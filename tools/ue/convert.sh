#!/usr/bin/env bash
# tools/ue/convert.sh: build the UE-only variant from upstream, or check it.
#
#   bash tools/ue/convert.sh [--base <commit>]          rebuild, stage, then check
#   bash tools/ue/convert.sh --check [--base <commit>]  check only; change nothing
#
# Every file convert.sh edits (ue_overlay_files in lib.sh) is rebuilt from
# upstream's copy at <commit>, then edited, and the files it generates
# (UE_GENERATED: README.md) are built from their templates in tools/ue/. The
# result depends only on upstream, lib.sh, the templates and which agents and
# skills the tree has, so changing a setting and re-running applies it, and
# --check is an exact comparison. <commit> defaults to the merge in progress
# (MERGE_HEAD), else to the merge base of HEAD and $UE_MIRROR_REF (origin/main):
# the upstream release this branch last merged.
#
# It also deletes the paths in UE_DENY and everything upstream keeps under
# .github/ (but not UE_OWN_GITHUB), and keeps the model: and effort: lines of
# every skill and agent outside the lib.sh lists equal to upstream's, so a pin
# removed from lib.sh does not linger. The checks also fail when upstream's
# author is named anywhere but README.md's Credit section and UE_NAME_OK.
#
# Required edits fail when upstream moves the text they rely on; edits to docs
# only warn. Upstream's files are read and compared as git blobs, and templates
# are read with CRs dropped, so core.autocrlf does not matter. This variant's
# own files (lib.sh, convert.sh, the templates) are read as they are on disk:
# edit one, run convert.sh, and commit both.
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
    -h|--help) sed -n '2,28p' "$0"; exit 0 ;;
    *) ue_die "unknown option: $1 (try --help)" ;;
  esac
  shift
