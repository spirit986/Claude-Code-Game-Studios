#!/usr/bin/env bash
# tools/ue/convert.sh: turn this checkout into the UE-only variant.
#
#   bash tools/ue/convert.sh          apply the conversion, stage it, then check it
#   bash tools/ue/convert.sh --check  check only; change nothing
#
# Idempotent: on a converted tree it changes nothing. It deletes the paths in
# UE_DENY and edits only the files ue_overlay_files lists (both in lib.sh).
# A required edit fails loudly when upstream moves the text it relies on, so a
# sync stops instead of producing a half-converted tree. Edits to docs only warn.
#
# Exit: 0 converted and checked; 1 a required edit or check failed.
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib.sh
. "$HERE/lib.sh"
ROOT="$(git -C "$HERE" rev-parse --show-toplevel)" || exit 1
cd "$ROOT" || exit 1

MODE=convert
case "${1:-}" in
  "") ;;
  --check) MODE=check ;;
  -h|--help) sed -n '2,12p' "$0"; exit 0 ;;
  *) ue_die "unknown option: $1 (try --help)" ;;
esac

FAILS=0
fail() { printf 'FAIL: %s\n' "$*" >&2; FAILS=$((FAILS + 1)); }

# A file git still holds as a conflict is left alone: staging it would mark it resolved.
in_conflict() { [ -n "$(git ls-files -u -- "$1")" ]; }

# Replace a file with the output of a command that reads it.
rewrite() { local f="$1"; shift; "$@" "$f" > "$f.ue-tmp" && mv "$f.ue-tmp" "$f"; }

# --- Deletions ----------------------------------------------------------------
DELETED=0
prune() {
  DELETED=$(git ls-files -- "${UE_DENY[@]}" | sort -u | wc -l)
  [ "$DELETED" -gt 0 ] || return 0
  git rm -r -q -f --ignore-unmatch -- "${UE_DENY[@]}" >/dev/null || fail "could not delete the Godot/Unity paths"
}

# --- CLAUDE.md: the Unreal stack and reference import (required) ----------------
edit_claude_md() {
  local f=CLAUDE.md
  [ -f "$f" ] && ! in_conflict "$f" || { fail "$f is missing or in conflict"; return; }
  sed -i -E \
    -e "s/^- \*\*Engine\*\*: (\[CHOOSE.*|Unreal Engine [0-9][0-9.]*)\$/- **Engine**: Unreal Engine $UE_VERSION/" \
    -e "s/^- \*\*Language\*\*: \[CHOOSE.*/- **Language**: $UE_LANGUAGE/" \
    -e 's/^- \*\*Build System\*\*: \[SPECIFY.*/- **Build System**: Unreal Build Tool (UBT)/' \
    -e 's/^- \*\*Asset Pipeline\*\*: \[SPECIFY.*/- **Asset Pipeline**: Unreal Content Pipeline/' \
    "$f"
  if grep -qE '^@docs/engine-reference/[a-z]+/VERSION\.md' "$f"; then
    sed -i -E 's|^@docs/engine-reference/[a-z]+/VERSION\.md|@docs/engine-reference/unreal/VERSION.md|' "$f"
  elif grep -q 'ENGINE-REFERENCE-IMPORT' "$f"; then
    # 1.3.0 ships no import line until an engine is set: add it under the marker comment.
    rewrite "$f" awk '{ print } /ENGINE-REFERENCE-IMPORT/ { m = 1 }
      m && /-->/ { print "@docs/engine-reference/unreal/VERSION.md"; m = 0 }'
  fi
  # Optional: the note that tells readers to pick an engine's agent set.
  if grep -q '^> \*\*Note\*\*: Engine-specialist agents exist for Godot, Unity, and Unreal' "$f"; then
    NOTE="> **Note**: UE-only variant: only the Unreal specialists (\`unreal-specialist\` and the \`ue-*\` sub-specialists) are installed. See \`.claude/docs/ue-variant.md\`." \
    rewrite "$f" awk '
      skip && /^>/ { next }
      { skip = 0 }
      /^> \*\*Note\*\*: Engine-specialist agents exist for Godot, Unity, and Unreal/ { print ENVIRON["NOTE"]; skip = 1; next }
      { print }'
  elif ! grep -q 'UE-only variant: only the Unreal specialists' "$f"; then
    ue_warn "$f: the engine-specialist note changed upstream; left as it is"
  fi
}

