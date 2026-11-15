#!/usr/bin/env bash
# tools/ue/ci-sync.sh: what the Upstream sync workflow runs
# (.github/workflows/upstream-sync.yml). Also runnable by hand.
#
#   bash tools/ue/ci-sync.sh [--dry-run] [--no-pr]
#
# 1. Fast-forwards origin/main to Donchitos's main (UE_UPSTREAM_URL). main must
#    stay an exact copy: if it has commits of its own, this stops.
# 2. Stops if unreal-engine already contains main: nothing to sync.
# 3. Looks at the open sync pull requests. One already open for this version:
#    nothing to do. One for this version closed without merging while its
#    branch still exists: skipped, since you turned it down (delete the branch to
#    get a fresh one).
# 4. Otherwise merges the release with sync.sh on sync/<version> in a temporary
#    worktree, pushes it and opens a pull request into unreal-engine, then closes
#    older open sync pull requests as superseded. It never merges.
#
# --dry-run  push nothing, open or close no pull request, leave no branch behind
# --no-pr    push, but print the pull-request command; no pull-request lookups
# Needs push access to origin, and gh (GH_TOKEN) unless --no-pr or --dry-run.
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
    -h|--help) sed -n '2,24p' "$0"; exit 0 ;;
    *) ue_die "unknown option: $a (try --help)" ;;
  esac
done
BASE_BRANCH="${UE_BASE_BRANCH:-unreal-engine}"
MIRROR="${UE_MIRROR_BRANCH:-main}"
run() { if [ "$DRY" -eq 1 ]; then echo "[dry-run] $*"; else "$@"; fi; }
summary() { [ -n "${GITHUB_STEP_SUMMARY:-}" ] && printf '%s\n' "$@" >> "$GITHUB_STEP_SUMMARY"; return 0; }

# Pull requests are looked up in this repository explicitly: with an `upstream`
# remote, gh would otherwise pick Donchitos's repository.
USE_GH=1
[ "$NOPR" -eq 1 ] && USE_GH=0
if [ "$USE_GH" -eq 1 ] && ! command -v gh >/dev/null 2>&1; then
  [ "$DRY" -eq 1 ] || ue_die "gh is needed to open the pull request (or pass --no-pr)"
  USE_GH=0
fi
REPO="${GITHUB_REPOSITORY:-$(git remote get-url origin 2>/dev/null | sed -E 's#^.*github\.com[:/]##; s#\.git$##')}"

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
BRANCH_EXISTS=0
git ls-remote --exit-code --heads origin "$BR" >/dev/null 2>&1 && BRANCH_EXISTS=1

# --- 3. Pull-request state ----------------------------------------------------------
OPEN=""
if [ "$USE_GH" -eq 1 ]; then
  OPEN="$(gh pr list --repo "$REPO" --state open --base "$BASE_BRANCH" --json number,headRefName \
          --jq '.[] | select(.headRefName | startswith("sync/")) | "\(.number)\t\(.headRefName)"')" \
    || ue_die "could not list pull requests in $REPO"
  N="$(printf '%s\n' "$OPEN" | awk -F'\t' -v b="$BR" '$2 == b { print $1; exit }')"
  if [ -n "$N" ]; then
    echo "ci-sync: pull request #$N for upstream $VER is already open"
    summary "Pull request #$N for upstream $VER is already open."
    exit 0
  fi
  CLOSED="$(gh pr list --repo "$REPO" --state closed --head "$BR" --json number,mergedAt \
            --jq '.[] | select(.mergedAt == null) | .number' | head -1)"
  if [ -n "$CLOSED" ] && [ "$BRANCH_EXISTS" -eq 1 ]; then
    echo "ci-sync: pull request #$CLOSED for upstream $VER was closed without merging; reopen it, or delete the branch $BR to get a fresh one"
    summary "Skipped: pull request #$CLOSED for upstream $VER was closed without merging. Reopen it, or delete the branch \`$BR\` to get a fresh one."
    exit 0
  fi
