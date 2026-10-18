#!/bin/bash

# .github/leak-gate.sh and .github/leak-gate-ci.sh against a scratch
# repository and the dummy pattern zzleakzz, so the real pattern never has to
# appear in a test.

pass() {
  printf 'ok - %s\n' "$1"
}

fail() {
  [[ -n ${2:-} ]] && printf '%s\n' "$2" >&2
  printf 'not ok - %s\n' "$1" >&2
  exit 1
}

here=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
gate="$here/leak-gate.sh"
ci="$here/leak-gate-ci.sh"
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT

export GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1
export GIT_AUTHOR_NAME=test GIT_AUTHOR_EMAIL=test@example.invalid
export GIT_COMMITTER_NAME=test GIT_COMMITTER_EMAIL=test@example.invalid
unset LEAK_PATTERN PR_TITLE PR_BODY PR_BRANCH GITHUB_ACTIONS GITHUB_REPOSITORY

mkdir "$work/repo"
cd "$work/repo" || fail "enter the scratch repository"
git init -q -b main
printf 'one\ntwo\nthree\n' > notes.txt
git add notes.txt
git commit -q -m "start"
base=$(git rev-parse HEAD)

start() {
  git checkout -q -B "$1" "$base"
}

save() {
  git add -A
  git commit -q -m "$1"
}

short() {
  git rev-parse --short=12 "$1"
}

