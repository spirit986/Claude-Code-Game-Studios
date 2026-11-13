#!/usr/bin/env bash
# tools/ue/install.sh: install or update the UE-only variant in an Unreal project.
#
#   bash tools/ue/install.sh [--dry-run] [--yes] [--with-studio-tests] <ue-project-dir>
#
# Copies this checkout's committed HEAD (uncommitted changes are not installed)
# into the folder that holds your .uproject. Run it again after each upstream
# sync. It records what it installed in <project>/.claude/ccgs-install.txt, so:
#   - new files are added, and files you have not changed are updated;
#   - files you changed (CLAUDE.md after /setup-engine, say) are three-way merged
#     with the template's new version; a clash is written with conflict markers
#     and reported;
#   - files upstream deleted are removed, unless you changed them;
#   - project.yaml, technical-preferences.md and the registries are only ever
#     added, never updated, and nothing it did not install is touched (your own
#     skills and agents, settings.local.json, agent memory);
#   - a marked CCGS block in your .gitignore and .gitattributes is kept current.
# Template-only files (README, CHANGELOG, UPGRADING, .github/, tools/) are not
# copied, and studio-tests/ only with --with-studio-tests.
#
# --dry-run            show what would change and write nothing
# --yes                do not ask before writing to a folder that is not a clean git repo
# --with-studio-tests  also install studio-tests/ (only to test skills you edit)
#
# Needs bash 4 or later and git. Exit: 0 done; 1 error; 3 done, with conflicts
# left in files for you to resolve.
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib.sh
. "$HERE/lib.sh"
TEMPLATE="$(git -C "$HERE" rev-parse --show-toplevel)" || exit 1

DRY=0; YES=0; STUDIO=0; PROJ=""
while [ $# -gt 0 ]; do
  case "$1" in
    --dry-run) DRY=1 ;;
    --yes) YES=1 ;;
    --with-studio-tests) STUDIO=1 ;;
    -h|--help) sed -n '2,27p' "$0"; exit 0 ;;
    -*) ue_die "unknown option: $1 (try --help)" ;;
    *) [ -z "$PROJ" ] || ue_die "only one project folder, please"; PROJ="$1" ;;
  esac
  shift
