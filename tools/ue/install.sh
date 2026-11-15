#!/usr/bin/env bash
# tools/ue/install.sh: install or update the UE-only variant in an Unreal project.
#
#   bash tools/ue/install.sh [options] <ue-project-dir>
#
# Copies this checkout's committed HEAD (uncommitted changes are not installed)
# into the folder that holds your .uproject. Run it again after each upstream
# sync. It records what it installed in <project>/.claude/ccgs-install.txt, so:
#   - new files are added, and files you have not changed are updated;
#   - files you changed (CLAUDE.md after /setup-engine, say) are three-way merged
#     with the template's new version; a clash is written with conflict markers
#     and reported;
#   - files upstream deleted are removed, unless you changed them;
#   - a file it installed that you deleted stays deleted (--restore-deleted
#     brings such files back);
#   - project.yaml, technical-preferences.md and the registries are only ever
#     added, never updated, and nothing it did not install is touched (your own
#     skills and agents, settings.local.json, agent memory);
#   - project.yaml gets engine.name Unreal when no engine is set, so skills that
#     default to Web take the Unreal route;
#   - a marked CCGS block in your .gitignore and .gitattributes is kept current.
# Template-only files (README, CHANGELOG, UPGRADING, .github/, tools/) are not
# copied. Line endings do not matter: files are compared and merged without CRs.
#
# --dry-run               show what would change and write nothing
# --yes                   do not ask before writing to a folder that is not a clean git repo
# --with-studio-tests     also install studio-tests/ (kept on later updates)
# --without-studio-tests  stop installing studio-tests/ (removes the unchanged ones)
# --restore-deleted       bring back installed files you deleted
#
# Needs bash 4 or later and git. Exit: 0 done; 1 error; 3 done, with conflicts
# left for you to resolve; 4 some files could not be written (nothing recorded:
# fix the cause, such as a file open in another program, and run it again).
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib.sh
. "$HERE/lib.sh"
TEMPLATE="$(git -C "$HERE" rev-parse --show-toplevel)" || exit 1

DRY=0; YES=0; STUDIO_ARG=""; RESTORE=0; PROJ=""
while [ $# -gt 0 ]; do
  case "$1" in
    --dry-run) DRY=1 ;;
    --yes) YES=1 ;;
    --with-studio-tests) STUDIO_ARG=1 ;;
    --without-studio-tests) STUDIO_ARG=0 ;;
    --restore-deleted) RESTORE=1 ;;
    -h|--help) sed -n '2,33p' "$0"; exit 0 ;;
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

# --- What was installed last time (CRs stripped: Git for Windows may add them) -----
STATE="$PROJ/.claude/ccgs-install.txt"
OLD=""; STUDIO_OLD=0
declare -A OLDKIND=() OLDSRC=()
if [ -f "$STATE" ]; then
  while IFS=$'\t' read -r kind tgt src; do
    kind="${kind%$'\r'}"; tgt="${tgt%$'\r'}"; src="${src%$'\r'}"
    case "$kind" in
      commit=*) OLD="${kind#commit=}" ;;
      studio_tests=*) STUDIO_OLD="${kind#studio_tests=}" ;;
      file|seed|deleted) OLDKIND["$tgt"]="$kind"; OLDSRC["$tgt"]="$src" ;;
    esac
  done < "$STATE"
fi
STUDIO="${STUDIO_ARG:-$STUDIO_OLD}"
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

