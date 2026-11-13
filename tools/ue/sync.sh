#!/usr/bin/env bash
# tools/ue/sync.sh: merge an upstream release into the UE-only branch.
#
#   bash tools/ue/sync.sh [--no-commit] [--force] [<upstream-ref>]
#
# <upstream-ref> is what to merge: by default origin/main, this fork's exact copy
# of Donchitos's main. Run it on unreal-engine, or a branch made from it, with no
# uncommitted changes. It merges, takes upstream's copy of every file convert.sh
# edits, re-runs convert.sh (which also deletes any Godot/Unity file upstream
# added or changed), and commits the merge.
#
# --no-commit  stop before committing so you can look at the result first
# --force      skip the hand-edit check (see below) and discard those edits
#
# Hand-edit check: the files convert.sh edits are rebuilt from upstream's copy on
# every sync, so a hand edit to one of them would be lost. Before merging, this
# compares each one with what convert.sh makes of the last merged upstream and
# stops if they differ. Move the change into tools/ue/convert.sh or lib.sh, or
# run convert.sh and commit if you just changed a setting in lib.sh.
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
    -h|--help) sed -n '2,23p' "$0"; exit 0 ;;
    -*) ue_die "unknown option: $1 (try --help)" ;;
    *) [ -z "$REF" ] || ue_die "only one ref, please"; REF="$1" ;;
  esac
  shift
done
REF="${REF:-origin/main}"

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
mapfile -t OVERLAY < <(ue_overlay_files | sort -u)

# --- Hand-edit check ------------------------------------------------------------
if [ "$FORCE" -eq 0 ]; then
  TMP="$(mktemp -d)"
  cleanup() { git worktree remove --force "$TMP/base" >/dev/null 2>&1; rm -rf "$TMP"; git worktree prune >/dev/null 2>&1; }
  trap cleanup EXIT
  git worktree add -q --detach "$TMP/base" "$BASE" >/dev/null 2>&1 || ue_die "could not check out $BASE for the hand-edit check"
  rm -rf "$TMP/base/tools/ue" && mkdir -p "$TMP/base/tools/ue" && cp "$HERE"/*.sh "$TMP/base/tools/ue/"
  ( cd "$TMP/base" && bash tools/ue/convert.sh >/dev/null 2>&1 ) \
    || ue_warn "convert.sh does not pass on the last merged upstream ($(git rev-parse --short "$BASE")); the hand-edit check may report extra files"
  EDITED=()
  for f in "${OVERLAY[@]}"; do
    git cat-file -e "HEAD:$f" 2>/dev/null || continue
    git show "HEAD:$f" | cmp -s - "$TMP/base/$f" 2>/dev/null || EDITED+=("$f")
  done
  cleanup; trap - EXIT
  if [ "${#EDITED[@]}" -gt 0 ]; then
    {
      echo "sync: these files differ from what convert.sh makes of upstream's copy, and the sync would replace them:"
      printf '  %s\n' "${EDITED[@]}"
      echo "Move the change into tools/ue/convert.sh (or a setting in lib.sh), or, if you only"
      echo "changed lib.sh, run bash tools/ue/convert.sh and commit. --force discards the edits."
    } >&2
    exit 1
  fi
fi

# --- Merge ------------------------------------------------------------------------
echo "sync: merging $REF ($DESC) into $BR"
git merge --no-ff --no-commit "$REF" >/dev/null 2>&1
RAW="$(git diff --name-only --diff-filter=U | sort -u | wc -l)"
TAKEN=0
for f in "${OVERLAY[@]}"; do
  if git cat-file -e "$REF:$f" 2>/dev/null; then
    git checkout -q "$REF" -- "$f" && TAKEN=$((TAKEN + 1))
  fi
done
if ! bash "$HERE/convert.sh"; then
  echo "sync: convert.sh failed, so the merge is still in progress. Fix tools/ue and re-run it, or run git merge --abort." >&2
  exit 1
fi
LEFT="$(git diff --name-only --diff-filter=U | sort -u)"
echo "sync: $RAW conflict(s) in the raw merge; $TAKEN file(s) rebuilt from upstream's copy"
if [ -n "$LEFT" ]; then
  {
    echo "sync: $(printf '%s\n' "$LEFT" | wc -l) file(s) need you (both sides changed them):"
    printf '%s\n' "$LEFT" | sed 's/^/  /'
    echo "Resolve them, git add them, run bash tools/ue/convert.sh --check, then git commit."
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
