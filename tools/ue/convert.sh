#!/usr/bin/env bash
# tools/ue/convert.sh: build the UE-only variant from upstream, or check it.
#
#   bash tools/ue/convert.sh [--base <commit>]          rebuild, stage, then check
#   bash tools/ue/convert.sh --check [--base <commit>]  check only; change nothing
#
# Every file convert.sh edits (ue_overlay_files in lib.sh) is rebuilt from
# upstream's copy at <commit>, then edited. The result depends only on upstream,
# lib.sh and which agents and skills the tree has, so changing a setting and
# re-running applies it, and --check is an exact comparison. <commit> defaults
# to the merge in progress (MERGE_HEAD), else to the merge base of HEAD and
# $UE_MIRROR_REF (origin/main): the upstream release this branch last merged.
#
# It also deletes the paths in UE_DENY, and keeps the model: and effort: lines
# of every skill and agent outside the lib.sh lists equal to upstream's, so a
# pin removed from lib.sh does not linger.
#
# Required edits fail when upstream moves the text they rely on; edits to docs
# only warn. Everything is read and compared as git blobs, so core.autocrlf
# does not matter.
#
# Exit: 0 converted (with --check: already converted); 1 a problem, listed.
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib.sh
. "$HERE/lib.sh"
ROOT="$(git -C "$HERE" rev-parse --show-toplevel)" || exit 1
cd "$ROOT" || exit 1

MODE=convert; BASE=""
while [ $# -gt 0 ]; do
  case "$1" in
    --check) MODE=check ;;
    --base) [ $# -ge 2 ] || ue_die "--base needs a commit"; BASE="$2"; shift ;;
    -h|--help) sed -n '2,23p' "$0"; exit 0 ;;
    *) ue_die "unknown option: $1 (try --help)" ;;
  esac
  shift
done
if [ -z "$BASE" ]; then
  if git rev-parse -q --verify MERGE_HEAD >/dev/null; then
    BASE=MERGE_HEAD
  elif git rev-parse -q --verify "$UE_MIRROR_REF^{commit}" >/dev/null; then
    BASE="$(git merge-base HEAD "$UE_MIRROR_REF")" || ue_die "HEAD and $UE_MIRROR_REF share no history"
  else
    ue_die "cannot tell which upstream release to build from: $UE_MIRROR_REF is missing. Run git fetch origin main, or pass --base <commit>."
  fi
fi
BASE="$(git rev-parse -q --verify "$BASE^{commit}")" || ue_die "unknown commit: $BASE"
BSHORT="$(git rev-parse --short "$BASE")"

STAGE="$(mktemp -d)"
trap 'rm -rf "$STAGE"' EXIT
FAILS=0
fail() { printf 'FAIL: %s\n' "$*" >&2; FAILS=$((FAILS + 1)); }
declare -A CONFLICTED=()
while IFS= read -r p; do [ -n "$p" ] && CONFLICTED["$p"]=1; done < <(git diff --name-only --diff-filter=U)
in_conflict() { [ -n "${CONFLICTED[$1]:-}" ]; }
in_list() { local x="$1" y; shift; for y in "$@"; do [ "$x" = "$y" ] && return 0; done; return 1; }

mapfile -t OVERLAY < <(ue_overlay_files | LC_ALL=C sort -u)
declare -A IS_OVERLAY=()
for f in "${OVERLAY[@]}"; do IS_OVERLAY["$f"]=1; done