# --- The template now, and as last installed, without CRs ---------------------------
STAGE="$(mktemp -d)"
trap 'rm -rf "$STAGE"' EXIT
unpack() { # commit, folder
  mkdir -p "$2" && git -C "$TEMPLATE" archive --format=tar "$1" | tar -x -C "$2" || return 1
  # Strip CRs only from text files (grep -I skips binaries), and not from files
  # the template's attributes keep binary (-text) or CRLF (eol=crlf). One
  # check-attr and one sed run for all of them: process starts are slow on Windows.
  local p a v
  local -A keep=()
  ( cd "$2" && LC_ALL=C grep -rIlZ $'\r' . 2>/dev/null ) \
    | while IFS= read -r -d '' p; do printf '%s\0' "${p#./}"; done > "$2.cr"
  [ -s "$2.cr" ] || { rm -f "$2.cr"; return 0; }
  while IFS= read -r -d '' p && IFS= read -r -d '' a && IFS= read -r -d '' v; do
    case "$a=$v" in text=unset|eol=crlf) keep["$p"]=1 ;; esac
  done < <(git -C "$TEMPLATE" check-attr --stdin -z text eol < "$2.cr")
  while IFS= read -r -d '' p; do [ -n "${keep[$p]:-}" ] || printf '%s\0' "$p"; done < "$2.cr" > "$2.strip"
  ( cd "$2" && xargs -0 -r sed -i 's/\r$//' < "$2.strip" )
  rm -f "$2.cr" "$2.strip"
}
is_text() { [ ! -s "$1" ] || LC_ALL=C grep -Iq . "$1" || ! LC_ALL=C grep -q . "$1"; }
# A file still holding the conflict markers an earlier run of this script wrote.
has_markers() { grep -q '^<<<<<<< yours$' "$1" && grep -q '^>>>>>>> template ' "$1"; }
unpack HEAD "$STAGE/t" || ue_die "could not read the template's HEAD"
if [ "$HAVEBASE" -eq 1 ]; then unpack "$OLD" "$STAGE/old" || ue_die "could not read the last installed commit $OLD"; fi
yget() { LC_ALL=C YG_PATH="$1" awk -f "$STAGE/t/.claude/scripts/yaml-get.awk" "$2" 2>/dev/null; }

