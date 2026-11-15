#!/usr/bin/env bash
# tools/ue/lib.sh: settings and helpers shared by the UE-only variant's tooling.
# Sourced by convert.sh, sync.sh, ci-sync.sh and install.sh.
# The whole process is described in .claude/docs/ue-variant.md.

# ---------------------------------------------------------------------------
# Settings. Change them here, then run `bash tools/ue/convert.sh` and commit.
# Never hand-edit the upstream files convert.sh rebuilds (see ue_overlay_files).
# ---------------------------------------------------------------------------

# The Unreal Engine version this variant pins in CLAUDE.md, /setup-engine and
# the engine block install.sh seeds into a project.
UE_VERSION="5.8"
UE_LANGUAGE="C++ (primary), Blueprint (secondary)"

# Model and effort overrides (these started as PR #7). Every other skill and
# agent keeps upstream's model: and effort: lines; convert.sh enforces that.
UE_OPUS_SKILLS=(brainstorm code-review create-architecture create-epics create-stories
                design-review design-system tech-debt vertical-slice)
UE_OPUS_AGENTS=(lead-programmer)
UE_XHIGH_AGENTS=(creative-director producer technical-director)
UE_SONNET_MODEL_ID="claude-sonnet-5-5"
UE_SONNET_EFFORT="high"

# The Unreal specialists install.sh writes into a project's project.yaml when it
# has no engine set (the same routing /setup-engine writes for Unreal).
UE_SPECIALIST_CODE="unreal-specialist"
UE_SPECIALIST_SHADER="unreal-specialist"
UE_SPECIALIST_UI="ue-umg-specialist"
UE_SPECIALIST_ADDITIONAL=(ue-gas-specialist ue-blueprint-specialist ue-replication-specialist)

# Paths the variant removes: the Godot and Unity agents, references, test specs
# and helpers, and upstream's security policy, which sends reports upstream.
# Web stays: /prototype, /start and /setup-engine are built around it, and
# install.sh sets engine.name to Unreal so those skills take the engine route.
# convert.sh also removes every file upstream keeps under .github/ (its code
# owners, funding, issue and pull-request templates, and any workflow it adds);
# only this variant's own files there stay.
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
  'SECURITY.md'
)
# This variant's own files under .github/, which the .github/ rule above keeps.
UE_OWN_GITHUB=(.github/workflows/upstream-sync.yml)

# This variant's repository, named in the README and the update notice.
UE_VARIANT_REPO="${UE_VARIANT_REPO:-spirit986/Claude-Code-Game-Studios}"
# The upstream repository, and the local ref that mirrors it. The README's credit
# and the release-notes links are derived from this one URL.
UE_UPSTREAM_URL="${UE_UPSTREAM_URL:-https://github.com/Donchitos/Claude-Code-Game-Studios.git}"
UE_UPSTREAM_WEB="$(printf '%s' "$UE_UPSTREAM_URL" | sed -E 's#\.git$##; s#^git@github\.com:#https://github.com/#')"
UE_UPSTREAM_OWNER="$(printf '%s' "$UE_UPSTREAM_WEB" | sed -E 's#^https://github\.com/([^/]+)/.*#\1#')"
# The README is generated from this template, not from upstream's README.
UE_README_TEMPLATE="tools/ue/variant-readme.md"
UE_MIRROR_REF="${UE_MIRROR_REF:-origin/main}"
# The upstream commit the converted files were last built from. convert.sh
# writes it and reads it first, so a stale origin/main cannot make it rebuild
# from an older release.
UE_BASE_FILE="tools/ue/upstream-base"

# ---------------------------------------------------------------------------
# Every upstream file convert.sh edits. It rebuilds each one from upstream's
# copy, so these never conflict, and a hand edit to one of them is caught by
# `convert.sh --check` (and sync.sh refuses to run) instead of being lost.
# ---------------------------------------------------------------------------
ue_overlay_files() {
  local s a
  printf '%s\n' \
    CLAUDE.md \
    README.md \
    UPGRADING.md \
    CHANGELOG.md \
    .claude/settings.json \
    .claude/hooks/update-check.sh \
    .claude/skills/setup-engine/SKILL.md \
    .claude/skills/setup-engine/references/7.5-scaffold.md \
    .claude/docs/agent-roster.md \
    .claude/docs/model-tiers.md \
    .claude/docs/director-gates/lp-code-review.md \
    .claude/docs/director-gates/lp-feasibility.md \
    studio-tests/catalog.yaml \
    studio-tests/agents/leads/lead-programmer.md
  for s in "${UE_OPUS_SKILLS[@]}"; do printf '.claude/skills/%s/SKILL.md\n' "$s"; done
  for a in "${UE_OPUS_AGENTS[@]}" "${UE_XHIGH_AGENTS[@]}"; do printf '.claude/agents/%s.md\n' "$a"; done
}

# 0 when a path is one UE_DENY removes.
ue_denied() {
  local p="$1" d
  for d in "${UE_DENY[@]}"; do
    # shellcheck disable=SC2053
    [[ $p == $d || $p == $d/* ]] && return 0
  done
  return 1
}

ue_warn() { printf 'WARN: %s\n' "$*" >&2; }
ue_die()  { printf 'ERROR: %s\n' "$*" >&2; exit 1; }

# Print a frontmatter key's value from a file's opening --- block.
ue_fm_get() {
  awk -v k="$2" '
    { sub(/\r$/, "") }
    NR == 1 && /^---[[:space:]]*$/ { fm = 1; next }
    NR == 1 { exit }
    fm && /^---[[:space:]]*$/      { exit }
    fm && index($0, k ":") == 1    { sub(/^[^:]*:[[:space:]]*/, ""); print; exit }
  ' "$1"
}