elif [ "$NOPR" -eq 1 ] && [ "$BRANCH_EXISTS" -eq 1 ]; then
  echo "ci-sync: $BR already exists on origin (--no-pr cannot see its pull request); delete it to sync again"
  exit 0
fi

# --- 4. Sync in a temporary worktree, push, open the pull request -------------------
TMP="$(mktemp -d)"
cleanup() {
  git worktree remove --force "$TMP/wt" >/dev/null 2>&1
  git worktree prune >/dev/null 2>&1
  git branch -D "$BR" >/dev/null 2>&1
  rm -rf "$TMP"
}
trap cleanup EXIT
git worktree add -q -B "$BR" "$TMP/wt" "origin/$BASE_BRANCH" >/dev/null 2>&1 || ue_die "could not create $BR"
LOG="$TMP/sync.log"
bash "$TMP/wt/tools/ue/sync.sh" "$TARGET" 2>&1 | tee "$LOG"
RC="${PIPESTATUS[0]}"
if [ "$RC" -ne 0 ]; then
  if [ "$RC" -eq 2 ]; then
    summary "### Upstream $VER needs you" "Run \`bash tools/ue/sync.sh\` locally on a branch from $BASE_BRANCH, resolve the files below and open the pull request yourself." '```' "$(cat "$LOG")" '```'
    echo "::error::upstream $VER conflicts with $BASE_BRANCH; run bash tools/ue/sync.sh locally"
    exit 2
  fi
  summary "### The sync of upstream $VER failed" '```' "$(cat "$LOG")" '```'
  echo "::error::the sync of upstream $VER failed; see the log above"
  exit 1
fi

# The branch belongs to this script, so a leftover from an earlier run is replaced.
run git push -q -f origin "refs/heads/$BR:refs/heads/$BR" || ue_die "could not push $BR"

NOTES=""
git describe --tags --exact-match upstream/main >/dev/null 2>&1 \
  && NOTES="Release notes: https://github.com/Donchitos/Claude-Code-Game-Studios/releases/tag/$VER"
BODY="$(cat <<EOF
Merges upstream **$VER** (\`$(git rev-parse --short upstream/main)\`) into \`$BASE_BRANCH\`, converted by \`tools/ue/sync.sh\`.

$NOTES

- [ ] Read the $VER section of \`UPGRADING.md\` for one-off steps; \`install.sh\` never changes your project's \`project.yaml\` beyond setting the engine.
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
OLDER="$(printf '%s\n' "$OPEN" | awk -F'\t' -v b="$BR" 'NF == 2 && $2 != b { print $1 }')"
if [ "$DRY" -eq 1 ]; then
  echo "[dry-run] gh pr create --repo $REPO --base $BASE_BRANCH --head $BR --title \"$TITLE\""
  for n in $OLDER; do echo "[dry-run] gh pr close $n --repo $REPO --delete-branch (superseded)"; done
elif [ "$NOPR" -eq 1 ]; then
  echo "ci-sync: pushed $BR. Open the pull request with:"
  echo "  gh pr create --repo $REPO --base $BASE_BRANCH --head $BR --title \"$TITLE\""
else
  URL="$(gh pr create --repo "$REPO" --base "$BASE_BRANCH" --head "$BR" --title "$TITLE" --body "$BODY")" \
    || ue_die "pushed $BR but could not open the pull request (is 'Allow GitHub Actions to create and approve pull requests' on?)"
  echo "ci-sync: opened $URL"
  summary "### Opened a pull request for upstream $VER" "$URL"
  for n in $OLDER; do
    gh pr close "$n" --repo "$REPO" --delete-branch --comment "Superseded by $URL, which merges upstream $VER (and everything before it)." \
      && echo "ci-sync: closed #$n as superseded" || ue_warn "could not close #$n"
  done
fi
