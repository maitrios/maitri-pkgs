#!/bin/bash
# Turn update-packages.yml's findings into one PR per package on auto/<name>,
# merge the ones whose recipe allows it once their build passed, hand the rest
# to the reviewer (merge-approved-updates.yml merges them on approval), close
# PRs whose package is current on main again, and start build-pkgs.yml for
# whatever merged.
#
#   propose-updates.sh <updates dir> <results dir>
#
# <updates dir> holds report.json from scripts/update-packages, a
# patches/<name>.patch per update and unchanged.txt (updates whose open PR
# already carries the same change). <results dir> holds <name>.json with the
# outcome of each verify build.
set -euo pipefail

updates=${1:?usage: propose-updates.sh <updates dir> <results dir>}
results=${2:?usage: propose-updates.sh <updates dir> <results dir>}
report=$updates/report.json
base=main
reviewer=beyera
build_context="update-packages / build"
run_url="$GITHUB_SERVER_URL/$GITHUB_REPOSITORY/actions/runs/$GITHUB_RUN_ID"
summary=${GITHUB_STEP_SUMMARY:-/dev/stdout}

git config user.name 'github-actions[bot]'
git config user.email '41898282+github-actions[bot]@users.noreply.github.com'
git fetch -q --no-tags origin "+refs/heads/$base:refs/remotes/origin/$base"

open_prs=$(gh pr list --base "$base" --state open --limit 200 --json number,headRefName,assignees \
  --jq '.[] | select(.headRefName | startswith("auto/")) | "\(.headRefName | ltrimstr("auto/"))\t\(.number)\t\([.assignees[].login] | join(","))"')

pr_for() { awk -F'\t' -v name="$1" '$1 == name { print $2 }' <<<"$open_prs"; }
assignees_for() { awk -F'\t' -v name="$1" '$1 == name { print $3 }' <<<"$open_prs"; }

hand_to_reviewer() {
  gh pr edit "$1" --add-reviewer "$reviewer" --add-assignee "$reviewer" >/dev/null
}

set_build_status() {
  local sha=$1 outcome=$2 state description
  case $outcome in
    success) state=success description="Package built in a clean container" ;;
    failure) state=failure description="Package build failed" ;;
    *) state=error description="Package build did not run ($outcome)" ;;
  esac
  gh api -X POST "repos/$GITHUB_REPOSITORY/statuses/$sha" -f state="$state" \
    -f context="$build_context" -f target_url="$run_url" -f description="$description" >/dev/null
}