# Set a frontmatter key: replace the line if the key is there, else add it after
# model: (or at the end of the block). An empty value deletes the key.
# Returns 1 if the file has no frontmatter.
ue_fm_set() {
  local f="$1" k="$2" v="$3" has=0
  awk 'NR == 1 { sub(/\r$/, ""); exit !($0 ~ /^---[[:space:]]*$/) }' "$f" || return 1
  K="$k" awk 'NR == 1 { next } { sub(/\r$/, "") } /^---[[:space:]]*$/ { exit }
              index($0, ENVIRON["K"] ":") == 1 { found = 1 } END { exit !found }' "$f" && has=1
  K="$k" V="$v" H="$has" awk '
    { sub(/\r$/, "") }
    NR == 1 { fm = 1; print; next }
    fm && ENVIRON["H"] == 1 && index($0, ENVIRON["K"] ":") == 1 {
      if (ENVIRON["V"] != "") print ENVIRON["K"] ": " ENVIRON["V"]
      next }
    fm && ENVIRON["H"] == 0 && ENVIRON["V"] != "" && ENVIRON["K"] != "model" && /^model:/ {
      print; print ENVIRON["K"] ": " ENVIRON["V"]; ins = 1; next }
    fm && /^---[[:space:]]*$/ {
      if (ENVIRON["H"] == 0 && ENVIRON["V"] != "" && !ins) print ENVIRON["K"] ": " ENVIRON["V"]
      fm = 0; print; next }
    { print }
  ' "$f" > "$f.ue-tmp" && mv "$f.ue-tmp" "$f"
}

# Fill a template: every {{NAME}} becomes the value of the environment variable
# UEV_NAME, as literal text.
ue_fill_template() {
  awk '
    BEGIN { for (k in ENVIRON) if (k ~ /^UEV_/) val["{{" substr(k, 5) "}}"] = ENVIRON[k] }
    {
      for (t in val) {
        out = ""; s = $0
        while ((i = index(s, t)) > 0) { out = out substr(s, 1, i - 1) val[t]; s = substr(s, i + length(t)) }
        $0 = out s
      }
      print
    }' "$1" > "$2"
}

# Replace the first line matching an extended regex with literal text.
# Returns 1 (and leaves the file as it was) when no line matches.
ue_replace_line() {
  local f="$1"
  RE="$2" NEW="$3" awk '
    !done && $0 ~ ENVIRON["RE"] { print ENVIRON["NEW"]; done = 1; next }
    { print }
    END { exit !done }
  ' "$f" > "$f.ue-tmp"
  local rc=$?
  if [ "$rc" -eq 0 ]; then mv "$f.ue-tmp" "$f"; else rm -f "$f.ue-tmp"; fi
  return "$rc"
}

# Replace literal text inside lines, every occurrence. Returns 1 when absent.
ue_replace_text() {
  local f="$1"
  OLD="$2" NEW="$3" awk '
    BEGIN { o = ENVIRON["OLD"]; n = ENVIRON["NEW"] }
    {
      out = ""; s = $0
      while ((i = index(s, o)) > 0) { out = out substr(s, 1, i - 1) n; s = substr(s, i + length(o)); done = 1 }
      print out s
    }
    END { exit !done }
  ' "$f" > "$f.ue-tmp"
  local rc=$?
  if [ "$rc" -eq 0 ]; then mv "$f.ue-tmp" "$f"; else rm -f "$f.ue-tmp"; fi
  return "$rc"
}

# Print "path<TAB>model<TAB>effort" for every skill and agent file in a tree:
# a commit, or the index when the first argument is --cached.
ue_pins() {
  local src="$1" out
  if [ "$src" = --cached ]; then
    out="$(git grep --cached -n -E '^(---[[:space:]]*$|model:|effort:)' -- '.claude/skills/*/SKILL.md' '.claude/agents/*.md' 2>/dev/null)"
  else
    out="$(git grep -n -E '^(---[[:space:]]*$|model:|effort:)' "$src" -- '.claude/skills/*/SKILL.md' '.claude/agents/*.md' 2>/dev/null | sed "s|^$src:||")"
  fi
  printf '%s\n' "$out" | awk -F: '
    NF < 3 { next }
    {
      path = $1; n = $2; text = substr($0, length($1) + length($2) + 3); sub(/\r$/, "", text)
      if (path != cur) { flush(); cur = path; state = 0; m = ""; e = "" }
      if (state == 2) next
      if (text ~ /^---[[:space:]]*$/) { if (n == 1) state = 1; else if (state == 1) state = 2; next }
      if (state != 1) next
      if (text ~ /^model:/)  { m = text; sub(/^model:[[:space:]]*/, "", m) }
      if (text ~ /^effort:/) { e = text; sub(/^effort:[[:space:]]*/, "", e) }
    }
    function flush() { if (cur != "") printf "%s\t%s\t%s\n", cur, m, e }
    END { flush() }'
}
