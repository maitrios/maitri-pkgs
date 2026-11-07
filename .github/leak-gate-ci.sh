#!/bin/bash

# leak-gate.yml's side of the leak gate: picks what to check, runs
# leak-gate.sh on it and posts the result as the leak-gate commit status. It
# runs from a clone whose origin is this repo, with main's copies of both
# scripts.
#
# A push checks the pushed range. A workflow_run or workflow_dispatch (given
# HEAD_SHA) finds every open PR whose head is the SHA, checks each one's range,
# title, body and branch, and posts one status for the SHA with the worst
# result, since statuses belong to the SHA, not the PR. If those PRs changed
# while it checked, it posts error, never a success for text it didn't see. A
# PR from a fork only learns pass or fail. Once pending is posted, any failure
# posts error instead of leaving pending (or another PR's success) behind.
# Statuses go out with STATUS_TOKEN (the leak-gate app's) when it's set.
#
#   leak-gate-ci.sh <leak-gate.sh>

set -euo pipefail

gate=${1:?usage: leak-gate-ci.sh <leak-gate.sh>}
repo=$GITHUB_REPOSITORY
sha=""
posted=""

set_status() {
  if ! GH_TOKEN=${STATUS_TOKEN:-${GH_TOKEN:-}} gh api -X POST "repos/$repo/statuses/$sha" -f context=leak-gate \
    -f state="$1" -f description="$2" -f target_url="$RUN_URL" >/dev/null; then
    echo "::error::Couldn't post the leak-gate status on ${sha:0:12}. A token that can't write statuses can't post it; bypass the check for this PR and say why."
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
  sha=${HEAD_SHA:-}
else
  sha=$(jq -r .workflow_run.head_sha "$GITHUB_EVENT_PATH")
fi
[[ $sha =~ ^[0-9a-f]{40}$ ]] || { echo "::error::sha has to be a full 40-character commit SHA"; exit 2; }

# prs_at <file>: every open PR whose head is the SHA, one JSON object a line.
prs_at() {
  gh api --paginate "repos/$repo/pulls?state=open&per_page=100" >"$RUNNER_TEMP/open.json" || return 1
  jq -c --arg sha "$sha" '.[] | select(.head.sha == $sha)' "$RUNNER_TEMP/open.json" >"$1"
}

# What a PR's check depends on, so a change during the check shows.
fingerprint() {
  jq -cs 'map({number, title, body, ref: .head.ref, base: .base.sha, repo: .head.repo.full_name}) | sort_by(.number)' "$1"
}

if ! prs_at "$RUNNER_TEMP/prs.jsonl"; then
  set_status error "Couldn't list the open PRs; see the run"
  exit 2
fi
if [[ ! -s $RUNNER_TEMP/prs.jsonl ]]; then
  echo "::notice::No open PR has ${sha:0:12} as its head now, so there's nothing to check."
  exit 0
fi

set_status pending "Checking for the forbidden names"
jq -r .base.sha "$RUNNER_TEMP/prs.jsonl" >"$RUNNER_TEMP/bases"
sort -u -o "$RUNNER_TEMP/bases" "$RUNNER_TEMP/bases"
mapfile -t bases <"$RUNNER_TEMP/bases"
fetch "$sha" "${bases[@]}"

# success < error < failure
worst=0
mapfile -t prs <"$RUNNER_TEMP/prs.jsonl"
for pr in "${prs[@]}"; do
  number=$(jq -r .number <<<"$pr")
  args=()
  fork=$(jq -r --arg repo "$repo" '.head.repo.full_name != $repo' <<<"$pr")
  if [[ $fork != "false" ]]; then
    args+=(--quiet)
  fi
  PR_TITLE=$(jq -r '.title // ""' <<<"$pr")
  PR_BODY=$(jq -r '.body // ""' <<<"$pr")
  PR_BRANCH=$(jq -r '.head.ref // ""' <<<"$pr")
  export PR_TITLE PR_BODY PR_BRANCH
  echo "PR #$number"
  result=0
  pr_base=$(jq -r .base.sha <<<"$pr")
  bash "$gate" "${args[@]}" "$pr_base" "$sha" || result=$?
  case $result in
    0) rank=0 ;;
    1) rank=2 ;;
    *) rank=1 ;;
  esac
  (( rank > worst )) && worst=$rank
done

if ! prs_at "$RUNNER_TEMP/prs-after.jsonl"; then
  echo "::error::Couldn't list the open PRs again before posting."
  conclude 2
fi
if [[ $(fingerprint "$RUNNER_TEMP/prs.jsonl") != "$(fingerprint "$RUNNER_TEMP/prs-after.jsonl")" ]]; then
  echo "::error::The PRs at ${sha:0:12} changed while they were checked, so this result doesn't count. Check them again with: gh workflow run leak-gate.yml -R $repo -f sha=$sha"
  conclude 2
fi

case $worst in
  0) conclude 0 ;;
  2) conclude 1 ;;
  *) conclude 2 ;;
esac