pr_body() {
  local entry=$1 outcome=$2 auto=$3 build merge
  case $outcome in
    success) build="passed" ;;
    failure) build="**failed**, see the [run]($run_url)" ;;
    *) build="did not run ($outcome), see the [run]($run_url)" ;;
  esac
  if [[ $auto == true ]]; then
    merge="merges itself once the build check passes"
  else
    merge="waits for @$reviewer's approval, then merges itself"
  fi
  jq -r --arg run "$run_url" --arg build "$build" --arg merge "$merge" '
    "Automatic update from [update-packages](\($run)).\n\n" +
    "| | |\n|---|---|\n" +
    "| Package | `\(.name)` |\n" +
    "| Version | \(.old) → \(.new) |\n" +
    "| Found by | \(.method) |\n" +
    "| Build check | \($build) |\n" +
    "| Merge | \($merge) |\n\n" +
    "## How it was checked\n\n" +
    ((.notes // []) | map("- " + .) | join("\n")) + "\n"' <<<"$entry"
}

merge_pr() {
  local pr=$1 attempt
  for attempt in 1 2 3; do
    gh pr merge "$pr" --squash --delete-branch && return 0
    sleep $((attempt * 10))
  done
  return 1
}

merged=0
problems=0
rows=()

problem() {
  echo "::error::$1"
  problems=1
}

while IFS= read -r entry; do
  name=$(jq -r .name <<<"$entry")
  title=$(jq -r .title <<<"$entry")
  change=$(jq -r '"\(.old) → \(.new)"' <<<"$entry")
  pr=$(pr_for "$name")

  if grep -qxF "$name" "$updates/unchanged.txt"; then
    # Covers PRs opened before review requests were added, without
    # re-requesting a review every run once the reviewer has it.
    if [[ -n $pr && $(jq -r .auto_merge <<<"$entry") != true && ,$(assignees_for "$name"), != *,$reviewer,* ]]; then
      hand_to_reviewer "$pr" || problem "$name: could not hand #$pr to $reviewer"
    fi
    rows+=("| \`$name\` | $change | open, unchanged since the last run | ${pr:+#$pr} |")
    continue
  fi

  outcome=$(jq -r .outcome "$results/$name.json" 2>/dev/null || echo missing)
  auto=$(jq -r .auto_merge <<<"$entry")
  branch=auto/$name

  git switch -q -C "$branch" "origin/$base"
  if ! git apply --3way "$updates/patches/$name.patch"; then
    rows+=("| \`$name\` | $change | patch no longer applies to $base | ${pr:+#$pr} |")
    problem "$name: patch no longer applies to $base"
    continue
  fi
  git add -- "pkgbuilds/$name"
  git commit -q -m "$title"
  git push -q -f origin "$branch"
  set_build_status "$(git rev-parse HEAD)" "$outcome" || problem "$name: could not set the build status"

  body=$(pr_body "$entry" "$outcome" "$auto")
  if [[ -n $pr ]]; then
    gh pr edit "$pr" --title "$title" --body "$body" >/dev/null
  else
    url=$(gh pr create --base "$base" --head "$branch" --title "$title" --body "$body")
    pr=${url##*/}
  fi
  if [[ $auto != true ]]; then
    hand_to_reviewer "$pr" || problem "$name: could not hand #$pr to $reviewer"
  fi

  if [[ $outcome != success ]]; then
    state="build $outcome"
    problem "$name: build $outcome"
  elif [[ $auto != true ]]; then
    state="waiting for @$reviewer"
  elif merge_pr "$pr"; then
    state="merged"
    merged=$((merged + 1))
  else
    state="merge failed"
    problem "$name: merging #$pr failed"
  fi
  rows+=("| \`$name\` | $change | $state | #$pr |")
done < <(jq -c '.[] | select(.status == "updated")' "$report")

closed=()
while IFS= read -r name; do
  pr=$(pr_for "$name")
  [[ -n $pr ]] || continue
  gh pr close "$pr" --delete-branch \
    --comment "Closing: \`$name\` on $base is already at the newest upstream release ([run]($run_url))." >/dev/null
  closed+=("#$pr ($name)")
done < <(jq -r '.[] | select(.status == "current") | .name' "$report")

if ((merged)); then
  gh workflow run build-pkgs.yml --ref "$base"
fi

failed=$(jq -r '.[] | select(.status == "failed") | "### `\(.name)` (\(.method))\n\n```\n\(.error)\n```\n"' "$report")
while IFS= read -r line; do
  problem "$line"
done < <(jq -r '.[] | select(.status == "failed") | "\(.name) could not update: \(.error)" | gsub("%"; "%25") | gsub("\r"; "%0D") | gsub("\n"; "%0A")' "$report")

{
  echo "## Package updates"
  echo
  if ((${#rows[@]})); then
    echo "| Package | Version | State | PR |"
    echo "|---|---|---|---|"
    printf '%s\n' "${rows[@]}"
  else
    echo "Nothing new upstream."
  fi
  echo
  if ((merged)); then
    echo "Merged $merged, so build-pkgs.yml was started on $base."
    echo
  fi
  if ((${#closed[@]})); then
    echo "Closed as current: ${closed[*]}"
    echo
  fi
  if [[ -n $failed ]]; then
    echo "## Could not update"
    echo
    echo "$failed"
  fi
  jq -r '"\(map(select(.status == "current")) | length) current, \(map(select(.status == "manual")) | length) updated by hand: \(map(select(.status == "manual") | .name) | join(", "))"' "$report"
} >>"$summary"

exit $problems
