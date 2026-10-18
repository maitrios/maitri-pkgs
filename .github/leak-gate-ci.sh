#!/bin/bash

# leak-gate.yml's side of the leak gate: picks what to check, runs
# leak-gate.sh on it and posts the result as the leak-gate commit status. It
# runs from a clone whose origin is this repo, with main's copies of both
# scripts.
#
# A push checks the pushed range. A workflow_run or workflow_dispatch finds
# every open PR whose head is the SHA, checks each one's range, title, body
# and branch, and posts one status for the SHA with the worst result, since
# statuses belong to the SHA, not the PR. A PR from a fork only learns pass or
# fail. Once pending is posted, any failure posts error instead of leaving
# pending (or another PR's success) behind.
#
#   leak-gate-ci.sh <leak-gate.sh>

set -euo pipefail

gate=${1:?usage: leak-gate-ci.sh <leak-gate.sh>}
repo=$GITHUB_REPOSITORY
sha=""
posted=""

set_status() {
  if ! gh api -X POST "repos/$repo/statuses/$sha" -f context=leak-gate -f state="$1" \
    -f description="$2" -f target_url="$RUN_URL" >/dev/null; then
    echo "::error::Couldn't post the leak-gate status on ${sha:0:12}. A read-only token can't post it; bypass the check for this PR and say why."
    return 1
  fi
  posted=$1
}

# shellcheck disable=SC2329
finish() {
  local code=$?
  if [[ $posted == "pending" ]]; then
    set_status error "Couldn't finish the check; see the run" || true
  fi
  exit "$code"
}
trap finish EXIT

conclude() {
  case $1 in
    0) set_status success "No forbidden names" ;;
    1) set_status failure "Forbidden names found" ;;
    *) set_status error "Couldn't check; see the run" ;;
  esac
  exit "$1"
}

fetch() {
  git fetch -q --no-tags --filter=blob:none origin "$@"
}

if [[ $GITHUB_EVENT_NAME == "push" ]]; then
  sha=$GITHUB_SHA
  before=$(jq -r .before "$GITHUB_EVENT_PATH")
  set_status pending "Checking for the forbidden names"
  fetch "$before" "$sha"
  result=0
  bash "$gate" "$before" "$sha" || result=$?
  if (( result == 1 )); then
    echo "::error title=Forbidden names on main::A commit pushed to main carries a forbidden name (the lines above say where). It's public now: revert or rewrite it."
  fi
  conclude "$result"
fi

if [[ $GITHUB_EVENT_NAME == "workflow_dispatch" ]]; then
  [[ ${PR_NUMBER:-} =~ ^[0-9]+$ ]] || { echo "::error::pr has to be a PR number"; exit 2; }
  sha=$(gh api "repos/$repo/pulls/$PR_NUMBER" | jq -r .head.sha)
else
  sha=$(jq -r .workflow_run.head_sha "$GITHUB_EVENT_PATH")
fi
[[ $sha =~ ^[0-9a-f]{40}$ ]] || { echo "::error::No head SHA to check"; exit 2; }

if ! gh api --paginate "repos/$repo/pulls?state=open&per_page=100" >"$RUNNER_TEMP/open.json"; then
  set_status error "Couldn't list the open PRs; see the run"
  exit 2
fi
jq -c --arg sha "$sha" '.[] | select(.head.sha == $sha)' "$RUNNER_TEMP/open.json" >"$RUNNER_TEMP/prs.jsonl"
if [[ ! -s $RUNNER_TEMP/prs.jsonl ]]; then
  echo "::notice::No open PR has ${sha:0:12} as its head now, so there's nothing to check."
  exit 0
fi

set_status pending "Checking for the forbidden names"
mapfile -t bases < <(jq -r .base.sha "$RUNNER_TEMP/prs.jsonl" | sort -u)
fetch "$sha" "${bases[@]}"

# success < error < failure
worst=0
while IFS= read -r pr; do
  number=$(jq -r .number <<<"$pr")
  args=()
  if [[ $(jq -r --arg repo "$repo" '.head.repo.full_name != $repo' <<<"$pr") == "true" ]]; then
    args+=(--quiet)
  fi
  PR_TITLE=$(jq -r '.title // ""' <<<"$pr")
  PR_BODY=$(jq -r '.body // ""' <<<"$pr")
  PR_BRANCH=$(jq -r '.head.ref // ""' <<<"$pr")
  export PR_TITLE PR_BODY PR_BRANCH
  echo "PR #$number"
  result=0
  bash "$gate" "${args[@]}" "$(jq -r .base.sha <<<"$pr")" "$sha" || result=$?
  case $result in
    0) rank=0 ;;
    1) rank=2 ;;
    *) rank=1 ;;
  esac
  (( rank > worst )) && worst=$rank
done <"$RUNNER_TEMP/prs.jsonl"

case $worst in
  0) conclude 0 ;;
  2) conclude 1 ;;
  *) conclude 2 ;;
esac