# --- README.md: one-line banner (optional) --------------------------------------
edit_readme() {
  local f=README.md
  [ -f "$f" ] && ! in_conflict "$f" || { ue_warn "$f is missing or in conflict; no banner"; return; }
  grep -qF '> **UE-only variant.**' "$f" && return
  BANNER="> **UE-only variant.** Godot and Unity are removed, and upstream releases arrive as pull requests. See [.claude/docs/ue-variant.md](.claude/docs/ue-variant.md)." \
  rewrite "$f" awk 'NR == 1 { print; print ""; print ENVIRON["BANNER"]; next } { print }'
}

# --- /setup-engine: Unreal by default (required) ---------------------------------
edit_setup_engine() {
  local f=.claude/skills/setup-engine/SKILL.md
  local desc="description: \"Sets up and pins the Unreal Engine version for this project (UE-only variant). Use to set up or upgrade it.\""
  local note="UE-only variant: with no arguments, run as \`/setup-engine unreal $UE_VERSION\` and skip engine selection, which would otherwise default to Web."
  [ -f "$f" ] && ! in_conflict "$f" || { fail "$f is missing or in conflict"; return; }
  # The description is in every session's skill list; upstream's says "web for a new project".
  if grep -q '^description:' "$f"; then
    sed -i -E "0,/^description:/s|^description:.*|$desc|" "$f"
  else
    fail "$f: no description line"
  fi
  if grep -q '^UE-only variant: with no arguments' "$f"; then
    sed -i -E "s|^UE-only variant: with no arguments.*|$note|" "$f"
  elif grep -q '^## 2\. Guided Mode' "$f"; then
    NOTE="$note" rewrite "$f" awk '{ print } /^## 2\. Guided Mode/ { print ""; print ENVIRON["NOTE"] }'
  else
    fail "$f: the '## 2. Guided Mode' heading moved upstream"
  fi
}

# --- /setup-engine 7.5: the .uproject belongs at the repo root (optional) ----------
edit_scaffold() {
  local f=.claude/skills/setup-engine/references/7.5-scaffold.md
  [ -f "$f" ] && ! in_conflict "$f" || { ue_warn "$f is missing or in conflict"; return; }
  grep -q 'sits at the repo root' "$f" && return
  if grep -q '^- \*\*Unreal\*\* — create the project in the Epic launcher' "$f"; then
    rewrite "$f" awk '
      skip && /^  / { next }
      { skip = 0 }
      /^- \*\*Unreal\*\* — create the project in the Epic launcher/ {
        print "- **Unreal** — create the project in the Epic launcher or via `UnrealEditor`,"
        print "  then move its contents up so the `.uproject` sits at the repo root: the"
        print "  launcher makes a subfolder, and the UE scripts look for the `.uproject` only"
        print "  at the root. Then re-run."
        skip = 1; next }
      { print }'
  else
    ue_warn "$f: the Unreal scaffold line changed upstream; left as it is"
  fi
}

# --- studio-tests catalog: drop the deleted agents' entries (required) ---------------
edit_catalog() {
  local f=studio-tests/catalog.yaml
  [ -f "$f" ] || { ue_warn "$f is missing"; return; }
  in_conflict "$f" && { fail "$f is in conflict"; return; }
  grep -qE '^[[:space:]]*- name: (godot|unity)-' "$f" || return
  rewrite "$f" awk '
    /# Engine Specialists — (Godot|Unity)/ { skip = 1; next }
    /# Engine Specialists — Unreal/        { skip = 0 }
    /^[^[:space:]]/                        { skip = 0 }
    !skip { print }'
}