done
[ -n "$PROJ" ] || ue_die "which project? Give the folder that holds the .uproject (try --help)"
[ -d "$PROJ" ] || ue_die "no such folder: $PROJ"
PROJ="$(cd "$PROJ" && pwd -P)"
case "$PROJ/" in "$TEMPLATE"/*) ue_die "that folder is inside the template itself" ;; esac
UPROJECT="$(find "$PROJ" -maxdepth 1 -type f -name '*.uproject' | head -1)"
[ -n "$UPROJECT" ] || ue_die "$PROJ has no .uproject at its top level. Install into the folder that holds it: the UE scripts look for it only there."

NEW="$(git -C "$TEMPLATE" rev-parse HEAD)"
SHORT="$(git -C "$TEMPLATE" rev-parse --short HEAD)"
[ -z "$(git -C "$TEMPLATE" status --porcelain --untracked-files=no)" ] \
  || ue_warn "the template has uncommitted changes; they are not installed (its HEAD, $SHORT, is)"

# --- What was installed last time ---------------------------------------------------
STATE="$PROJ/.claude/ccgs-install.txt"
OLD=""
declare -A OLDKIND=() OLDSRC=()
if [ -f "$STATE" ]; then
  OLD="$(sed -n 's/^commit=//p' "$STATE" | head -1)"
  while IFS=$'\t' read -r kind tgt src; do
    case "$kind" in file|seed) OLDKIND["$tgt"]="$kind"; OLDSRC["$tgt"]="$src" ;; esac
  done < "$STATE"
fi
HAVEBASE=0
if [ -n "$OLD" ]; then
  if git -C "$TEMPLATE" cat-file -e "$OLD^{commit}" 2>/dev/null; then
    HAVEBASE=1
  else
    ue_warn "the last installed commit ($OLD) is not in this template's history, so files you changed are kept as .pre-ccgs copies instead of merged"
  fi
fi

# --- Ask before writing where git cannot show or undo the install -------------------
if [ "$DRY" -eq 0 ] && [ "$YES" -eq 0 ]; then
  RISK=""
  if ! git -C "$PROJ" rev-parse --is-inside-work-tree >/dev/null 2>&1; then
    RISK="$PROJ is not in a git repository, so this install cannot be reviewed with git diff or undone. Back the folder up first."
  elif [ -n "$(git -C "$PROJ" status --porcelain 2>/dev/null)" ]; then
    RISK="$PROJ has uncommitted changes, so git diff will not show this install on its own."
  fi
  if [ -n "$RISK" ]; then
    if [ -t 0 ]; then
      printf '%s\nInstall anyway? [y/N] ' "$RISK"
      read -r ans
      case "$ans" in y|Y|yes|YES) ;; *) ue_die "stopped; nothing was written" ;; esac
    else
      ue_die "$RISK Re-run with --yes to install anyway."
    fi
  fi
fi
[ "$DRY" -eq 1 ] || echo "install: close any Claude Code session in the project first; hooks run on every tool call."

STAGE="$(mktemp -d)"
trap 'rm -rf "$STAGE"' EXIT
mkdir -p "$STAGE/t"
git -C "$TEMPLATE" archive --format=tar HEAD | tar -x -C "$STAGE/t" || ue_die "could not read the template's HEAD"

# --- What to install, and where -------------------------------------------------
SEEDS=" project.yaml .claude/docs/technical-preferences.md design/registry/entities.yaml docs/registry/architecture.yaml docs/architecture/tr-registry.yaml production/session-state/.gitkeep "
declare -A NEWKIND=() NEWSRC=()
ORDER=(); NOTES=()
while IFS= read -r src; do
  tgt="$src"
  case "$src" in
    README.md|CHANGELOG.md|UPGRADING.md|CONTRIBUTING.md|SECURITY.md|.gitignore|.gitattributes) continue ;;
    .github/*|tools/*) continue ;;
    studio-tests/*) [ "$STUDIO" -eq 1 ] || continue ;;
    LICENSE) tgt=.claude/CCGS-LICENSE.txt ;;
    src/CLAUDE.md)
      if [ -d "$PROJ/Source" ]; then
        tgt=Source/CLAUDE.md
      else
        NOTES+=("Source/CLAUDE.md was not installed: the project has no Source/ folder (Blueprint-only). The next install after you add C++ adds it.")
        continue
      fi ;;
    src/*) continue ;;
  esac
  case "$SEEDS" in *" $src "*) kind=seed ;; *) kind=file ;; esac
  NEWKIND["$tgt"]="$kind"; NEWSRC["$tgt"]="$src"; ORDER+=("$tgt")
done < <(git -C "$TEMPLATE" ls-tree -r --name-only HEAD)

declare -A N=()
count() { N[$1]=$(( ${N[$1]:-0} + 1 )); }
MERGED=(); CONFLICTS=(); BACKUPS=(); REMOVED=(); KEPT_DELETED=(); BLOCKS=()
put() { [ "$DRY" -eq 1 ] && return 0; mkdir -p "$(dirname "$2")" && cp "$1" "$2"; }
base_of() { git -C "$TEMPLATE" show "$OLD:$1" > "$STAGE/base" 2>/dev/null; }

# --- Add, update or merge ---------------------------------------------------------
for tgt in "${ORDER[@]}"; do
  src="${NEWSRC[$tgt]}"; S="$STAGE/t/$src"; T="$PROJ/$tgt"
  if [ -d "$T" ] || [ -L "$T" ]; then ue_warn "skipped $tgt: a folder or link is in the way"; count skipped; continue; fi
  if [ ! -e "$T" ]; then put "$S" "$T"; count added; continue; fi
  if [ "${NEWKIND[$tgt]}" = seed ]; then count yours; continue; fi
  if cmp -s "$T" "$S"; then count unchanged; continue; fi
  osrc="${OLDSRC[$tgt]:-}"
  if [ "$HAVEBASE" -eq 1 ] && [ -n "$osrc" ] && base_of "$osrc"; then
    if cmp -s "$T" "$STAGE/base"; then put "$S" "$T"; count updated; continue; fi   # you had not changed it
    if cmp -s "$S" "$STAGE/base"; then count yours; continue; fi                    # only you changed it
    git -C "$TEMPLATE" merge-file -p -L "yours" -L "installed ${OLD:0:9}" -L "template $SHORT" \
      "$T" "$STAGE/base" "$S" > "$STAGE/merged" 2>/dev/null
    rc=$?
    if [ "$rc" -eq 0 ]; then
      put "$STAGE/merged" "$T"; count merged; MERGED+=("$tgt")
    elif [ "$rc" -ge 1 ] && [ "$rc" -le 127 ]; then
      put "$STAGE/merged" "$T"; count conflicts; CONFLICTS+=("$tgt")
    else
      ue_warn "could not merge $tgt; left as it is"; count skipped
    fi
  else
    # Not installed by this script before: someone else's file with the same name.
    if [ "$DRY" -eq 0 ]; then cp "$T" "$T.pre-ccgs" && cp "$S" "$T"; fi
    count backed-up; BACKUPS+=("$tgt")
  fi
done

# --- Remove what upstream deleted ---------------------------------------------------
for tgt in "${!OLDKIND[@]}"; do
  [ "${OLDKIND[$tgt]}" = file ] || continue
  [ -n "${NEWKIND[$tgt]:-}" ] && continue
  T="$PROJ/$tgt"
  [ -f "$T" ] || continue
  if [ "$HAVEBASE" -eq 1 ] && base_of "${OLDSRC[$tgt]}" && cmp -s "$T" "$STAGE/base"; then
    if [ "$DRY" -eq 0 ]; then
      rm -f "$T"
      d="$(dirname "$T")"
      while [ "$d" != "$PROJ" ] && rmdir "$d" 2>/dev/null; do d="$(dirname "$d")"; done
    fi
    count removed; REMOVED+=("$tgt")
  else
    count kept; KEPT_DELETED+=("$tgt")
  fi
done

# --- The CCGS blocks in .gitignore and .gitattributes ---------------------------------
BEGIN_MARK="# >>> CCGS: managed by tools/ue/install.sh; edits inside this block are replaced >>>"
END_MARK="# <<< CCGS <<<"
block() {
  local T="$PROJ/$1" out="$STAGE/block"
  if [ -f "$T" ] && grep -qxF "$BEGIN_MARK" "$T"; then
    BODY="$2" B="$BEGIN_MARK" E="$END_MARK" awk '
      $0 == ENVIRON["B"] { print; print ENVIRON["BODY"]; skip = 1; next }
      $0 == ENVIRON["E"] { skip = 0 }
      !skip { print }' "$T" > "$out"
  elif [ -f "$T" ]; then
    { cat "$T"; [ -n "$(tail -c 1 "$T")" ] && echo; echo; echo "$BEGIN_MARK"; printf '%s\n' "$2"; echo "$END_MARK"; } > "$out"
  else
    { echo "$BEGIN_MARK"; printf '%s\n' "$2"; echo "$END_MARK"; } > "$out"
  fi
  if [ -f "$T" ] && cmp -s "$T" "$out"; then count unchanged; return 0; fi
  put "$out" "$T"; count block; BLOCKS+=("$1")
}
GI_BODY="$(awk '/^# === Claude Code Local ===/ { p = 1; next } p && /^# ===/ { exit } p && NF && !/^#/' "$STAGE/t/.gitignore"
           echo docs/consistency-failures.md)"
GA_BODY="$(echo '# LF endings for the CCGS hooks and helpers: a CRLF checkout breaks them on Windows.'
           grep -vE '^[[:space:]]*(#|$)' "$STAGE/t/.gitattributes")"
block .gitignore "$GI_BODY"
block .gitattributes "$GA_BODY"

# --- Record what is installed now ---------------------------------------------------
FRAMEWORK="$(awk '/^framework:/ { f = 1; next } f && /^[^[:space:]]/ { exit } f && /^[[:space:]]+version:/ { sub(/^[[:space:]]+version:[[:space:]]*/, ""); print; exit }' "$STAGE/t/project.yaml")"
if [ "$DRY" -eq 0 ]; then
  {
    echo "# Written by tools/ue/install.sh (UE-only variant of Claude Code Game Studios)."
    echo "# Lists the template files installed here and the commit they came from; the next"
    echo "# install merges your changes against them. Commit this file; do not edit it."
    echo "commit=$NEW"
    echo "framework=$FRAMEWORK"
    echo "ue_version=$UE_VERSION"
    echo "installed=$(date -u +%Y-%m-%dT%H:%M:%SZ)"
    for tgt in "${ORDER[@]}"; do printf '%s\t%s\t%s\n' "${NEWKIND[$tgt]}" "$tgt" "${NEWSRC[$tgt]}"; done
  } > "$STATE"
