#!/usr/bin/env bash
# tools/ue/lib.sh: settings and helpers shared by the UE-only variant's tooling.
# Sourced by convert.sh, sync.sh, ci-sync.sh and install.sh.
# The whole process is described in .claude/docs/ue-variant.md.

# ---------------------------------------------------------------------------
# Settings. Change them here, then run `bash tools/ue/convert.sh` and commit.
# Never hand-edit the upstream files the scripts edit (see ue_overlay_files).
# ---------------------------------------------------------------------------

# The Unreal Engine version this variant pins in CLAUDE.md and /setup-engine.
UE_VERSION="5.8"
UE_LANGUAGE="C++ (primary), Blueprint (secondary)"

# Model and effort overrides (these started as PR #7).
UE_OPUS_SKILLS=(brainstorm code-review create-architecture create-epics create-stories
                design-review design-system tech-debt vertical-slice)
UE_OPUS_AGENTS=(lead-programmer)
UE_XHIGH_AGENTS=(creative-director producer technical-director)
UE_SONNET_MODEL_ID="claude-sonnet-5-5"
UE_SONNET_EFFORT="high"

# Paths the variant removes: the Godot and Unity agents, references, test specs
# and helpers. Web stays: /prototype, /start and /setup-engine are built around it,
# and it does nothing once engine.name is Unreal.
UE_DENY=(
  '.claude/agents/godot-*'
  '.claude/agents/unity-*'
  'docs/engine-reference/godot'
  'docs/engine-reference/unity'
  'studio-tests/agents/engine/godot'
  'studio-tests/agents/engine/unity'
  '.claude/scripts/godot-parse-check.gd'
  '.claude/skills/setup-engine/references/godot-language-config.md'
  'production/.gdignore'
)

# Donchitos's repository, which origin/main mirrors.
UE_UPSTREAM_URL="${UE_UPSTREAM_URL:-https://github.com/Donchitos/Claude-Code-Game-Studios.git}"

# ---------------------------------------------------------------------------
# Every upstream file convert.sh edits. sync.sh takes upstream's copy of each
# one and convert.sh re-applies the edit, so these never conflict. A hand edit
# to one of them on unreal-engine would be lost at the next sync, which is why
# sync.sh refuses to run until such an edit is moved into convert.sh.
# ---------------------------------------------------------------------------
ue_overlay_files() {
  local s a
  printf '%s\n' \
    CLAUDE.md \
    README.md \
    .claude/settings.json \
    .claude/skills/setup-engine/SKILL.md \
    .claude/skills/setup-engine/references/7.5-scaffold.md \
    .claude/docs/model-tiers.md \
    .claude/docs/director-gates/lp-code-review.md \
    .claude/docs/director-gates/lp-feasibility.md \
    studio-tests/catalog.yaml \
    studio-tests/agents/leads/lead-programmer.md
  for s in "${UE_OPUS_SKILLS[@]}"; do printf '.claude/skills/%s/SKILL.md\n' "$s"; done
  for a in "${UE_OPUS_AGENTS[@]}" "${UE_XHIGH_AGENTS[@]}"; do printf '.claude/agents/%s.md\n' "$a"; done
}

ue_warn() { printf 'WARN: %s\n' "$*" >&2; }
ue_die()  { printf 'ERROR: %s\n' "$*" >&2; exit 1; }

# Print a frontmatter key's value from the file's opening --- block.
ue_fm_get() {
  awk -v k="$2" '
    NR == 1 && /^---[[:space:]]*$/ { fm = 1; next }
    fm && /^---[[:space:]]*$/      { exit }
    fm && index($0, k ":") == 1    { sub(/^[^:]*:[[:space:]]*/, ""); print; exit }
  ' "$1"
}

# Set a frontmatter key: replace the line if the key is there, else add it after
# model: (or at the end of the block). Returns 1 if the file has no frontmatter.
ue_fm_set() {
  local f="$1" k="$2" v="$3"
  head -1 "$f" | grep -q '^---[[:space:]]*$' || return 1
  if awk -v k="$k" 'NR==1{next} /^---[[:space:]]*$/{exit} index($0, k ":")==1{found=1} END{exit !found}' "$f"; then
    awk -v k="$k" -v v="$v" '
      NR == 1 { fm = 1; print; next }
      fm && /^---[[:space:]]*$/ { fm = 0 }
      fm && index($0, k ":") == 1 { print k ": " v; next }
      { print }' "$f" > "$f.ue-tmp"
  else
    awk -v k="$k" -v v="$v" '
      NR == 1 { fm = 1; print; next }
      fm && /^model:/ { print; print k ": " v; done = 1; next }
      fm && /^---[[:space:]]*$/ { if (!done) print k ": " v; fm = 0 }
      { print }' "$f" > "$f.ue-tmp"
  fi
  mv "$f.ue-tmp" "$f"
}