# --- Model and effort (required), plus the docs that state them (optional) -----------
edit_models() {
  local s a f
  for s in "${UE_OPUS_SKILLS[@]}"; do
    f=".claude/skills/$s/SKILL.md"
    [ -f "$f" ] && ! in_conflict "$f" || { fail "$f is missing or in conflict (skill renamed upstream? update UE_OPUS_SKILLS)"; continue; }
    ue_fm_set "$f" model opus || fail "$f has no frontmatter"
  done
  for a in "${UE_OPUS_AGENTS[@]}"; do
    f=".claude/agents/$a.md"
    [ -f "$f" ] && ! in_conflict "$f" || { fail "$f is missing or in conflict (update UE_OPUS_AGENTS)"; continue; }
    ue_fm_set "$f" model opus || fail "$f has no frontmatter"
  done
  for a in "${UE_XHIGH_AGENTS[@]}"; do
    f=".claude/agents/$a.md"
    [ -f "$f" ] && ! in_conflict "$f" || { fail "$f is missing or in conflict (update UE_XHIGH_AGENTS)"; continue; }
    ue_fm_set "$f" effort xhigh || fail "$f has no frontmatter"
  done
  f=.claude/settings.json
  if [ ! -f "$f" ] || in_conflict "$f"; then
    fail "$f is missing or in conflict"
  elif ! command -v jq >/dev/null 2>&1; then
    fail "jq is needed to edit $f"
  elif ! jq -e --arg m "$UE_SONNET_MODEL_ID" --arg e "$UE_SONNET_EFFORT" \
         '.modelSettings[$m].effortLevel == $e' "$f" >/dev/null 2>&1; then
    rewrite "$f" jq --indent 2 --arg m "$UE_SONNET_MODEL_ID" --arg e "$UE_SONNET_EFFORT" \
      '.modelSettings = ((.modelSettings // {}) + {($m): ((.modelSettings[$m] // {}) + {effortLevel: $e})})' \
      || fail "could not write modelSettings into $f"
  fi

  # Docs: a pointer at the top of model-tiers.md, and lead-programmer's tier lines.
  f=.claude/docs/model-tiers.md
  if [ -f "$f" ] && ! in_conflict "$f" && ! grep -qF '> **UE-only variant:**' "$f"; then
    POINTER="> **UE-only variant:** the model and effort overrides in \`.claude/docs/ue-variant.md\` (Model and effort) win over the tier lists below." \
    rewrite "$f" awk 'NR == 1 { print; print ""; print ENVIRON["POINTER"]; next } { print }'
  fi
  case " ${UE_OPUS_AGENTS[*]} " in
    *" lead-programmer "*)
      for f in .claude/docs/director-gates/lp-code-review.md .claude/docs/director-gates/lp-feasibility.md; do
        [ -f "$f" ] && ! in_conflict "$f" || { ue_warn "$f is missing or in conflict"; continue; }
        sed -i -E 's/^(Agent: `lead-programmer` \| Model tier: )Sonnet/\1Opus/' "$f"
        grep -qE '^Agent: `lead-programmer` \| Model tier: Opus' "$f" || ue_warn "$f: the tier line changed upstream; not updated"
      done
      f=studio-tests/agents/leads/lead-programmer.md
      if [ -f "$f" ] && ! in_conflict "$f"; then
        sed -i 's/Model tier is `sonnet` — frontmatter `model:` reads exactly `sonnet`/Model tier is `opus` — frontmatter `model:` reads exactly `opus`/' "$f"
        grep -q 'reads exactly `opus`' "$f" || ue_warn "$f: the tier line changed upstream; not updated"
      fi
      ;;
  esac
}

