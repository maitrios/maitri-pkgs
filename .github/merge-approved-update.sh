#!/bin/bash
# Squash-merge an auto/<name> PR from update-packages.yml once its reviewer
# approved the current head, the PR is mergeable and every check on it is
# green, then start build-pkgs.yml, since a merge made with GITHUB_TOKEN does
# not trigger it.
#
#   merge-approved-update.sh <pr>
#
# REVIEWER is the one login whose approval counts (default beyera). SELF names
# the workflow running this script, whose own check run on the head commit is
# ignored. DRY_RUN=1 checks everything but neither merges, dispatches nor
# comments.
set -euo pipefail

pr=${1:?usage: merge-approved-update.sh <pr>}
reviewer=${REVIEWER:-beyera}
self=${SELF:-}
dry=${DRY_RUN:-}
repo=${GITHUB_REPOSITORY:?}
base=main
build_context="update-packages / build"

skip() {
  echo "::notice::#$pr: not merging, $1"
  exit 0
}

block() {
  echo "::error::#$pr: not merging, $1"
  if [[ -z $dry ]]; then
    gh pr comment "$pr" --body "Not merging this approval automatically: $1. Fix that and approve again, or merge by hand." >/dev/null
  fi
  exit 1
}

pr_json() {
  gh pr view "$pr" --json state,isDraft,baseRefName,headRefName,headRefOid,headRepository,headRepositoryOwner,mergeable,statusCheckRollup,body
}

info=$(pr_json)
head=$(jq -r .headRefOid <<<"$info")

[[ $(jq -r .state <<<"$info") == OPEN ]] || skip "it is not open"
[[ $(jq -r .headRefName <<<"$info") == auto/* ]] || skip "the head branch is not auto/*"
[[ $(jq -r .baseRefName <<<"$info") == "$base" ]] || skip "it does not target $base"
[[ $(jq -r '"\(.headRepositoryOwner.login)/\(.headRepository.name)"' <<<"$info") == "$repo" ]] ||
  skip "the head branch lives outside $repo"

# The latest approve/request-changes verdict from the reviewer is what counts;
# plain comments don't override it.
verdict=$(gh api --paginate "repos/$repo/pulls/$pr/reviews" |
  jq -rs --arg who "$reviewer" '
    [.[][] | select(.user.login == $who and (.state == "APPROVED" or .state == "CHANGES_REQUESTED"))]
    | last // {} | "\(.state // "none") \(.commit_id // "")"')
read -r state approved_sha <<<"$verdict"
[[ $state == APPROVED ]] || skip "$reviewer has not approved it (latest verdict: $state)"
[[ $approved_sha == "$head" ]] || block "$reviewer approved ${approved_sha:0:7}, but the branch has moved on to ${head:0:7}"
[[ $(jq -r .isDraft <<<"$info") == false ]] || block "it is a draft"

# mergeable is UNKNOWN until GitHub has computed it, and checks may still be
# finishing, so give both a few minutes.
for _ in $(seq 1 20); do
  mergeable=$(jq -r .mergeable <<<"$info")
  checks=$(jq -c --arg self "$self" '
    [.statusCheckRollup[]
     | select(.__typename != "CheckRun" or .workflowName != $self)
     | if .__typename == "CheckRun"
       then {name, done: (.status == "COMPLETED"), ok: (.conclusion | IN("SUCCESS", "NEUTRAL", "SKIPPED"))}
       else {name: .context, done: (.state != "PENDING" and .state != "EXPECTED"), ok: (.state == "SUCCESS")}
       end]' <<<"$info")
  pending=$(jq -r 'map(select(.done | not) | .name) | join(", ")' <<<"$checks")
  if [[ $mergeable != UNKNOWN && -z $pending ]]; then
    break
  fi
  echo "waiting (mergeable=$mergeable, pending: ${pending:-none})"
  sleep 30
  info=$(pr_json)
  [[ $(jq -r .headRefOid <<<"$info") == "$head" ]] || block "the branch moved while waiting for its checks"
done

[[ $mergeable == MERGEABLE ]] || block "GitHub reports it as $mergeable"
[[ -z $pending ]] || block "these checks are still running: $pending"
failing=$(jq -r 'map(select(.ok | not) | .name) | join(", ")' <<<"$checks")
[[ -z $failing ]] || block "these checks did not pass: $failing"

# PRs opened before propose-updates.sh started setting the build status only
# record the outcome in their body, so fall back to that for them.
if ! jq -e --arg c "$build_context" '.statusCheckRollup[] | select(.context == $c)' <<<"$info" >/dev/null; then
  grep -qF '| Build check | passed |' <<<"$(jq -r .body <<<"$info")" ||
    block "there is no passing \`$build_context\` status and the body doesn't say the build passed"
fi

echo "#$pr: approved by $reviewer at ${head:0:7}, mergeable, checks green: $(jq -r 'map(.name) | join(", ")' <<<"$checks")"
if [[ -n $dry ]]; then
  echo "dry run: would run gh pr merge $pr --squash --delete-branch --match-head-commit $head"
  echo "dry run: would run gh workflow run build-pkgs.yml --ref $base"
  exit 0
fi

gh pr merge "$pr" --squash --delete-branch --match-head-commit "$head"
gh workflow run build-pkgs.yml --ref "$base"
echo "merged #$pr and started build-pkgs.yml on $base"