fi

# --- Report ---------------------------------------------------------------------
ENGINE="$(awk '/^engine:/ { e = 1; next } e && /^[^[:space:]#]/ { exit }
  e && /^[[:space:]]+name:/ { sub(/^[[:space:]]+name:[[:space:]]*/, ""); gsub(/["\047]/, ""); print; exit }' "$PROJ/project.yaml" 2>/dev/null)"
case "$ENGINE" in
  [Uu]nreal*) ;;
  "") NOTES+=("Next: open Claude Code in the project and run /setup-engine unreal $UE_VERSION before /start or /prototype. With no engine set, 1.3 defaults to Web.") ;;
  *) NOTES+=("project.yaml says engine.name: $ENGINE. This variant is for Unreal: run /setup-engine unreal $UE_VERSION.") ;;
esac
ASSOC="$(sed -n 's/.*"EngineAssociation"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' "$UPROJECT" | head -1)"
if [ -n "$ASSOC" ] && [ "$ASSOC" != "$UE_VERSION" ]; then
  NOTES+=("$(basename "$UPROJECT") is on UE $ASSOC and this variant pins UE $UE_VERSION; /setup-engine records the difference so agents know which APIs your editor has.")
fi
grep -qi microsoft /proc/version 2>/dev/null \
  && NOTES+=("Run Claude Code for this project from Windows, not WSL: under WSL the UE test runner builds Linux commands.")
