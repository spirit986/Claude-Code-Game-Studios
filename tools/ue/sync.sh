#!/usr/bin/env bash
# tools/ue/sync.sh: merge an upstream release into the UE-only branch.
#
#   bash tools/ue/sync.sh [--no-commit] [--force] [<upstream-ref>]
#
# <upstream-ref> is what to merge: by default origin/main, this fork's exact copy
# of upstream's main. Run it on unreal-engine, or a branch made from it, with no
# uncommitted changes. It merges, rebuilds every file convert.sh edits from the
# new upstream's copy (which also resolves their conflicts), deletes the
# Godot/Unity files upstream added or changed, and commits the merge.
#
# --no-commit  stop before committing so you can look at the result first
# --force      skip the hand-edit check (below) and discard those edits
#
# Hand-edit check: before merging, `convert.sh --check` against the upstream
# release this branch last merged. Every file convert.sh edits is rebuilt at each
# sync, so a hand edit to one of them would be lost; the check stops the sync
# and names the file instead. If you only changed lib.sh, run convert.sh and
# commit; otherwise move the edit into tools/ue/convert.sh.
#
# Exit: 0 merged, or nothing to do; 1 refused or a check failed;
#       2 conflicts are left for you, with the merge still in progress.
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib.sh
. "$HERE/lib.sh"
ROOT="$(git -C "$HERE" rev-parse --show-toplevel)" || exit 1
cd "$ROOT" || exit 1

NOCOMMIT=0; FORCE=0; REF=""
while [ $# -gt 0 ]; do
  case "$1" in
    --no-commit) NOCOMMIT=1 ;;
    --force) FORCE=1 ;;
    -h|--help) sed -n '2,22p' "$0"; exit 0 ;;
    -*) ue_die "unknown option: $1 (try --help)" ;;
    *) [ -z "$REF" ] || ue_die "only one ref, please"; REF="$1" ;;
  esac
  shift
done
REF="${REF:-$UE_MIRROR_REF}"

git rev-parse -q --verify "$REF^{commit}" >/dev/null || ue_die "unknown ref: $REF (fetch first?)"
BR="$(git symbolic-ref --short -q HEAD)" || ue_die "detached HEAD: switch to unreal-engine or a branch made from it"
[ "$BR" != main ] || ue_die "main must stay an exact copy of upstream; run this on unreal-engine or a branch made from it"
git rev-parse -q --verify MERGE_HEAD >/dev/null && ue_die "a merge is already in progress: finish it or run git merge --abort"
[ -z "$(git status --porcelain --untracked-files=no)" ] || ue_die "commit or set aside your changes first"

DESC="$(git describe --tags --always "$REF" 2>/dev/null || git rev-parse --short "$REF")"
if git merge-base --is-ancestor "$REF" HEAD; then
  echo "sync: $BR already contains $REF ($DESC); nothing to do"
  exit 0
fi
BASE="$(git merge-base HEAD "$REF")" || ue_die "$BR and $REF share no history"

# --- Hand-edit check ------------------------------------------------------------
CHECKLOG="$(mktemp)"
if [ "$FORCE" -eq 0 ] && ! bash "$HERE/convert.sh" --check --base "$BASE" >/dev/null 2>"$CHECKLOG"; then
  {
    echo "sync: $BR does not match what convert.sh builds from the upstream it last merged ($(git rev-parse --short "$BASE")):"
    sed 's/^/  /' "$CHECKLOG"
    echo "Fix that first (see above), or rerun with --force to discard those edits."
  } >&2
  rm -f "$CHECKLOG"
  exit 1
fi
rm -f "$CHECKLOG"

# --- Merge ------------------------------------------------------------------------
echo "sync: merging $REF ($DESC) into $BR"
OUT="$(git merge --no-ff --no-commit "$REF" 2>&1)"
if ! git rev-parse -q --verify MERGE_HEAD >/dev/null; then
  # Conflicts make git merge exit non-zero too, so MERGE_HEAD is the test: without
  # it the merge never started (an untracked file in the way, for example).
  printf '%s\n' "$OUT" | sed 's/^/  git: /' >&2
  ue_die "the merge did not start, so nothing was changed"
fi
RAW="$(git diff --name-only --diff-filter=U | sort -u | wc -l)"
if ! bash "$HERE/convert.sh"; then
  echo "sync: convert.sh failed, so the merge is still in progress. Fix tools/ue and re-run bash tools/ue/convert.sh, or run git merge --abort." >&2
  exit 1
fi

# --- Anything left for a person ------------------------------------------------------
LEFT="$(git status --porcelain=v1 --untracked-files=no | awk '
  { code = substr($0, 1, 2); path = substr($0, 4) }
  code == "UU" { print "  " path " (changed on both sides)" }
  code == "AA" { print "  " path " (added on both sides)" }
  code == "UD" { print "  " path " (changed here, deleted upstream)" }
  code == "DU" { print "  " path " (deleted here, changed upstream)" }
  code == "AU" || code == "UA" { print "  " path " (added on one side, in conflict)" }
  code == "DD" { print "  " path " (deleted on both sides)" }')"
echo "sync: $RAW conflict(s) in the raw merge"
if [ -n "$LEFT" ]; then
  {
    echo "sync: $(printf '%s\n' "$LEFT" | wc -l) file(s) need you:"
    printf '%s\n' "$LEFT"
    echo "Resolve them, git add (or git rm) them, run bash tools/ue/convert.sh --check, then git commit."
    echo "Or give up with git merge --abort."
  } >&2
  exit 2
fi
echo "sync: nothing left for you to resolve"
if [ "$NOCOMMIT" -eq 1 ]; then
  echo "sync: merged and converted, not committed (--no-commit). Review, then git commit."
  exit 0
fi
git commit -q -m "chore(ue): sync upstream $DESC into $BR" \
  -m "Merged $REF ($DESC) with tools/ue/sync.sh: $RAW conflict(s) in the raw merge, all resolved by the script." \
  || ue_die "the commit failed"
echo "sync: committed $(git rev-parse --short HEAD)"