stage() {
  local f
  while IFS= read -r f; do
    [ -f "$f" ] && ! in_conflict "$f" && git add -- "$f"
  done < <(ue_overlay_files | sort -u)
}

# --- Checks (also run with --check) ----------------------------------------------
checks() {
  local f s a v left
  left="$(git ls-files -- "${UE_DENY[@]}" | sort -u)"
  [ -z "$left" ] || fail "Godot/Unity paths are still tracked: $(printf '%s ' $left | cut -c1-300)"
  f=CLAUDE.md
  grep -qxF -- "- **Engine**: Unreal Engine $UE_VERSION" "$f" || fail "$f: the Engine line is not 'Unreal Engine $UE_VERSION'"
  grep -qx '@docs/engine-reference/unreal/VERSION.md' "$f" || fail "$f: the Unreal reference import is missing"
  grep -qE '^@docs/engine-reference/(godot|unity|web)/' "$f" && fail "$f: imports another engine's reference"
  f=.claude/skills/setup-engine/SKILL.md
  grep -q '^description: .*UE-only variant' "$f" || fail "$f: the description is not the UE-only one"
  grep -qF "UE-only variant: with no arguments, run as \`/setup-engine unreal $UE_VERSION\`" "$f" \
    || fail "$f: the no-arguments note for Unreal $UE_VERSION is missing"
  f=studio-tests/catalog.yaml
  [ -f "$f" ] && grep -qE '^[[:space:]]*- name: (godot|unity)-' "$f" && fail "$f: Godot/Unity entries remain (its section markers moved upstream?)"
  for s in "${UE_OPUS_SKILLS[@]}"; do
    f=".claude/skills/$s/SKILL.md"
    [ -f "$f" ] && v="$(ue_fm_get "$f" model)" && [ "$v" = opus ] || fail "$f: model is '${v:-missing}', expected opus"
  done
  for a in "${UE_OPUS_AGENTS[@]}"; do
    f=".claude/agents/$a.md"
    [ -f "$f" ] && v="$(ue_fm_get "$f" model)" && [ "$v" = opus ] || fail "$f: model is '${v:-missing}', expected opus"
  done
  for a in "${UE_XHIGH_AGENTS[@]}"; do
    f=".claude/agents/$a.md"
    [ -f "$f" ] && v="$(ue_fm_get "$f" effort)" && [ "$v" = xhigh ] || fail "$f: effort is '${v:-missing}', expected xhigh"
    [ -f "$f" ] && [ "$(awk 'NR==1{next} /^---/{exit} /^effort:/' "$f" | wc -l)" -le 1 ] || fail "$f: more than one effort line"
  done
  f=.claude/settings.json
  jq -e --arg m "$UE_SONNET_MODEL_ID" --arg e "$UE_SONNET_EFFORT" '.modelSettings[$m].effortLevel == $e' "$f" >/dev/null 2>&1 \
    || fail "$f: modelSettings.$UE_SONNET_MODEL_ID.effortLevel is not $UE_SONNET_EFFORT (or the file is not valid JSON)"
  while IFS= read -r f; do
    [ -f "$f" ] && grep -qE '^(<<<<<<<|>>>>>>>)( |$)' "$f" && fail "$f: contains conflict markers"
  done < <(ue_overlay_files | sort -u)
}

if [ "$MODE" = convert ]; then
  prune
  edit_claude_md
  edit_readme
  edit_setup_engine
  edit_scaffold
  edit_catalog
  edit_models
  stage
  printf 'convert: removed %s Godot/Unity file(s); applied the UE edits (Unreal Engine %s)\n' "$DELETED" "$UE_VERSION"
fi
checks
if [ "$FAILS" -gt 0 ]; then
  printf 'convert: %s problem(s). If upstream moved something, update tools/ue/convert.sh or lib.sh.\n' "$FAILS" >&2
  exit 1
fi
echo "convert: checks passed"