# --- What to install, and where -------------------------------------------------
SEEDS=" project.yaml .claude/docs/technical-preferences.md design/registry/entities.yaml docs/registry/architecture.yaml docs/architecture/tr-registry.yaml "
declare -A NEWKIND=() NEWSRC=()
ORDER=(); NOTES=()
while IFS= read -r src; do
  tgt="$src"
  case "$src" in
    README.md|CHANGELOG.md|UPGRADING.md|CONTRIBUTING.md|SECURITY.md|.gitignore|.gitattributes) continue ;;
    .github/*|tools/*|production/session-state/*) continue ;;
    studio-tests/*) [ "$STUDIO" = 1 ] || continue ;;
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

declare -A N=() REC=()
count() { N[$1]=$(( ${N[$1]:-0} + 1 )); }
MERGED=(); CONFLICTS=(); BACKUPS=(); REMOVED=(); KEPT_DELETED=(); YOU_DELETED=(); BLOCKS=(); FAILED=()
put() { [ "$DRY" -eq 1 ] && return 0; mkdir -p "$(dirname "$2")" && cp "$1" "$2"; }
failed() { FAILED+=("$1"); count failed; }
lf() { tr -d '\r' < "$1" > "$2"; }

# Find the unchanged files in a handful of processes, not one or more per file
# (process starts are slow on Windows): copy the project's installed files once,
# strip CRs from the text ones as unpack() does, and hash both sides in two git
# runs. A CRLF checkout of an unchanged file then matches too. Should any step
# fail, each file falls back to its own comparison below.
declare -A SAME=()
HASHED=0; HKEYS=()
: > "$STAGE/plist"; : > "$STAGE/ppaths"; : > "$STAGE/spaths"
for tgt in "${ORDER[@]}"; do
  T="$PROJ/$tgt"
  [ -f "$T" ] && [ ! -L "$T" ] && [ "${NEWKIND[$tgt]}" != seed ] || continue
  printf '%s\n' "$tgt" >> "$STAGE/plist"
  printf '%s\n' "$STAGE/p/$tgt" >> "$STAGE/ppaths"
  printf '%s\n' "$STAGE/t/${NEWSRC[$tgt]}" >> "$STAGE/spaths"
  HKEYS+=("$tgt")
done
if [ "${#HKEYS[@]}" -gt 0 ] && mkdir -p "$STAGE/p" \
   && ( cd "$PROJ" && tar -cf - -T "$STAGE/plist" ) | tar -C "$STAGE/p" -xf - 2>/dev/null; then
  ( cd "$STAGE/p" && LC_ALL=C grep -rIlZ $'\r' . 2>/dev/null | xargs -0 -r sed -i 's/\r$//' )
  mapfile -t HP < <(git -C "$TEMPLATE" hash-object --no-filters --stdin-paths < "$STAGE/ppaths" 2>/dev/null)
  mapfile -t HS < <(git -C "$TEMPLATE" hash-object --no-filters --stdin-paths < "$STAGE/spaths" 2>/dev/null)
  if [ "${#HP[@]}" -eq "${#HKEYS[@]}" ] && [ "${#HS[@]}" -eq "${#HKEYS[@]}" ]; then
    HASHED=1
    for i in "${!HKEYS[@]}"; do [ "${HP[$i]}" = "${HS[$i]}" ] && SAME["${HKEYS[$i]}"]=1; done
  fi
fi
# Unchanged: the same bytes, or the same text once CRs are stripped from the
# project's copy. Without the hashes, a cmp (the main loop then checks the CRs).
same_bytes() { if [ "$HASHED" -eq 1 ]; then [ -n "${SAME[$1]:-}" ]; else cmp -s "$2" "$3"; fi; }

# --- Add, update or merge ---------------------------------------------------------
for tgt in "${ORDER[@]}"; do
  src="${NEWSRC[$tgt]}"; S="$STAGE/t/$src"; T="$PROJ/$tgt"; REC["$tgt"]="${NEWKIND[$tgt]}"
  if [ -d "$T" ] || [ -L "$T" ]; then ue_warn "skipped $tgt: a folder or link is in the way"; count skipped; continue; fi
  if [ ! -e "$T" ]; then
    if [ -n "${OLDKIND[$tgt]:-}" ] && [ "$RESTORE" -eq 0 ]; then
      # Installed before and gone now: you deleted it, so it stays deleted.
      REC["$tgt"]=deleted; count you-deleted; YOU_DELETED+=("$tgt"); continue
    fi
    if put "$S" "$T"; then count added; else failed "$tgt"; fi
    continue
  fi
  if [ "${NEWKIND[$tgt]}" = seed ]; then count yours; continue; fi
  if same_bytes "$tgt" "$T" "$S"; then count unchanged; continue; fi
  # Text is compared and merged with CRs stripped from all three copies (yours,
  # the base, the template's), so line endings never look like an edit; a file the
  # template keeps as CRLF is written back as CRLF. Binaries are compared as bytes.
  TEXT=0; is_text "$S" && TEXT=1
  CRLF=0; [ "$TEXT" -eq 1 ] && grep -q $'\r' "$S" && CRLF=1
  if [ "$TEXT" -eq 1 ]; then
    lf "$T" "$STAGE/mine"; lf "$S" "$STAGE/theirs"
    if cmp -s "$STAGE/mine" "$STAGE/theirs"; then count unchanged; continue; fi   # only line endings differ
    if has_markers "$STAGE/mine"; then
      # Merged with conflicts by an earlier run and not resolved yet: merging it
      # again would nest the markers, so leave it and keep reporting it.
      count conflicts; CONFLICTS+=("$tgt (still unresolved from an earlier run)"); continue
    fi
  else
    cp "$T" "$STAGE/mine"; cp "$S" "$STAGE/theirs"
  fi
  osrc="${OLDSRC[$tgt]:-}"; B="$STAGE/old/$osrc"
  if [ "$HAVEBASE" -eq 1 ] && [ -n "$osrc" ] && [ "${OLDKIND[$tgt]:-}" != deleted ] && [ -f "$B" ]; then
    if [ "$TEXT" -eq 1 ]; then lf "$B" "$STAGE/base"; else cp "$B" "$STAGE/base"; fi
    if cmp -s "$STAGE/mine" "$STAGE/base"; then                          # you had not changed it
      if put "$S" "$T"; then count updated; else failed "$tgt"; fi
      continue
    fi
    if cmp -s "$STAGE/theirs" "$STAGE/base"; then count yours; continue; fi   # only you changed it
    if [ "$TEXT" -eq 0 ]; then
      ue_warn "$tgt is binary and changed both here and in the template; kept yours"; count skipped; continue
    fi
    git -C "$TEMPLATE" merge-file -p -L "yours" -L "installed ${OLD:0:9}" -L "template $SHORT" \
      "$STAGE/mine" "$STAGE/base" "$STAGE/theirs" > "$STAGE/merged" 2>/dev/null
    rc=$?
    if [ "$CRLF" -eq 1 ] && [ "$rc" -ge 0 ] && [ "$rc" -le 127 ]; then
      sed -i 's/$/\r/' "$STAGE/merged"
    fi
    if [ "$rc" -eq 0 ]; then
      if put "$STAGE/merged" "$T"; then count merged; MERGED+=("$tgt"); else failed "$tgt"; fi
    elif [ "$rc" -ge 1 ] && [ "$rc" -le 127 ]; then
      if put "$STAGE/merged" "$T"; then count conflicts; CONFLICTS+=("$tgt"); else failed "$tgt"; fi
    else
      ue_warn "could not merge $tgt; left as it is"; count skipped
    fi
  else
    # Not installed by this script before: someone else's file with the same name.
    if [ "$DRY" -eq 1 ] || { cp "$T" "$T.pre-ccgs" && put "$S" "$T"; }; then
      count backed-up; BACKUPS+=("$tgt")
    else
      failed "$tgt"
    fi
  fi
done

# --- Remove what upstream deleted (or what you stopped installing) -------------------
for tgt in "${!OLDKIND[@]}"; do
  [ "${OLDKIND[$tgt]}" = file ] || continue
  [ -n "${NEWKIND[$tgt]:-}" ] && continue
  T="$PROJ/$tgt"
  [ -f "$T" ] || continue
  B="$STAGE/old/${OLDSRC[$tgt]}"
  same=1
  if [ "$HAVEBASE" -eq 1 ] && [ -f "$B" ]; then
    # Both sides without CRs, as in the main loop, so a CRLF file still matches.
    if is_text "$B"; then cmp -s <(tr -d '\r' < "$T") <(tr -d '\r' < "$B") || same=0; else cmp -s "$T" "$B" || same=0; fi
  else
    same=0
  fi
  if [ "$same" -eq 1 ]; then
    if [ "$DRY" -eq 0 ]; then
      if rm -f "$T"; then
        d="$(dirname "$T")"
        while [ "$d" != "$PROJ" ] && rmdir "$d" 2>/dev/null; do d="$(dirname "$d")"; done
      else
        failed "$tgt"; continue
      fi
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
  local rel="$1" T="$PROJ/$1" cur="$STAGE/blk.cur" out="$STAGE/blk.out"
  if [ -f "$T" ]; then tr -d '\r' < "$T" > "$cur"; else : > "$cur"; fi
  if grep -qxF "$BEGIN_MARK" "$cur"; then
    # Replace the first block in place; drop any duplicates an older run left.
    BODY="$2" B="$BEGIN_MARK" E="$END_MARK" awk '
      $0 == ENVIRON["B"] { skip = 1; if (!seen) { print; print ENVIRON["BODY"]; print ENVIRON["E"] } seen = 1; next }
      skip && $0 == ENVIRON["E"] { skip = 0; next }
      skip { next }
      { print }' "$cur" > "$out"
  elif [ -s "$cur" ]; then
    { cat "$cur"; [ -n "$(tail -c 1 "$cur")" ] && echo; echo; echo "$BEGIN_MARK"; printf '%s\n' "$2"; echo "$END_MARK"; } > "$out"
  else
    { echo "$BEGIN_MARK"; printf '%s\n' "$2"; echo "$END_MARK"; } > "$out"
  fi
  if [ -f "$T" ] && cmp -s "$cur" "$out"; then count unchanged; return 0; fi
  if put "$out" "$T"; then count block; BLOCKS+=("$rel"); else failed "$rel"; fi
}
GI_BODY="$(awk '/^# === Claude Code Local ===/ { p = 1; next } p && /^# ===/ { exit } p && NF && !/^#/' "$STAGE/t/.gitignore"
           echo docs/consistency-failures.md)"
GA_BODY="$(echo '# LF endings for the CCGS hooks, helpers and install record: CRLF breaks them.'
           grep -vE '^[[:space:]]*(#|$)' "$STAGE/t/.gitattributes"
           echo '.claude/ccgs-install.txt text eol=lf')"
block .gitignore "$GI_BODY"
block .gitattributes "$GA_BODY"

# --- project.yaml: Unreal when no engine is set ---------------------------------------
PY="$PROJ/project.yaml"
if [ ! -f "$PY" ]; then
  # A dry run of a first install reads the copy it would add; otherwise there is none.
  if [ "$DRY" -eq 1 ] && [ "${REC[project.yaml]:-}" = seed ]; then PY="$STAGE/t/project.yaml"; else PY=""; fi
fi
ENGINE=""; [ -n "$PY" ] && ENGINE="$(yget engine.name "$PY")"
if [ -z "$PY" ]; then
  NOTES+=("There is no project.yaml (you deleted it): run /setup-engine unreal $UE_VERSION to write one.")
elif [ -z "$ENGINE" ] && ! tr -d '\r' < "$PY" | grep -qE '^engine:'; then
  {
    echo ""
    echo "# Added by tools/ue/install.sh (UE-only variant) so skills that default to Web"
    echo "# take the Unreal route. /setup-engine unreal $UE_VERSION fills in the rest."
    echo "engine:"
    echo "  name: \"Unreal\""
    echo "  version: \"$UE_VERSION\""
    if ! tr -d '\r' < "$PY" | grep -qE '^specialists:'; then
      echo "specialists:"
      echo "  code: \"$UE_SPECIALIST_CODE\""
      echo "  shader: \"$UE_SPECIALIST_SHADER\""
      echo "  ui: \"$UE_SPECIALIST_UI\""
      printf '  additional: [%s]\n' "$(printf '"%s", ' "${UE_SPECIALIST_ADDITIONAL[@]}" | sed 's/, $//')"
    fi
  } > "$STAGE/engine.yaml"
  if [ "$DRY" -eq 1 ] || { [ -n "$(tail -c 1 "$PY")" ] && echo >> "$PY"; cat "$STAGE/engine.yaml" >> "$PY"; }; then
    NOTES+=("project.yaml had no engine, so engine.name is now Unreal $UE_VERSION. Run /setup-engine unreal $UE_VERSION to fill in the rest.")
  else
    failed project.yaml
  fi
elif [ -z "$ENGINE" ]; then
  NOTES+=("project.yaml has an engine block with no name: run /setup-engine unreal $UE_VERSION.")
else
  case "$ENGINE" in
    [Uu]nreal*) ;;
    *) NOTES+=("project.yaml says engine.name: $ENGINE, but this variant is for Unreal: run /setup-engine unreal $UE_VERSION.") ;;
  esac
fi

# --- Record what is installed now (not after a failure: the next run retries) --------
FRAMEWORK="$(yget framework.version "$STAGE/t/project.yaml")"
if [ "$DRY" -eq 0 ] && [ "${#FAILED[@]}" -eq 0 ]; then
  {
    echo "# Written by tools/ue/install.sh (UE-only variant of Claude Code Game Studios)."
    echo "# Lists the template files installed here and the commit they came from; the next"
    echo "# install merges your changes against them. Commit this file; do not edit it."
    echo "commit=$NEW"
    echo "framework=$FRAMEWORK"
    echo "ue_version=$UE_VERSION"
    echo "studio_tests=$STUDIO"
    echo "installed=$(date -u +%Y-%m-%dT%H:%M:%SZ)"
    for tgt in "${ORDER[@]}"; do printf '%s\t%s\t%s\n' "${REC[$tgt]}" "$tgt" "${NEWSRC[$tgt]}"; done
  } > "$STAGE/state"
  # Keep the old file, and its date, when nothing but the date would change.
  if ! [ -f "$STATE" ] || ! cmp -s <(tr -d '\r' < "$STATE" | grep -v '^installed=') <(grep -v '^installed=' "$STAGE/state"); then
    mkdir -p "$(dirname "$STATE")" && cp "$STAGE/state" "$STATE" || failed .claude/ccgs-install.txt
  fi
fi

# --- Report ---------------------------------------------------------------------
ASSOC="$(sed -n 's/.*"EngineAssociation"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' "$UPROJECT" | head -1)"
if [ -n "$ASSOC" ] && [ "$ASSOC" != "$UE_VERSION" ]; then
  NOTES+=("$(basename "$UPROJECT") is on UE $ASSOC and this variant pins UE $UE_VERSION; /setup-engine records the difference so agents know which APIs your editor has.")
fi
grep -qi microsoft /proc/version 2>/dev/null \
  && NOTES+=("Run Claude Code for this project from Windows, not WSL: under WSL the UE test runner builds Linux commands.")
[ "${#BACKUPS[@]}" -gt 0 ] \
  && NOTES+=("Files that were already there are kept beside ours as <name>.pre-ccgs: merge back what you need, then delete them.")
[ "${#YOU_DELETED[@]}" -gt 0 ] \
  && NOTES+=("${#YOU_DELETED[@]} installed file(s) you deleted stay deleted; --restore-deleted brings them back.")
if [ -n "$OLD" ] && [ "$OLD" != "$NEW" ]; then
  NOTES+=("Read the new release's section of UPGRADING.md in the template: this script does not migrate project.yaml, so one-off steps and new settings reach you only that way.")
fi

list() { local title="$1"; shift; [ $# -gt 0 ] || return 0; echo "  $title"; printf '    %s\n' "$@"; }
WHAT="into"; [ "$DRY" -eq 1 ] && WHAT="dry run for"
echo "install: template $SHORT (framework ${FRAMEWORK:-?}, Unreal Engine $UE_VERSION), $WHAT $PROJ"
printf '  added %d, updated %d, merged %d, conflicts %d, removed %d, unchanged %d, kept as yours %d, backed up %d, you deleted %d, skipped %d, failed %d\n' \
  "${N[added]:-0}" "${N[updated]:-0}" "${N[merged]:-0}" "${N[conflicts]:-0}" "${N[removed]:-0}" \
  "${N[unchanged]:-0}" "${N[yours]:-0}" "${N[backed-up]:-0}" "${N[you-deleted]:-0}" "${N[skipped]:-0}" "${N[failed]:-0}"
list "merged with your changes:" "${MERGED[@]}"
list "CONFLICTS, resolve the <<<<<<< markers:" "${CONFLICTS[@]}"
list "kept as <name>.pre-ccgs, then replaced:" "${BACKUPS[@]}"
list "removed (deleted upstream, or no longer installed):" "${REMOVED[@]}"
list "deleted upstream but changed here, so left in place:" "${KEPT_DELETED[@]}"
list "deleted by you, so not added back:" "${YOU_DELETED[@]}"
list "CCGS block updated in:" "${BLOCKS[@]}"
list "FAILED to write:" "${FAILED[@]}"
[ "${#NOTES[@]}" -gt 0 ] && { echo "Notes:"; printf -- '- %s\n' "${NOTES[@]}"; }
if [ "$DRY" -eq 1 ]; then
  echo "Nothing was written. Run again without --dry-run to install."
elif [ "${#FAILED[@]}" -gt 0 ]; then
  echo "Some files could not be written, so nothing was recorded. Fix the cause (a read-only file, or one open in another program) and run it again; add --yes, since the files it did write are now uncommitted changes." >&2
  if [ "${#CONFLICTS[@]}" -gt 0 ]; then
    echo "Resolve the CONFLICTS listed above before that run, or drop the merge with git checkout -- <file>: the retry leaves any file that still has conflict markers alone." >&2
  fi
  exit 4
elif git -C "$PROJ" rev-parse --is-inside-work-tree >/dev/null 2>&1; then
  echo "Review with: git -C \"$PROJ\" status, then commit, .claude/ccgs-install.txt included."
fi
[ "${#CONFLICTS[@]}" -eq 0 ] || exit 3
exit 0
