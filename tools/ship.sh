#!/usr/bin/env bash
#
# Opening a pull request without stalling it.
#
# PR #100 took four manual CI runs and a rebase to land, and every one of
# those was caused by a single mistake at the very start: the branch was cut
# from another feature branch instead of from main.
#
# That mistake is expensive in a way that is not obvious. This repo squash
# merges, so once the parent branch lands, its commit exists on main under a
# different hash — and a branch still carrying the original is in conflict
# with main. GitHub computes the `pull_request` event against the *merge*
# ref, and a conflicting PR has no merge ref, so **CI never starts on its
# own**. The PR sits there looking neglected rather than broken, and the only
# way to see a check is to dispatch one by hand, which tests the branch head
# rather than the thing that would actually be merged.
#
# So: two commands. `start` cuts from a freshly fetched main and nowhere
# else. `pr` opens the request, turns auto-merge on so it lands the moment
# the checks pass, and refuses quietly to let a conflicting PR look healthy.

set -euo pipefail

usage() {
  cat <<'USAGE'
Usage:
  tools/ship.sh start <branch-name>      cut a branch from a fresh origin/main
  tools/ship.sh pr <title> [body-file]   push, open the PR, enable auto-merge
  tools/ship.sh check [pr-number]        is it actually going to land?

Examples:
  tools/ship.sh start feat/taste-on-profiles
  tools/ship.sh pr "Somewhere to say what you sound like" /tmp/body.md
USAGE
}

main_branch() {
  # Piping straight through sed would swallow the failure: sed exits 0 on
  # empty input, so `|| echo main` never fires and the caller is handed an
  # empty branch name. Capture first, then decide.
  local head
  head="$(git symbolic-ref --quiet --short refs/remotes/origin/HEAD 2>/dev/null || true)"
  head="${head#origin/}"
  echo "${head:-main}"
}

cmd_start() {
  local name="${1:-}"
  if [ -z "$name" ]; then usage; exit 2; fi
  local base; base="$(main_branch)"

  # Uncommitted work would follow the checkout onto the new branch and get
  # swept into the first commit. Better to say so than to carry it silently.
  if [ -n "$(git status --porcelain --untracked-files=no)" ]; then
    echo "There are uncommitted changes. Commit or stash them first:" >&2
    git status --short >&2
    exit 1
  fi

  git fetch --quiet origin "$base"
  git checkout --quiet -b "$name" "origin/$base"
  echo "$name, cut from origin/$base at $(git rev-parse --short HEAD)."
}

cmd_pr() {
  local title="${1:-}"
  local body_file="${2:-}"
  if [ -z "$title" ]; then usage; exit 2; fi

  local base; base="$(main_branch)"
  local branch; branch="$(git rev-parse --abbrev-ref HEAD)"
  if [ "$branch" = "$base" ]; then
    echo "On $base. Run 'tools/ship.sh start <name>' first." >&2
    exit 1
  fi

  # The check that would have saved PR #100. If main has moved somewhere this
  # branch cannot replay onto, say so now — while the fix is still a rebase
  # of two commits rather than an afternoon.
  git fetch --quiet origin "$base"
  if ! git merge-base --is-ancestor "origin/$base" HEAD 2>/dev/null; then
    if ! git merge-tree --write-tree "origin/$base" HEAD >/dev/null 2>&1; then
      echo "This branch conflicts with origin/$base." >&2
      echo "Rebase before opening a PR, or CI will never start:" >&2
      echo "  git rebase origin/$base" >&2
      exit 1
    fi
  fi

  git push --quiet --set-upstream origin "$branch"

  if [ -n "$body_file" ]; then
    gh pr create --base "$base" --title "$title" --body-file "$body_file"
  else
    gh pr create --base "$base" --title "$title" --fill
  fi

  # Land it the moment the four checks go green, rather than whenever
  # somebody next looks at the tab.
  gh pr merge --auto --squash || {
    echo "Auto-merge was refused. The PR is open; check its state:" >&2
    echo "  tools/ship.sh check" >&2
  }

  cmd_check
}

cmd_check() {
  local number="${1:-}"
  local args=(--json number,mergeable,mergeStateStatus,autoMergeRequest,statusCheckRollup)
  local json
  if [ -n "$number" ]; then
    json="$(gh pr view "$number" "${args[@]}")"
  else
    json="$(gh pr view "${args[@]}")"
  fi

  echo "$json" | gh_summary
}

gh_summary() {
  python -c '
import json, sys
pr = json.load(sys.stdin)
checks = pr.get("statusCheckRollup") or []
done = [c for c in checks if c.get("conclusion")]
bad = [c["name"] for c in done if c["conclusion"] not in ("SUCCESS", "NEUTRAL", "SKIPPED")]
print("PR #%s" % pr["number"])
print("  mergeable   %s" % pr["mergeable"])
print("  state       %s" % pr["mergeStateStatus"])
print("  auto-merge  %s" % ("on" if pr.get("autoMergeRequest") else "OFF"))
print("  checks      %d/%d reported%s"
      % (len(done), len(checks), (", failing: " + ", ".join(bad)) if bad else ""))
if pr["mergeable"] == "CONFLICTING":
    print("")
    print("  CONFLICTING means CI will not start by itself: the pull_request")
    print("  event has no merge ref to run against. Rebase onto main.")
elif not checks:
    print("")
    print("  No checks yet. If this persists, the PR is probably not")
    print("  mergeable - check the line above rather than dispatching a run.")
'
}

case "${1:-}" in
  start) shift; cmd_start "$@" ;;
  pr)    shift; cmd_pr "$@" ;;
  check) shift; cmd_check "$@" ;;
  *)     usage; exit 2 ;;
esac
