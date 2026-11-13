#!/usr/bin/env bash
# tools/ue/ci-sync.sh: what the Upstream sync workflow runs
# (.github/workflows/upstream-sync.yml). Also runnable by hand.
#
#   bash tools/ue/ci-sync.sh [--dry-run] [--no-pr]
#
# 1. Fast-forwards origin/main to Donchitos's main (UE_UPSTREAM_URL). main must
#    stay an exact copy: if it has commits of its own, this stops.
# 2. Stops if unreal-engine already contains main: nothing to sync.
# 3. Otherwise makes sync/<version> from unreal-engine, runs sync.sh on it,
#    pushes the branch and opens a pull request into unreal-engine. It never
#    merges: you review the pull request and merge it with a merge commit.
#
# --dry-run  push nothing and open no pull request; the merge still runs locally
# --no-pr    push, then print the pull-request command instead of running it
# Needs push access to origin, and gh with GH_TOKEN to open the pull request.
#
# Exit: 0 done or nothing to do; 1 failed; 2 the release conflicts with this
#       branch and needs a person (run tools/ue/sync.sh locally).
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib.sh
. "$HERE/lib.sh"
ROOT="$(git -C "$HERE" rev-parse --show-toplevel)" || exit 1
cd "$ROOT" || exit 1

DRY=0; NOPR=0
for a in "$@"; do
  case "$a" in
    --dry-run) DRY=1 ;;
    --no-pr) NOPR=1 ;;
    -h|--help) sed -n '2,20p' "$0"; exit 0 ;;
    *) ue_die "unknown option: $a (try --help)" ;;
  esac
done
BASE_BRANCH="${UE_BASE_BRANCH:-unreal-engine}"
MIRROR="${UE_MIRROR_BRANCH:-main}"
run() { if [ "$DRY" -eq 1 ]; then echo "[dry-run] $*"; else "$@"; fi; }
summary() { [ -n "${GITHUB_STEP_SUMMARY:-}" ] && printf '%s\n' "$@" >> "$GITHUB_STEP_SUMMARY"; return 0; }

git fetch -q --prune origin || ue_die "could not fetch origin"
git fetch -q --tags "$UE_UPSTREAM_URL" "+refs/heads/main:refs/remotes/upstream/main" \
  || ue_die "could not fetch $UE_UPSTREAM_URL"

# --- 1. Mirror ------------------------------------------------------------------
UP="$(git rev-parse upstream/main)"
OM="$(git rev-parse -q --verify "origin/$MIRROR")" || ue_die "origin has no $MIRROR branch"
VER="$(git describe --tags --always upstream/main)"
if [ "$UP" = "$OM" ]; then
  echo "ci-sync: $MIRROR already matches upstream ($VER)"
elif git merge-base --is-ancestor "$OM" "$UP"; then
  echo "ci-sync: fast-forwarding $MIRROR to upstream $VER"
  run git push -q origin "upstream/main:refs/heads/$MIRROR" || ue_die "could not push $MIRROR"
  [ "$DRY" -eq 1 ] || git fetch -q origin "$MIRROR"
else
  summary "### $MIRROR has commits of its own" "It must stay an exact copy of upstream. Move those commits to $BASE_BRANCH, then reset $MIRROR to upstream."
  ue_die "$MIRROR has commits that are not in upstream; it must stay an exact copy"
fi
TARGET="upstream/main"   # equal to origin/$MIRROR once the push above has landed

# --- 2. Anything to sync? -----------------------------------------------------------
git rev-parse -q --verify "origin/$BASE_BRANCH" >/dev/null || ue_die "origin has no $BASE_BRANCH branch"
if git merge-base --is-ancestor "$TARGET" "origin/$BASE_BRANCH"; then
  echo "ci-sync: $BASE_BRANCH already contains upstream $VER; nothing to sync"
  summary "Nothing to sync: $BASE_BRANCH already contains upstream $VER."
  exit 0
fi
BR="sync/$VER"
if git ls-remote --exit-code --heads origin "$BR" >/dev/null 2>&1; then
  echo "ci-sync: $BR already exists on origin; review or close its pull request first"
  summary "$BR already exists: review or close its pull request first."
  exit 0
fi

# --- 3. Sync on a branch, push, open a pull request ----------------------------------
git switch -q -c "$BR" "origin/$BASE_BRANCH" || ue_die "could not create $BR"
LOG="$(mktemp)"
bash tools/ue/sync.sh "$TARGET" 2>&1 | tee "$LOG"
RC="${PIPESTATUS[0]}"
if [ "$RC" -ne 0 ]; then
  if [ "$RC" -eq 2 ]; then
    summary "### Upstream $VER needs you" "Both sides changed the files below. Run \`bash tools/ue/sync.sh\` locally on a branch from $BASE_BRANCH, resolve them and open the pull request yourself." '```' "$(cat "$LOG")" '```'
    echo "::error::upstream $VER conflicts with $BASE_BRANCH; run bash tools/ue/sync.sh locally"
    exit 2
  fi
  summary "### The sync of upstream $VER failed" '```' "$(cat "$LOG")" '```'
  echo "::error::the sync of upstream $VER failed; see the log above"
  exit 1
fi

run git push -q -u origin "$BR" || ue_die "could not push $BR"

NOTES=""
git describe --tags --exact-match upstream/main >/dev/null 2>&1 \
  && NOTES="Release notes: https://github.com/Donchitos/Claude-Code-Game-Studios/releases/tag/$VER"
BODY="$(cat <<EOF
Merges upstream **$VER** (\`$(git rev-parse --short upstream/main)\`) into \`$BASE_BRANCH\`, converted by \`tools/ue/sync.sh\`.

$NOTES

- [ ] Read the $VER section of \`UPGRADING.md\` for one-off steps; \`install.sh\` never changes your project's \`project.yaml\`.
- [ ] Merge with a **merge commit**. A squash loses the record of what was merged, and the next sync conflicts.
- [ ] Then update your UE project: \`bash tools/ue/install.sh --dry-run <project>\`, then without \`--dry-run\`.

<details><summary>sync.sh output</summary>

\`\`\`
$(cat "$LOG")
\`\`\`
</details>
EOF
)"
TITLE="Sync upstream $VER"
if [ "$DRY" -eq 1 ]; then
  echo "[dry-run] gh pr create --base $BASE_BRANCH --head $BR --title \"$TITLE\""
elif [ "$NOPR" -eq 1 ]; then
  echo "ci-sync: pushed $BR. Open the pull request with:"
  echo "  gh pr create --base $BASE_BRANCH --head $BR --title \"$TITLE\""
else
  URL="$(gh pr create --base "$BASE_BRANCH" --head "$BR" --title "$TITLE" --body "$BODY")" \
    || ue_die "pushed $BR but could not open the pull request (is 'Allow GitHub Actions to create and approve pull requests' on?)"
  echo "ci-sync: opened $URL"
  summary "### Opened a pull request for upstream $VER" "$URL"
fi
