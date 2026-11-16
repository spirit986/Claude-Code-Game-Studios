#!/usr/bin/env bash
# tools/ue/lib.sh: settings and helpers shared by the UE-only variant's tooling.
# Sourced by convert.sh, sync.sh, ci-sync.sh and install.sh.
# The whole process is described in .claude/docs/ue-variant.md.

ue_warn() { printf 'WARN: %s\n' "$*" >&2; }
ue_die()  { printf 'ERROR: %s\n' "$*" >&2; exit 1; }

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
# and helpers; upstream's security policy, which sends reports upstream; and its
# contributing guide, which describes its own review process (code owners,
# issues, release-note credits) and is linked from the new-PR page.
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
  'CONTRIBUTING.md'
)
# This variant's own files under .github/, which the .github/ rule above keeps.
UE_OWN_GITHUB=(.github/workflows/upstream-sync.yml)

# This variant's repository, named in the README and the update notice.
UE_VARIANT_REPO="${UE_VARIANT_REPO:-spirit986/Claude-Code-Game-Studios}"
# The upstream repository on GitHub, as <owner>/<name>. The README's credit, the
# release-notes link and the name check are built from it, so the name is
# written once. It is a setting of its own, not parsed from UE_UPSTREAM_URL, so
# a fetch URL with a token in it never reaches the README or a pull request.
UE_UPSTREAM_SLUG="${UE_UPSTREAM_SLUG:-Donchitos/Claude-Code-Game-Studios}"
_ue_slug_re='^[A-Za-z0-9-]+/[A-Za-z0-9._-]+$'
[[ $UE_UPSTREAM_SLUG =~ $_ue_slug_re ]] || ue_die "UE_UPSTREAM_SLUG must be <owner>/<name> on GitHub"
[[ $UE_VARIANT_REPO =~ $_ue_slug_re ]] || ue_die "UE_VARIANT_REPO must be <owner>/<name> on GitHub"
UE_UPSTREAM_OWNER="${UE_UPSTREAM_SLUG%%/*}"
UE_UPSTREAM_WEB="https://github.com/$UE_UPSTREAM_SLUG"
# Where the sync fetches upstream from. Override it for a mirror or a URL with
# credentials: it is only fetched from, never written into a file.
UE_UPSTREAM_URL="${UE_UPSTREAM_URL:-$UE_UPSTREAM_WEB.git}"
# The only files, besides README.md's Credit section, that may name upstream's
# author: convert.sh --check fails on any other mention, so the name cannot
# spread through the variant unnoticed. LICENSE: MIT needs its notice kept.
# update-check.sh: it watches upstream's releases. /start, its test spec and
# effects-map.md: upstream's warning when a clone still points at upstream.
UE_NAME_OK=(LICENSE tools/ue/lib.sh .claude/hooks/update-check.sh
            .claude/skills/start/SKILL.md .claude/docs/effects-map.md
            studio-tests/skills/utility/start.md)
# Files convert.sh generates from this variant's own templates instead of
# rebuilding upstream's copy. README.md comes from UE_README_TEMPLATE, with
# upstream's Configuration section pulled in.
UE_GENERATED=(README.md)
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

# Print the owner/name of a GitHub repository URL: https (with or without
# user:token@), git@github.com: or ssh://git@github.com/. Returns 1 otherwise.
ue_github_slug() {
  local u="${1%/}"
  u="${u%.git}"
  case "$u" in
    https://github.com/*|http://github.com/*) u="${u#*://github.com/}" ;;
    https://*@github.com/*|http://*@github.com/*) u="${u#*@github.com/}" ;;
    git@github.com:*) u="${u#git@github.com:}" ;;
    ssh://git@github.com/*) u="${u#ssh://git@github.com/}" ;;
    *) return 1 ;;
  esac
  [[ $u =~ $_ue_slug_re ]] || return 1
  printf '%s\n' "$u"
}

# A URL with any user:password@ taken out, for messages.
ue_redact_url() {
  local u="$1"
  case "$u" in *://*@*) u="${u%%://*}://${u#*@}" ;; esac
  printf '%s' "$u"
}

# awk functions the helpers below share. replace_all(s, old, new): s with every
# occurrence of the literal text old replaced by new.
UE_AWK_LIB='
function replace_all(s, o, n,    out, i) {
  if (o == "") return s
  out = ""
  while ((i = index(s, o)) > 0) { out = out substr(s, 1, i - 1) n; s = substr(s, i + length(o)) }
  return out s
}
'

# Fill a template and print it: every {{NAME}} becomes the value of the
# environment variable UEV_NAME, as literal text. CRs are dropped, so a template
# checked out CRLF (core.autocrlf on Windows) builds the same file. A comment
# that opens the template (its note to whoever edits it) is left out.
ue_fill_template() {
  awk "$UE_AWK_LIB"'
    BEGIN { for (k in ENVIRON) if (k ~ /^UEV_/) val["{{" substr(k, 5) "}}"] = ENVIRON[k] }
    { sub(/\r$/, "") }
    NR == 1 && /^<!--/ { note = 1 }
    note { if (/-->/) { note = 0; gap = 1 } next }
    gap && /^[[:space:]]*$/ { next }
    { gap = 0; for (t in val) if (index($0, t)) $0 = replace_all($0, t, val[t]); print }
  ' "$1"
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
  OLD="$2" NEW="$3" awk "$UE_AWK_LIB"'
    index($0, ENVIRON["OLD"]) { $0 = replace_all($0, ENVIRON["OLD"], ENVIRON["NEW"]); done = 1 }
    { print }
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