# run_gate <base> [VAR=value...] [-- gate args]
run_gate() {
  local from=$1
  shift
  local vars=() args=()
  while (( $# )); do
    if [[ $1 == "--" ]]; then
      shift
      args=("$@")
      break
    fi
    vars+=("$1")
    shift
  done
  status=0
  output=$(env "${vars[@]}" "$gate" "${args[@]}" "$from" HEAD 2>&1) || status=$?
}

expect_status() {
  local description=$1 expected=$2
  (( status == expected )) || fail "$description" "exit $status, expected $expected:"$'\n'"$output"
}

expect_quiet() {
  local description=$1
  if grep -q -i zzleak <<<"$output"; then
    fail "$description" "the output repeats what matched:"$'\n'"$output"
  fi
}

expect_absent() {
  local description=$1 text
  shift
  for text in "$@"; do
    [[ $output != *"$text"* ]] || fail "$description" "'$text' is in:"$'\n'"$output"
  done
}

expect_leak() {
  local description=$1 where
  shift
  expect_status "$description" 1
  for where in "$@"; do
    [[ $output == *"$where"* ]] || fail "$description" "no '$where' in:"$'\n'"$output"
  done
  expect_quiet "$description"
  pass "$description"
}

start clean
echo four >> notes.txt
save "add four"
run_gate "$base" LEAK_PATTERN=zzleakzz PR_TITLE="Add four" PR_BODY="Adds a line." PR_BRANCH=beyer/four
expect_status "a clean change passes" 0
pass "a clean change passes"

start line
printf 'one\ntwo\nthree\nsome ZZLeakZZ here\n' > notes.txt
save "update notes"
line=$(git rev-parse HEAD)
run_gate "$base" LEAK_PATTERN=zzleakzz
expect_absent "an added line is reported by file number and line, ignoring case" "notes.txt"
expect_leak "an added line is reported by file number and line, ignoring case" \
  "changed file #1, line 4" "commit $(short HEAD) file #1, line 4" "git diff -M --name-only" "git show -M"

run_gate "$base" LEAK_PATTERN=zzleakzz GITHUB_ACTIONS=true
expect_absent "on GitHub there's one error and no file annotation" "file="
expect_leak "on GitHub there's one error and no file annotation" "::error::Forbidden names found"

run_gate "$base" LEAK_PATTERN=zzleakzz -- --quiet
expect_absent "--quiet says only that it matched" "file #" "line" "commit"
expect_leak "--quiet says only that it matched" "Locations aren't shown"

run_gate "$base" LEAK_PATTERN=$'\n \nqqnothingqq\r\nzzleakzz\n'
expect_leak "a pattern file with several lines, blank lines and CRLF still matches" "changed file #1, line 4"

git checkout -q clean
run_gate "$base" LEAK_PATTERN=$'\n \nzzleakzz\r\n'
expect_status "blank lines in the pattern don't match everything" 0
pass "blank lines in the pattern don't match everything"

start plusses
printf 'first\n++ zzleakzz\n' > plus.txt
save "add plus"
run_gate "$base" LEAK_PATTERN=zzleakzz
expect_leak "an added line starting with ++ is not taken for a diff header" "changed file #1, line 2"

start message
echo four >> notes.txt
save $'tidy notes\n\nthe zzleakzz bit'
run_gate "$base" LEAK_PATTERN=zzleakzz
expect_leak "a commit message is reported by commit and line" "commit $(short HEAD) message, line 3"

start name
mkdir docs
echo "about the zzleakzz notes" > docs/zzleakzz-notes.md
echo fine > docs/other.md
save "add docs"
run_gate "$base" LEAK_PATTERN=zzleakzz
expect_absent "a file is only ever named by its number" "docs" "other.md"
expect_leak "a file is only ever named by its number" "changed file #2, name" "changed file #2, line 1"

start tabname
echo fine > $'note\tzzleakzz.txt'
save "add a tabbed name"
run_gate "$base" 'LEAK_PATTERN=[[:space:]]zzleakzz'
expect_absent "a name is matched raw, so a tab in it can't hide a match" "note"
expect_leak "a name is matched raw, so a tab in it can't hide a match" "changed file #1, name"

start rename
git mv notes.txt zzleakzz.txt
save "rename notes"
run_gate "$base" LEAK_PATTERN=zzleakzz
expect_leak "a rename to a matching name is reported" "changed file #1, name"

start binary
printf 'PNG\0\0zzleakzz\0' > image.bin
save "add image"
run_gate "$base" LEAK_PATTERN=zzleakzz
expect_leak "a binary file is searched too" "changed file #1, binary content"

start oddbinary
printf 'PNG\0\0zzleakzz\0' > $'odd "name"\twith\\slash.bin'
save "add odd image"
run_gate "$base" LEAK_PATTERN=zzleakzz
expect_leak "a binary file with a quote, tab and backslash in its name is searched too" "changed file #1, binary content"

git checkout -q -B dropbinary binary
git rm -q image.bin
save "drop image"
run_gate "$(git rev-parse binary)" LEAK_PATTERN=zzleakzz
expect_status "a deleted binary file is not a leak" 0
pass "a deleted binary file is not a leak"

start addremove
echo "a zzleakzz line" >> notes.txt
save "add a line"
added=$(git rev-parse HEAD)
printf 'one\ntwo\nthree\n' > notes.txt
save "take it out again"
run_gate "$base" LEAK_PATTERN=zzleakzz
expect_absent "a line added and removed again still fails" "changed file"
expect_leak "a line added and removed again still fails" "commit $(short "$added") file #1, line 4"

start addremovebinary
printf 'PNG\0zzleakzz\0' > image.bin
save "add image"
added=$(git rev-parse HEAD)
git rm -q image.bin
save "drop image"
run_gate "$base" LEAK_PATTERN=zzleakzz
expect_leak "a binary added and removed again still fails" "commit $(short "$added") file #1, binary content"

start renameaway
echo fine > zzleakzz.txt
save "add a file"
added=$(git rev-parse HEAD)
git mv zzleakzz.txt fine.txt
save "rename it"
run_gate "$base" LEAK_PATTERN=zzleakzz
expect_leak "a name renamed away again still fails" "commit $(short "$added") file #1, name"

git checkout -q -B side-a "$base"
sed -i 's/^two$/two-a/' notes.txt
save "a side"
git checkout -q -B side-b "$base"
sed -i 's/^two$/two-b/' notes.txt
save "b side"
git merge -q side-a >/dev/null 2>&1 || true
printf 'one\ntwo zzleakzz\nthree\n' > notes.txt
git add notes.txt
git commit -q --no-edit
merge=$(git rev-parse HEAD)
run_gate "$base" LEAK_PATTERN=zzleakzz
expect_leak "a merge's own conflict resolution is checked" "commit $(short "$merge") file #1, line 2"

git checkout -q -B dirty "$base"
echo "an old zzleakzz line" >> notes.txt
save "old line"
dirty=$(git rev-parse HEAD)
printf 'one\ntwo\nthree\n' > notes.txt
save "remove the old line"
run_gate "$dirty" LEAK_PATTERN=zzleakzz
expect_status "removing a line the base already has is not a leak" 0
pass "removing a line the base already has is not a leak"

git checkout -q clean
run_gate "$base" LEAK_PATTERN=zzleakzz PR_TITLE="Add zzleakzz" PR_BODY=$'Adds a line.\r\nThe ZZLEAKZZ part.' PR_BRANCH=beyer/zzleakzz
expect_leak "the title, body and branch are reported by name" "the PR title" "the PR body, line 2" "the branch name"

run_gate "$line" LEAK_PATTERN=zzleakzz
expect_status "a line only the base has is not a leak" 0
pass "a line only the base has is not a leak"

run_gate "$base" LEAK_PATTERN=
expect_status "a missing pattern fails closed" 2
[[ $output == *"LEAK_PATTERN is empty"* ]] || fail "a missing pattern fails closed" "$output"
pass "a missing pattern fails closed"

run_gate "$base" LEAK_PATTERN=$'\n  \n'
expect_status "a pattern of blank lines counts as missing" 2
pass "a pattern of blank lines counts as missing"

run_gate "$base" LEAK_PATTERN='zzleak(zz'
expect_status "an invalid pattern fails without quoting it" 2
expect_quiet "an invalid pattern fails without quoting it"
pass "an invalid pattern fails without quoting it"

run_gate nope LEAK_PATTERN=zzleakzz
expect_status "an unknown base fails" 2
pass "an unknown base fails"

# leak-gate-ci.sh, with a local origin and a gh that serves canned PRs and
# records the statuses it's asked to post.
mkdir -p "$work/origin/o" "$work/bin" "$work/gh"
git init -q --bare "$work/origin/o/r.git"
git -C "$work/origin/o/r.git" config uploadpack.allowFilter true
git -C "$work/origin/o/r.git" config uploadpack.allowAnySHA1InWant true
git push -q "$work/origin/o/r.git" --all

cat > "$work/bin/gh" <<'GH'
#!/bin/bash
case "$*" in
  "api -X POST repos/o/r/statuses/"*)
    sha=${4##*/}
    for arg in "$@"; do
      [[ $arg == state=* ]] && echo "${sha:0:12} ${arg#state=}" >> "$FAKE_GH/statuses"
    done
    [[ ! -e $FAKE_GH/status-fails ]]
    ;;
  "api --paginate repos/o/r/pulls?state=open&per_page=100")
    [[ ! -e $FAKE_GH/list-fails ]] || { echo "HTTP 502" >&2; exit 1; }
    cat "$FAKE_GH/open.json"
    ;;
  "api repos/o/r/pulls/"*)
    jq --argjson n "${2##*/}" '.[] | select(.number == $n)' "$FAKE_GH/open.json"
    ;;
  *)
    echo "fake gh: unexpected: $*" >&2
    exit 1
    ;;