# --- The tree's agents and skills, as they are once the deletions are done -------
keep() { while IFS= read -r p; do ue_denied "$p" || printf '%s\n' "$p"; done; }
mapfile -t AGENTS < <(git ls-files -- '.claude/agents/*.md' | LC_ALL=C sort -u | keep)
mapfile -t SKILLS < <(git ls-files -- '.claude/skills/*/SKILL.md' | LC_ALL=C sort -u | keep)
AGENT_COUNT=${#AGENTS[@]}

declare -A IN_BASE=() UP_M=() UP_E=() IX_M=() IX_E=()
while IFS= read -r p; do IN_BASE["$p"]=1; done < <(git ls-tree -r --name-only "$BASE" -- .claude/agents .claude/skills)
while IFS=$'\t' read -r p m e; do [ -n "$p" ] && { UP_M["$p"]="$m"; UP_E["$p"]="$e"; }; done < <(ue_pins "$BASE")
while IFS=$'\t' read -r p m e; do [ -n "$p" ] && { IX_M["$p"]="$m"; IX_E["$p"]="$e"; }; done < <(ue_pins --cached)

# What model: and effort: a skill or agent should have: the lib.sh lists first,
# then upstream's value, then (for a file upstream does not have) its own.
want_model() {
  local p="$1" n
  case "$p" in
    .claude/skills/*/SKILL.md) n="${p#.claude/skills/}"; n="${n%/SKILL.md}"; in_list "$n" "${UE_OPUS_SKILLS[@]}" && { echo opus; return; } ;;
    .claude/agents/*.md) n="${p#.claude/agents/}"; n="${n%.md}"; in_list "$n" "${UE_OPUS_AGENTS[@]}" && { echo opus; return; } ;;
  esac
  if [ -n "${IN_BASE[$p]:-}" ]; then echo "${UP_M[$p]:-}"; else echo "${IX_M[$p]:-}"; fi
}
want_effort() {
  local p="$1" n
  case "$p" in
    .claude/agents/*.md) n="${p#.claude/agents/}"; n="${n%.md}"; in_list "$n" "${UE_XHIGH_AGENTS[@]}" && { echo xhigh; return; } ;;
  esac
  if [ -n "${IN_BASE[$p]:-}" ]; then echo "${UP_E[$p]:-}"; else echo "${IX_E[$p]:-}"; fi
}

# --- The edits, applied to upstream's copy of each file --------------------------
edit_claude_md() {
  local x="$1"
  ue_replace_line "$x" '^- \*\*Engine\*\*: \[CHOOSE' "- **Engine**: Unreal Engine $UE_VERSION" \
    || fail "CLAUDE.md: upstream has no '- **Engine**: [CHOOSE ...' line"
  ue_replace_line "$x" '^- \*\*Language\*\*: \[CHOOSE' "- **Language**: $UE_LANGUAGE" \
    || fail "CLAUDE.md: upstream has no '- **Language**: [CHOOSE ...' line"
  ue_replace_line "$x" '^- \*\*Build System\*\*: \[SPECIFY' "- **Build System**: Unreal Build Tool (UBT)" \
    || fail "CLAUDE.md: upstream has no '- **Build System**: [SPECIFY ...' line"
  ue_replace_line "$x" '^- \*\*Asset Pipeline\*\*: \[SPECIFY' "- **Asset Pipeline**: Unreal Content Pipeline" \
    || fail "CLAUDE.md: upstream has no '- **Asset Pipeline**: [SPECIFY ...' line"
  if grep -qE '^@docs/engine-reference/[a-z]+/VERSION\.md' "$x"; then
    ue_replace_line "$x" '^@docs/engine-reference/[a-z]+/VERSION\.md' '@docs/engine-reference/unreal/VERSION.md'
  elif grep -q 'ENGINE-REFERENCE-IMPORT' "$x"; then
    # 1.3.0 ships no import line until an engine is set: add it under the marker comment.
    awk '{ print } /ENGINE-REFERENCE-IMPORT/ { m = 1 } m && /-->/ { print "@docs/engine-reference/unreal/VERSION.md"; m = 0 }' \
      "$x" > "$x.t" && mv "$x.t" "$x"
  else
    fail "CLAUDE.md: upstream has neither an engine import line nor the ENGINE-REFERENCE-IMPORT marker"
  fi
  grep -qE 'managed through [0-9]+ coordinated' "$x" \
    && sed -i -E "s/managed through [0-9]+ coordinated/managed through $AGENT_COUNT coordinated/" "$x" \
    || ue_warn "CLAUDE.md: the agent-count sentence changed upstream; not updated"
  if grep -q '^> \*\*Note\*\*: Engine-specialist agents exist for Godot, Unity, and Unreal' "$x"; then
    NOTE="> **Note**: UE-only variant: only the Unreal specialists (\`unreal-specialist\` and the \`ue-*\` sub-specialists) are installed. See \`.claude/docs/ue-variant.md\`." \
    awk '
      skip && /^>/ { next }
      { skip = 0 }
      /^> \*\*Note\*\*: Engine-specialist agents exist for Godot, Unity, and Unreal/ { print ENVIRON["NOTE"]; skip = 1; next }
      { print }' "$x" > "$x.t" && mv "$x.t" "$x"
  else
    ue_warn "CLAUDE.md: the engine-specialist note changed upstream; left as it is"
  fi
}

edit_readme() {
  local x="$1"
  # At the very top: upstream's README opens with an HTML block, not a heading.
  BANNER="> **UE-only variant.** Godot and Unity are removed, and upstream releases arrive as pull requests. Counts, model tiers and engine lists below describe upstream; this variant has $AGENT_COUNT agents and is Unreal only. See [.claude/docs/ue-variant.md](.claude/docs/ue-variant.md)." \
  awk 'NR == 1 { print ENVIRON["BANNER"]; print "" } { print }' "$x" > "$x.t" && mv "$x.t" "$x"
}

edit_settings() {
  local x="$1"
  command -v jq >/dev/null 2>&1 || { fail "jq is needed to edit .claude/settings.json"; return; }
  jq --indent 2 --arg m "$UE_SONNET_MODEL_ID" --arg e "$UE_SONNET_EFFORT" \
    '.modelSettings = ((.modelSettings // {}) + {($m): ((.modelSettings[$m] // {}) + {effortLevel: $e})})' \
    "$x" > "$x.t" && mv "$x.t" "$x" || fail ".claude/settings.json: upstream's copy is not valid JSON, or jq failed"
}

edit_update_check() {
  local x="$1"
  # The version check still watches Donchitos (the earliest signal of a release);
  # the hint now sends an installed project to this variant's process.
  ue_replace_text "$x" \
    'What changed and how to upgrade: https://github.com/$UPDATE_CHECK_REPO/releases/latest' \
    "This project uses the UE-only variant: update it from https://github.com/$UE_VARIANT_REPO (merge the release's sync pull request there, then run tools/ue/install.sh), not with upstream's UPGRADING steps" \
    || fail ".claude/hooks/update-check.sh: the upgrade hint changed upstream; update edit_update_check in convert.sh"
}

edit_setup_engine() {
  local x="$1"
  ue_replace_line "$x" '^description:' \
    'description: "Sets up and pins the Unreal Engine version for this project (UE-only variant). Use to set up or upgrade it."' \
    || fail ".claude/skills/setup-engine/SKILL.md: upstream has no description line"
  if grep -q '^## 2\. Guided Mode' "$x"; then
    NOTE="UE-only variant: with no arguments, run as \`/setup-engine unreal $UE_VERSION\` and skip engine selection, which would otherwise default to Web." \
    awk '{ print } /^## 2\. Guided Mode/ { print ""; print ENVIRON["NOTE"] }' "$x" > "$x.t" && mv "$x.t" "$x"
  else
    fail ".claude/skills/setup-engine/SKILL.md: the '## 2. Guided Mode' heading moved upstream"
  fi
}

edit_scaffold() {
  local x="$1"
  if grep -q '^- \*\*Unreal\*\* — create the project in the Epic launcher' "$x"; then
    awk '
      skip && /^  / { next }
      { skip = 0 }
      /^- \*\*Unreal\*\* — create the project in the Epic launcher/ {
        print "- **Unreal** — create the project in the Epic launcher or via `UnrealEditor`,"
        print "  then move its contents up so the `.uproject` sits at the repo root: the"
        print "  launcher makes a subfolder, and the UE scripts look for the `.uproject` only"
        print "  at the root. Then re-run."
        skip = 1; next }
      { print }' "$x" > "$x.t" && mv "$x.t" "$x"
  else
    ue_warn "7.5-scaffold.md: the Unreal scaffold line changed upstream; left as it is"
  fi
}

edit_roster() {
  local x="$1"
  ue_replace_line "$x" '^## Engine-Specific Agents' '## Engine-Specific Agents (this variant has the Unreal set only)' \
    || ue_warn "agent-roster.md: the engine section heading changed upstream"
  awk '
    /^### (Unity|Godot) Sub-Specialists/ { skip = 1; next }
    skip && /^#/ { skip = 0 }
    skip { next }
    /^\| `(godot|unity)-/ { next }
    { print }' "$x" > "$x.t" && mv "$x.t" "$x"
  grep -qE '`(godot|unity)-' "$x" && ue_warn "agent-roster.md: still names a Godot or Unity agent (its layout changed upstream)"
}

edit_model_tiers() {
  local x="$1" p n m e line
  local -a s_opus=() s_haiku=() s_other=() a_opus=() a_sonnet=() a_other=() effort=()
  local s_sonnet=0 a_inherit=0
  for p in "${SKILLS[@]}"; do
    n="${p#.claude/skills/}"; n="/${n%/SKILL.md}"; m="$(want_model "$p")"; e="$(want_effort "$p")"
    case "$m" in opus) s_opus+=("\`$n\`") ;; haiku) s_haiku+=("\`$n\`") ;; sonnet) s_sonnet=$((s_sonnet + 1)) ;; *) s_other+=("\`$n\`: ${m:-no model}") ;; esac
    [ -n "$e" ] && effort+=("\`$n\` \`$e\`")
  done
  for p in "${AGENTS[@]}"; do
    n="${p#.claude/agents/}"; n="${n%.md}"; m="$(want_model "$p")"; e="$(want_effort "$p")"
    case "$m" in opus) a_opus+=("\`$n\`") ;; sonnet) a_sonnet+=("\`$n\`") ;; inherit) a_inherit=$((a_inherit + 1)) ;; *) a_other+=("\`$n\`: ${m:-no model}") ;; esac
    [ -n "$e" ] && effort+=("\`$n\` \`$e\`")
  done
  join() { local IFS=,; local s="$*"; printf '%s' "${s//,/, }"; }
  {
    echo "> **This variant's tiers.** Generated by \`tools/ue/convert.sh\` from this tree. The"
    echo "> lists further down describe upstream and can name agents this variant removed."
    echo "> Overrides and notes: \`.claude/docs/ue-variant.md\`."
    echo ">"
    echo "> - Skills on Opus (${#s_opus[@]}): $(join "${s_opus[@]}")"
    [ "${#s_haiku[@]}" -gt 0 ] && echo "> - Skills on Haiku (${#s_haiku[@]}): $(join "${s_haiku[@]}")"
    [ "${#s_other[@]}" -gt 0 ] && echo "> - Other skills: $(join "${s_other[@]}")"
    echo "> - Skills on Sonnet: the other $s_sonnet"
    echo "> - Agents on Opus (${#a_opus[@]}): $(join "${a_opus[@]}")"
    echo "> - Agents on Sonnet (${#a_sonnet[@]}): $(join "${a_sonnet[@]}")"
    [ "${#a_other[@]}" -gt 0 ] && echo "> - Other agents: $(join "${a_other[@]}")"
    echo "> - Agents on the session's model (\`inherit\`): $a_inherit"
    echo "> - Effort pins: $(join "${effort[@]:-none}"); Sonnet runs at \`$UE_SONNET_EFFORT\` (\`modelSettings\` in \`.claude/settings.json\`)"
  } > "$STAGE/tiers"
  head -1 "$x" | grep -q '^# ' || ue_warn "model-tiers.md: no title line upstream; the generated section goes first"
  TIERS="$(cat "$STAGE/tiers")" awk 'NR == 1 { if (/^# /) { print; print ""; print ENVIRON["TIERS"]; next } else { print ENVIRON["TIERS"]; print "" } } { print }' \
    "$x" > "$x.t" && mv "$x.t" "$x"
}

edit_lp_gate() {
  local x="$1" p="$2"
  in_list lead-programmer "${UE_OPUS_AGENTS[@]}" || return 0
  sed -i -E 's/^(Agent: `lead-programmer` \| Model tier: )Sonnet/\1Opus/' "$x"
  grep -qE '^Agent: `lead-programmer` \| Model tier: Opus' "$x" || ue_warn "$p: the tier line changed upstream; not updated"
}

edit_lp_spec() {
  local x="$1"
  in_list lead-programmer "${UE_OPUS_AGENTS[@]}" || return 0
  ue_replace_text "$x" 'Model tier is `sonnet` — frontmatter `model:` reads exactly `sonnet`' \
    'Model tier is `opus` — frontmatter `model:` reads exactly `opus`' \
    || ue_warn "studio-tests lead-programmer spec: the tier line changed upstream; not updated"
}

edit_catalog() {
  local x="$1"
  awk '
    /# Engine Specialists — (Godot|Unity)/ { skip = 1; next }
    /# Engine Specialists — Unreal/        { skip = 0 }
    /^[^[:space:]]/                        { skip = 0 }
    !skip { print }' "$x" > "$x.t" && mv "$x.t" "$x"
  grep -qE '^[[:space:]]*- name: (godot|unity)-' "$x" \
    && fail "studio-tests/catalog.yaml: Godot/Unity entries remain (its section markers moved upstream)"
}

apply_pins() {
  local x="$1" p="$2"
  ue_fm_set "$x" model "$(want_model "$p")" && ue_fm_set "$x" effort "$(want_effort "$p")" \
    || fail "$p: upstream's copy has no frontmatter"
}

# --- Build every overlay file into $STAGE/x ---------------------------------------
declare -A ABSENT=()
for p in "${OVERLAY[@]}"; do
  x="$STAGE/x/$p"; mkdir -p "$(dirname "$x")"
  if ! git cat-file -e "$BASE:$p" 2>/dev/null; then
    case "$p" in
      CLAUDE.md|.claude/settings.json|.claude/hooks/update-check.sh|.claude/skills/setup-engine/SKILL.md)
        fail "upstream $BSHORT no longer has $p, which convert.sh must edit: update tools/ue/convert.sh" ;;
      .claude/skills/*|.claude/agents/*)
        fail "upstream $BSHORT no longer has $p, which lib.sh names: renamed upstream? update the lists in tools/ue/lib.sh" ;;
      *) ue_warn "upstream $BSHORT no longer has $p; it is removed here too" ;;
    esac
    ABSENT["$p"]=1
    continue
  fi
  git show "$BASE:$p" > "$x"
  case "$p" in
    CLAUDE.md) edit_claude_md "$x" ;;
    README.md) edit_readme "$x" ;;
    .claude/settings.json) edit_settings "$x" ;;
    .claude/hooks/update-check.sh) edit_update_check "$x" ;;
    .claude/skills/setup-engine/SKILL.md) edit_setup_engine "$x" ;;
    .claude/skills/setup-engine/references/7.5-scaffold.md) edit_scaffold "$x" ;;
    .claude/docs/agent-roster.md) edit_roster "$x" ;;
    .claude/docs/model-tiers.md) edit_model_tiers "$x" ;;
    .claude/docs/director-gates/lp-*.md) edit_lp_gate "$x" "$p" ;;
    studio-tests/catalog.yaml) edit_catalog "$x" ;;
    studio-tests/agents/leads/lead-programmer.md) edit_lp_spec "$x" ;;
  esac
  case "$p" in .claude/skills/*/SKILL.md|.claude/agents/*.md) apply_pins "$x" "$p" ;; esac
done

# Overlay files whose staged blob differs from what was just built.
differing() {
  local p want have
  for p in "${OVERLAY[@]}"; do
    if [ -n "${ABSENT[$p]:-}" ]; then
      git ls-files --error-unmatch -- "$p" >/dev/null 2>&1 && printf '%s\n' "$p"
      continue
    fi
    want="$(git hash-object --no-filters "$STAGE/x/$p")"
    have="$(git rev-parse -q --verify ":$p" 2>/dev/null)"
    [ "$want" = "$have" ] || printf '%s\n' "$p"
  done
}

# Skills and agents outside the overlay whose model:/effort: drifted from upstream's.
stale_pins() {
  local p
  for p in "${SKILLS[@]}" "${AGENTS[@]}"; do
    [ -n "${IS_OVERLAY[$p]:-}" ] && continue
    [ -n "${IN_BASE[$p]:-}" ] || continue
    in_conflict "$p" && continue
    if [ "${IX_M[$p]:-}" != "${UP_M[$p]:-}" ] || [ "${IX_E[$p]:-}" != "${UP_E[$p]:-}" ]; then printf '%s\n' "$p"; fi
  done
}

mapfile -t DIFF < <(differing)
mapfile -t STALE < <(stale_pins)

if [ "$MODE" = convert ]; then
  DELETED="$(git ls-files -- "${UE_DENY[@]}" | sort -u | wc -l)"
  [ "$DELETED" -eq 0 ] || git rm -r -q -f --ignore-unmatch -- "${UE_DENY[@]}" >/dev/null || fail "could not delete the Godot/Unity paths"
  for p in "${DIFF[@]}"; do
    if [ -n "${ABSENT[$p]:-}" ]; then
      git rm -q -f -- "$p" >/dev/null || fail "could not remove $p"
    else
      mkdir -p "$(dirname "$p")" && cp "$STAGE/x/$p" "$p" && git add -- "$p" || fail "could not write $p"
    fi
  done
  for p in "${STALE[@]}"; do
    git show ":$p" > "$STAGE/pin"
    ue_fm_set "$STAGE/pin" model "${UP_M[$p]:-}" && ue_fm_set "$STAGE/pin" effort "${UP_E[$p]:-}" \
      && cp "$STAGE/pin" "$p" && git add -- "$p" || fail "could not reset the model/effort lines of $p"
  done
  printf 'convert: built %s edited file(s) from upstream %s; removed %s Godot/Unity file(s); rewrote %s; reset %s stale pin(s)\n' \
    "${#OVERLAY[@]}" "$BSHORT" "$DELETED" "${#DIFF[@]}" "${#STALE[@]}"
  mapfile -t DIFF < <(differing)
  STALE=()
fi

# --- Checks ------------------------------------------------------------------------
left="$(git ls-files -- "${UE_DENY[@]}" | sort -u)"
[ -z "$left" ] || fail "Godot/Unity paths are still tracked: $(printf '%s ' $left | cut -c1-300)"
if [ "${#DIFF[@]}" -gt 0 ]; then
  fail "these differ from what convert.sh builds from upstream $BSHORT: ${DIFF[*]}"
  echo "  If you changed lib.sh or convert.sh, run bash tools/ue/convert.sh and commit." >&2
  echo "  If you edited one of them by hand, move the change into tools/ue/convert.sh." >&2
fi
for p in "${STALE[@]}"; do
  fail "$p: model '${IX_M[$p]:-}' / effort '${IX_E[$p]:-}' differ from upstream's ('${UP_M[$p]:-}' / '${UP_E[$p]:-}'), and it is not in the lib.sh lists"
done
if [ "$FAILS" -gt 0 ]; then
  printf 'convert: %s problem(s). If upstream moved something, update tools/ue/convert.sh or lib.sh.\n' "$FAILS" >&2
  exit 1
fi
echo "convert: checks passed against upstream $BSHORT"