done
RECORDED=""
[ -f "$UE_BASE_FILE" ] && RECORDED="$(tr -d '\r' < "$UE_BASE_FILE" | awk 'NF && !/^#/ { print $1; exit }')"
if [ -z "$BASE" ]; then
  if git rev-parse -q --verify MERGE_HEAD >/dev/null; then
    BASE=MERGE_HEAD
  elif [ -n "$RECORDED" ] && git merge-base --is-ancestor "$RECORDED" HEAD 2>/dev/null; then
    BASE="$RECORDED"
  elif git rev-parse -q --verify "$UE_MIRROR_REF^{commit}" >/dev/null; then
    [ -n "$RECORDED" ] && ue_warn "$UE_BASE_FILE names $RECORDED, which HEAD does not contain; using the merge base with $UE_MIRROR_REF"
    BASE="$(git merge-base HEAD "$UE_MIRROR_REF")" || ue_die "HEAD and $UE_MIRROR_REF share no history"
  else
    ue_die "cannot tell which upstream release to build from: no $UE_BASE_FILE and no $UE_MIRROR_REF. Run git fetch origin main, or pass --base <commit>."
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
GENERATED=("${UE_GENERATED[@]}")
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
# then upstream's value, then (for a file upstream does not have) its own. The
# answers go to WANT_M and WANT_E, not to stdout: a $(...) per file is a fork per
# file, and forks are slow on Windows.
want_pins() {
  local p="$1" n
  if [ -n "${IN_BASE[$p]:-}" ]; then WANT_M="${UP_M[$p]:-}"; WANT_E="${UP_E[$p]:-}"
  else WANT_M="${IX_M[$p]:-}"; WANT_E="${IX_E[$p]:-}"; fi
  case "$p" in
    .claude/skills/*/SKILL.md) n="${p#.claude/skills/}"; n="${n%/SKILL.md}"; in_list "$n" "${UE_OPUS_SKILLS[@]}" && WANT_M=opus ;;
    .claude/agents/*.md) n="${p#.claude/agents/}"; n="${n%.md}"
      in_list "$n" "${UE_OPUS_AGENTS[@]}" && WANT_M=opus
      in_list "$n" "${UE_XHIGH_AGENTS[@]}" && WANT_E=xhigh ;;
  esac
  return 0
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

# --- The files convert.sh generates ------------------------------------------------
# README.md is this variant's own, built from tools/ue/variant-readme.md.
# Upstream's README (its install steps, links and sponsor badges) is not used,
# except for its Configuration section: it explains project.yaml's settings, and
# docs/migration-guide-v1.1.md links to it.
build_readme() {
  local x="$1" p shims=0 conf hits
  local -A shim=()
  [ -f "$UE_README_TEMPLATE" ] || { fail "$UE_README_TEMPLATE is missing"; return; }
  # Count skills as upstream does: a shim kept for a renamed skill (its
  # description starts "Old name of /x") is not a skill of its own. Shims are
  # upstream's, so they are found in upstream's tree, whatever state the index
  # is in mid-merge, and counted from SKILLS, the same list as the skills.
  while IFS= read -r p; do shim["${p#"$BASE":}"]=1; done \
    < <(git grep -l -i -E "^description:[[:space:]]*[\"']?Old name of /" "$BASE" -- '.claude/skills/*/SKILL.md' 2>/dev/null)
  for p in "${SKILLS[@]}"; do [ -n "${shim[$p]:-}" ] && shims=$((shims + 1)); done
  conf="$(git show "$BASE:README.md" 2>/dev/null | awk '
    { sub(/\r$/, "") }
    /^## / { p = ($0 ~ /^## Configuration[[:space:]]*$/) }
    p { print }')"
  if [ -z "$conf" ]; then
    ue_warn "README.md: upstream's README has no '## Configuration' section; the README points at effects-map.md instead"
    conf="## Configuration

Every \`project.yaml\` setting and what it changes: \`.claude/docs/effects-map.md\`.
View or change one with \`/project-settings\`."
  fi
  {
    printf '%s\n\n' "<!-- Generated by tools/ue/convert.sh from $UE_README_TEMPLATE: edit the template, not this file. -->"
    UEV_AGENTS="$AGENT_COUNT" UEV_SKILLS="$(( ${#SKILLS[@]} - shims ))" UEV_UE_VERSION="$UE_VERSION" \
    UEV_VARIANT_REPO="$UE_VARIANT_REPO" UEV_UPSTREAM_WEB="$UE_UPSTREAM_WEB" UEV_UPSTREAM_OWNER="$UE_UPSTREAM_OWNER" \
    UEV_UPSTREAM_CONFIGURATION="$conf" \
      ue_fill_template "$UE_README_TEMPLATE"
  } > "$x" || fail "could not generate README.md"
  grep -qE '\{\{[A-Z_]+\}\}' "$x" && fail "README.md: a {{NAME}} placeholder in $UE_README_TEMPLATE has no value"
  # Upstream's author is named in the Credit section and nowhere else.
  hits="$(OWNER="$UE_UPSTREAM_OWNER" awk '
    BEGIN { o = tolower(ENVIRON["OWNER"]) }
    /^## / { credit = ($0 ~ /^## Credit[[:space:]]*$/) }
    !credit && index(tolower($0), o) { printf "%s ", NR }' "$x")"
  [ -z "$hits" ] || fail "README.md names upstream's author outside its Credit section, on line(s) $hits(from $UE_README_TEMPLATE or upstream's Configuration section)"
}

# --- The edits, continued ------------------------------------------------------------
# Upstream's links to itself become plain text, in any letter case, with http
# or www, a #fragment or a sub-path: [#12](<upstream>/issues/12) and a bare
# <upstream>/pull/12/files become "upstream #12", [see #12](...) becomes
# "see upstream #12", [text](...) with another number becomes "text (upstream
# #N)", and a link with no number keeps only its text. What this cannot rewrite
# (a bare URL with no number, a reference-style link) is left, and the name check
# at the end reports it.
unlink_upstream() {
  local x="$1"
  SLUG="$UE_UPSTREAM_SLUG" awk "$UE_AWK_LIB"'
    function isname(c) { return c ~ /[A-Za-z0-9_-]/ }
    BEGIN { key = tolower("github.com/" ENVIRON["SLUG"]); kl = length(key) }
    {
      line = $0; out = ""
      while ((i = index(tolower(line), key)) > 0) {
        low = tolower(line); s = i; e = i + kl
        if (s > 4 && substr(low, s - 4, 4) == "www.") s -= 4
        if (s > 8 && substr(low, s - 8, 8) == "https://") s -= 8
        else if (s > 7 && substr(low, s - 7, 7) == "http://") s -= 7
        # A longer name (Claude-Code-Game-Studios-2) is another repository.
        c = substr(line, e, 1)
        if (isname(c) || (c == "." && isname(substr(line, e + 1, 1)) && !(substr(low, e, 4) == ".git" && !isname(substr(line, e + 4, 1))))) {
          out = out substr(line, 1, e - 1); line = substr(line, e); continue
        }
        rest = substr(line, e)
        match(rest, /^[^]()<>"[:space:]]*/); ul = RLENGTH
        while (ul > 0 && substr(rest, ul, 1) ~ /[.,;:!?]/) ul--
        path = substr(rest, 1, ul); post = substr(rest, ul + 1); pre = substr(line, 1, s - 1)
        n = ""
        if (match(path, /^(\.git)?\/(issues|pull|discussions)\/[0-9]+/)) { n = substr(path, RSTART, RLENGTH); sub(/.*\//, "", n) }
        j = 0
        if (substr(pre, length(pre) - 1) == "](" && substr(post, 1, 1) == ")")
          for (k = length(pre) - 2; k > 0; k--) if (substr(pre, k, 1) == "[") { j = k; break }
        if (j > 0) {
          # An inline link: [text](url)
          text = substr(pre, j + 1, length(pre) - j - 2); pre = substr(pre, 1, j - 1); post = substr(post, 2)
          if (n == "") r = text
          else if (text ~ /^#?[0-9]+$/) r = "upstream #" n
          else if (index(text, "#" n)) r = replace_all(text, "#" n, "upstream #" n)
          else r = text " (upstream #" n ")"
        } else if (n != "" && substr(pre, length(pre)) == "<" && substr(post, 1, 1) == ">") {
          pre = substr(pre, 1, length(pre) - 1); post = substr(post, 2); r = "upstream #" n
        } else if (n != "" && pre !~ /^[[:space:]]*\[[^]]*\]:[[:space:]]*$/) {
          r = "upstream #" n
        } else {
          r = substr(line, s, e - s + ul)
        }
        out = out pre r; line = post
      }
      print out line
    }' "$x" > "$x.t" && mv "$x.t" "$x"
}

edit_upgrading() {
  local x="$1" left
  # The release sections stay: they list each release's changes and one-off
  # steps. Upstream's upgrade strategies merge or copy upstream into a project,
  # which brings the Godot and Unity files back, so the strategies section
  # points at install.sh instead.
  if grep -q '^## Upgrade Strategies' "$x"; then
    TEXT="This is the UE-only variant: update a project with \`tools/ue/install.sh\`, as \`.claude/docs/ue-variant.md\` describes, never by merging or copying upstream's files into it, which brings back the Godot and Unity files and undoes the variant's changes. The release sections below say what each release changed. Their file lists (Safe to Overwrite, Merge Carefully, Delete) are what \`install.sh\` does for you: it updates the files you have not changed, merges the ones you have, removes the ones a release deletes, and leaves out the files this variant removes, even where a list names them. What is left for you are the steps for the files it adds once and then leaves to you: \`project.yaml\`, \`technical-preferences.md\` and the registries." \
    awk '
      /^## Upgrade Strategies/ { print; print ""; print ENVIRON["TEXT"]; print ""; skip = 1; next }
      skip && /^## / { skip = 0 }
      !skip { print }' "$x" > "$x.t" && mv "$x.t" "$x"
  else
    ue_warn "UPGRADING.md: the '## Upgrade Strategies' heading changed upstream; left as it is"
  fi
  # The release sections' steps for those strategies go too: each "With
  # Strategy A2, also check out ... git checkout template/main -- ..." paragraph
  # (it restores the Godot, Unity and SECURITY.md files this variant removes,
  # from a remote the variant never adds), each "**Strategy A:** the merge has
  # already ..." note, and each "> **Strategy A ...**" aside. One sentence about
  # what the merge does to docs/engine-reference/ is reworded for install.sh.
  OLD1=" With Strategy A
the merge takes the new folder without asking; only a file you edited (usually
\`VERSION.md\`) conflicts. To keep yours, run \`git checkout HEAD -- docs/engine-reference/<engine>/\` before you commit the merge." \
  NEW1=" \`install.sh\` takes the new folder and merges
the files you edited (usually \`VERSION.md\`); to keep your folder, run \`git checkout HEAD -- docs/engine-reference/<engine>/\` after the install." \
  awk "$UE_AWK_LIB"'
    function strategy_only(p) {
      return p ~ /^With Strateg(y|ies) / || p ~ /^\*\*Strateg(y|ies) [A-C][0-9]*:\*\*/ || p ~ /^> \*\*Strateg(y|ies) / || index(p, "template/main") > 0
    }
    function flush() {
      if (buf != "") {
        if (strategy_only(buf)) dropped = 1
        else printf "%s", replace_all(buf, ENVIRON["OLD1"], ENVIRON["NEW1"])
      }
      buf = ""
    }
    /^[[:space:]]*$/ { flush(); if (dropped) { dropped = 0; next } print; next }
    { buf = buf $0 "\n" }
    END { flush() }' "$x" > "$x.t" && mv "$x.t" "$x"
  # Upstream rewords these at times: whatever is left fails the check, so a
  # step that would restore the removed files is never shipped unnoticed.
  left="$(awk '/template\/main|Strateg(y|ies) [A-C]/ { printf "%s ", NR }' "$x")"
  [ -z "$left" ] || fail "UPGRADING.md still has steps for upstream's upgrade strategies, on line(s) $left(they merge or copy upstream into a project): drop them in edit_upgrading in tools/ue/convert.sh"
  unlink_upstream "$x"
}

edit_changelog() {
  unlink_upstream "$1"
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
  # The version check still watches upstream (the earliest signal of a release);
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
    n="${p#.claude/skills/}"; n="/${n%/SKILL.md}"; want_pins "$p"; m="$WANT_M"; e="$WANT_E"
    case "$m" in opus) s_opus+=("\`$n\`") ;; haiku) s_haiku+=("\`$n\`") ;; sonnet) s_sonnet=$((s_sonnet + 1)) ;; *) s_other+=("\`$n\`: ${m:-no model}") ;; esac
    [ -n "$e" ] && effort+=("\`$n\` \`$e\`")
  done
  for p in "${AGENTS[@]}"; do
    n="${p#.claude/agents/}"; n="${n%.md}"; want_pins "$p"; m="$WANT_M"; e="$WANT_E"
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
  want_pins "$p"
  ue_fm_set "$x" model "$WANT_M" && ue_fm_set "$x" effort "$WANT_E" \
    || fail "$p: upstream's copy has no frontmatter"
}

# --- Build every overlay file into $STAGE/x ---------------------------------------
# Upstream's copies come out of one archive, not one git run per file. With
# autocrlf off and eol=lf, the archive writes each file as git stores it (the
# repo's attributes ask for LF on these files anyway).
declare -A ABSENT=() IN_UP=()
while IFS= read -r p; do IN_UP["$p"]=1; done < <(git ls-tree -r --name-only "$BASE" -- "${OVERLAY[@]}")
UPFILES=()
for p in "${OVERLAY[@]}"; do [ -n "${IN_UP[$p]:-}" ] && UPFILES+=("$p"); done
mkdir -p "$STAGE/x"
if [ "${#UPFILES[@]}" -gt 0 ]; then
  git -c core.autocrlf=false -c core.eol=lf archive --format=tar "$BASE" -- "${UPFILES[@]}" | tar -x -C "$STAGE/x" \
    || ue_die "could not read upstream $BSHORT's copies of the files convert.sh edits"
fi
for p in "${OVERLAY[@]}"; do
  x="$STAGE/x/$p"
  if [ -z "${IN_UP[$p]:-}" ]; then
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
  case "$p" in
    CLAUDE.md) edit_claude_md "$x" ;;
    UPGRADING.md) edit_upgrading "$x" ;;
    CHANGELOG.md) edit_changelog "$x" ;;
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
# The generated files need no upstream copy (README.md reads one section of
# upstream's README itself), so a conflict in one is resolved by writing it.
for p in "${GENERATED[@]}"; do
  x="$STAGE/x/$p"
  case "$p" in
    README.md) build_readme "$x" ;;
    *) fail "UE_GENERATED names $p, which convert.sh has no build step for" ;;
  esac
done

# Built files whose staged blob differs from what was just built: one
# hash-object and one ls-files for all of them.
differing() {
  local p i mode sha stage path
  local -A have=() want=() tracked=()
  local -a built=() all=("${OVERLAY[@]}" "${GENERATED[@]}")
  # Stage 0 is the resolved blob; any stage means the index still has the path
  # (an upstream deletion in conflict, say, which then needs its git rm).
  while read -r mode sha stage path; do
    tracked["$path"]=1
    [ "$stage" = 0 ] && have["$path"]="$sha"
  done < <(git ls-files -s -- "${all[@]}")
  for p in "${all[@]}"; do [ -z "${ABSENT[$p]:-}" ] && built+=("$p"); done
  if [ "${#built[@]}" -gt 0 ]; then
    mapfile -t sums < <(for p in "${built[@]}"; do printf '%s\n' "$STAGE/x/$p"; done | git hash-object --no-filters --stdin-paths)
    for i in "${!built[@]}"; do want["${built[$i]}"]="${sums[$i]:-}"; done
  fi
  for p in "${all[@]}"; do
    if [ -n "${ABSENT[$p]:-}" ]; then
      [ -n "${tracked[$p]:-}" ] && printf '%s\n' "$p"
      continue
    fi
    [ -n "${want[$p]:-}" ] && [ "${want[$p]}" = "${have[$p]:-}" ] || printf '%s\n' "$p"
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

# Everything upstream keeps under .github/ goes too (its code owners, funding,
# issue and pull-request templates, and any workflow it adds); this variant's
# own files there (UE_OWN_GITHUB) stay.
DENY=("${UE_DENY[@]}")
while IFS= read -r p; do
  in_list "$p" "${UE_OWN_GITHUB[@]}" || DENY+=("$p")
done < <(git ls-tree -r --name-only "$BASE" -- .github)

if [ "$MODE" = convert ]; then
  DELETED="$(git ls-files -- "${DENY[@]}" | sort -u | wc -l)"
  [ "$DELETED" -eq 0 ] || git rm -r -q -f --ignore-unmatch -- "${DENY[@]}" >/dev/null || fail "could not delete the removed paths"
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
  if [ "$RECORDED" != "$BASE" ]; then
    { echo "# The upstream commit tools/ue/convert.sh last built from. Written by convert.sh."
      echo "$BASE $(git describe --tags --always "$BASE" 2>/dev/null)"; } > "$UE_BASE_FILE" \
      && git add -- "$UE_BASE_FILE" || fail "could not write $UE_BASE_FILE"
  fi
  printf 'convert: built %s edited file(s) from upstream %s and %s generated; removed %s file(s) the variant drops; rewrote %s; reset %s stale pin(s)\n' \
    "${#OVERLAY[@]}" "$BSHORT" "${#GENERATED[@]}" "$DELETED" "${#DIFF[@]}" "${#STALE[@]}"
  mapfile -t DIFF < <(differing)
  STALE=()
fi

# --- Checks ------------------------------------------------------------------------
left="$(git ls-files -- "${DENY[@]}" | sort -u)"
[ -z "$left" ] || fail "paths the variant drops are still tracked: $(printf '%s ' $left | cut -c1-300)"
if [ "${#DIFF[@]}" -gt 0 ]; then
  fail "these differ from what convert.sh builds from upstream $BSHORT: ${DIFF[*]}"
  echo "  If you changed lib.sh or convert.sh, run bash tools/ue/convert.sh and commit." >&2
  echo "  If you edited one of them by hand, move the change into tools/ue/convert.sh." >&2
fi
for p in "${STALE[@]}"; do
  fail "$p: model '${IX_M[$p]:-}' / effort '${IX_E[$p]:-}' differ from upstream's ('${UP_M[$p]:-}' / '${UP_E[$p]:-}'), and it is not in the lib.sh lists"
done
# Upstream's author is named only in README.md's Credit section (checked when it
# is built) and in the files UE_NAME_OK lists: a new mention upstream adds, or a
# link form unlink_upstream cannot rewrite, stops here instead of spreading.
EXCL=()
for p in "${GENERATED[@]}" "${UE_NAME_OK[@]}"; do EXCL+=(":(exclude)$p"); done
NAMED="$(git grep --cached -n -I -i -F -e "$UE_UPSTREAM_OWNER" -- . "${EXCL[@]}" 2>/dev/null)"
if [ -n "$NAMED" ]; then
  fail "upstream's author is named outside README.md's Credit section and the files UE_NAME_OK lists:"
  printf '%s\n' "$NAMED" | awk 'NR <= 20 { print "    " substr($0, 1, 160) } END { if (NR > 20) print "    ... and " NR - 20 " more" }' >&2
  echo "  Rewrite it with an edit in tools/ue/convert.sh, or add the file to UE_NAME_OK in tools/ue/lib.sh." >&2
fi
if [ "$FAILS" -gt 0 ]; then
  printf 'convert: %s problem(s). If upstream moved something, update tools/ue/convert.sh or lib.sh.\n' "$FAILS" >&2
  exit 1
fi
echo "convert: checks passed against upstream $BSHORT"