[ "${#BACKUPS[@]}" -gt 0 ] \
  && NOTES+=("Files that were already there are kept beside ours as <name>.pre-ccgs: merge back what you need, then delete them.")
if [ -n "$OLD" ] && [ "$OLD" != "$NEW" ]; then
  NOTES+=("Read the new release's section of UPGRADING.md in the template: this script never updates project.yaml, so one-off steps and new settings reach you only that way.")
fi

list() { local title="$1"; shift; [ $# -gt 0 ] || return 0; echo "  $title"; printf '    %s\n' "$@"; }
WHAT="into"; [ "$DRY" -eq 1 ] && WHAT="dry run for"
echo "install: template $SHORT (framework ${FRAMEWORK:-?}, Unreal Engine $UE_VERSION), $WHAT $PROJ"
printf '  added %d, updated %d, merged %d, conflicts %d, removed %d, unchanged %d, kept as yours %d, backed up %d, skipped %d\n' \
  "${N[added]:-0}" "${N[updated]:-0}" "${N[merged]:-0}" "${N[conflicts]:-0}" "${N[removed]:-0}" \
  "${N[unchanged]:-0}" "${N[yours]:-0}" "${N[backed-up]:-0}" "${N[skipped]:-0}"
list "merged with your changes:" "${MERGED[@]}"
list "CONFLICTS, resolve the <<<<<<< markers:" "${CONFLICTS[@]}"
list "kept as <name>.pre-ccgs, then replaced:" "${BACKUPS[@]}"
list "removed (deleted upstream):" "${REMOVED[@]}"
list "deleted upstream but changed here, so left in place:" "${KEPT_DELETED[@]}"
list "CCGS block updated in:" "${BLOCKS[@]}"
[ "${#NOTES[@]}" -gt 0 ] && { echo "Notes:"; printf -- '- %s\n' "${NOTES[@]}"; }
if [ "$DRY" -eq 1 ]; then
  echo "Nothing was written. Run again without --dry-run to install."
elif git -C "$PROJ" rev-parse --is-inside-work-tree >/dev/null 2>&1; then
  echo "Review with: git -C \"$PROJ\" status, then commit, .claude/ccgs-install.txt included."
fi
[ "${#CONFLICTS[@]}" -eq 0 ] || exit 3
exit 0