esac
GH
chmod +x "$work/bin/gh"

# pr <number> <head> <title> [<head repo>]
pr() {
  jq -n --argjson n "$1" --arg head "$(git rev-parse "$2")" --arg title "$3" --arg repo "${4:-o/r}" --arg base "$base" \
    '{number: $n, title: $title, body: "", head: {sha: $head, ref: "beyer/x", repo: {full_name: $repo}}, base: {sha: $base}}'
}

# open_prs <pr json>...: the open PRs the fake gh lists, as one page.
open_prs() {
  printf '%s\n' "$@" | jq -s . > "$work/gh/open.json"
}

# run_ci <event> <event json> [VAR=value...]
run_ci() {
  local event=$1 json=$2 clone
  shift 2
  clone=$(mktemp -d -p "$work")
  git init -q "$clone"
  git -C "$clone" remote add origin "file://$work/origin/o/r.git"
  printf '%s\n' "$json" > "$work/event.json"
  : > "$work/gh/statuses"
  status=0
  output=$(cd "$clone" && env PATH="$work/bin:$PATH" FAKE_GH="$work/gh" GITHUB_REPOSITORY=o/r GITHUB_EVENT_NAME="$event" \
    GITHUB_EVENT_PATH="$work/event.json" GITHUB_SHA="$base" RUNNER_TEMP="$(mktemp -d -p "$work")" \
    RUN_URL=https://example.invalid/run LEAK_PATTERN=zzleakzz "$@" bash "$ci" "$gate" 2>&1) || status=$?
  posted=$(<"$work/gh/statuses")
}

expect_posted() {
  local description=$1 expected=$2
  [[ $posted == "$expected" ]] || fail "$description" "posted:"$'\n'"$posted"$'\n'"expected:"$'\n'"$expected"$'\n'"$output"
}

run_event() {
  jq -n --arg sha "$(git rev-parse "$1")" '{workflow_run: {head_sha: $sha}}'
}

head=$(short clean)
open_prs "$(pr 1 clean "Add zzleakzz")" "$(pr 2 clean "Add four")"
run_ci workflow_run "$(run_event clean)"
expect_status "two PRs at one SHA get one status, the worst" 1
expect_posted "two PRs at one SHA get one status, the worst" "$head pending"$'\n'"$head failure"
expect_quiet "two PRs at one SHA get one status, the worst"
pass "two PRs at one SHA get one status, the worst"

touch "$work/gh/list-fails"
run_ci workflow_run "$(run_event clean)"
rm "$work/gh/list-fails"
expect_status "a PR list that fails posts error, never pending or success" 2
expect_posted "a PR list that fails posts error, never pending or success" "$head error"
pass "a PR list that fails posts error, never pending or success"

open_prs "$(pr 3 line "Update notes")"
run_ci workflow_run "$(run_event line)"
expect_leak "a same-repo PR gets locations" "changed file #1, line 4"
expect_posted "a same-repo PR gets locations" "$(short line) pending"$'\n'"$(short line) failure"

open_prs "$(pr 3 line "Update notes" someone/r)"
run_ci workflow_run "$(run_event line)"
expect_absent "a fork's PR only learns pass or fail" "file #" "line 4"
expect_leak "a fork's PR only learns pass or fail" "Locations aren't shown"
expect_posted "a fork's PR only learns pass or fail" "$(short line) pending"$'\n'"$(short line) failure"

open_prs "$(pr 4 clean "Add four")"
run_ci workflow_run "$(run_event line)"
expect_status "a SHA no open PR has gets no status" 0
expect_posted "a SHA no open PR has gets no status" ""
pass "a SHA no open PR has gets no status"

run_ci workflow_dispatch "{}" PR_NUMBER=4
expect_status "a dispatch checks the PR's head" 0
expect_posted "a dispatch checks the PR's head" "$head pending"$'\n'"$head success"
pass "a dispatch checks the PR's head"

touch "$work/gh/status-fails"
run_ci workflow_dispatch "{}" PR_NUMBER=4
rm "$work/gh/status-fails"
(( status != 0 )) || fail "a status that can't be posted fails and says why" "$output"
[[ $output == *"Couldn't post the leak-gate status"* ]] || fail "a status that can't be posted fails and says why" "$output"
pass "a status that can't be posted fails and says why"

git checkout -q -B squash "$base"
echo four >> notes.txt
save "Squash: the zzleakzz fix"
git push -q "$work/origin/o/r.git" squash
run_ci push "$(jq -n --arg before "$base" '{before: $before}')" GITHUB_SHA="$(git rev-parse squash)"
expect_leak "a push to main checks the squash message and fails loudly" "message, line 1" "Forbidden names on main"
expect_posted "a push to main checks the squash message and fails loudly" "$(short squash) pending"$'\n'"$(short squash) failure"
