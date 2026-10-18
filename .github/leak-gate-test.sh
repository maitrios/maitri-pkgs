#!/bin/bash

# .github/leak-gate.sh against a scratch repository and the dummy pattern
# zzleakzz, so the real pattern never has to appear in a test.

pass() {
  printf 'ok - %s\n' "$1"
}

fail() {
  [[ -n ${2:-} ]] && printf '%s\n' "$2" >&2
  printf 'not ok - %s\n' "$1" >&2
  exit 1
}

gate="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)/leak-gate.sh"
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT

export GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1
export GIT_AUTHOR_NAME=test GIT_AUTHOR_EMAIL=test@example.invalid
export GIT_COMMITTER_NAME=test GIT_COMMITTER_EMAIL=test@example.invalid
unset LEAK_PATTERN PR_TITLE PR_BODY PR_BRANCH GITHUB_ACTIONS GITHUB_REPOSITORY

cd "$work" || fail "enter the scratch directory"
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
expect_leak "an added line is reported by file and line, ignoring case" "notes.txt:4"

run_gate "$base" LEAK_PATTERN=zzleakzz GITHUB_ACTIONS=true
expect_leak "an added line becomes an annotation on GitHub" "::error file=notes.txt,line=4::notes.txt:4"

run_gate "$base" LEAK_PATTERN=$'\n \nqqnothingqq\r\nzzleakzz\n'
expect_leak "a pattern file with several lines, blank lines and CRLF still matches" "notes.txt:4"

git checkout -q clean
run_gate "$base" LEAK_PATTERN=$'\n \nzzleakzz\r\n'
expect_status "blank lines in the pattern don't match everything" 0
pass "blank lines in the pattern don't match everything"

start plusses
printf 'first\n++ zzleakzz\n' > plus.txt
save "add plus"
run_gate "$base" LEAK_PATTERN=zzleakzz
expect_leak "an added line starting with ++ is not taken for a diff header" "plus.txt:2"

start message
echo four >> notes.txt
save $'tidy notes\n\nthe zzleakzz bit'
run_gate "$base" LEAK_PATTERN=zzleakzz
expect_leak "a commit message is reported by commit and line" "commit $(git rev-parse --short=12 HEAD) message, line 3"

start name
mkdir docs
echo "about the zzleakzz notes" > docs/zzleakzz-notes.md
echo fine > docs/other.md
save "add docs"
run_gate "$base" LEAK_PATTERN=zzleakzz
expect_leak "a matching file name is reported by number, never by name" \
  "the name of changed file #2" "changed file #2, line 1" "git diff -M --name-only"

start rename
git mv notes.txt zzleakzz.txt
save "rename notes"
run_gate "$base" LEAK_PATTERN=zzleakzz
expect_leak "a rename to a matching name is reported" "the name of changed file #1"

start binary
printf 'PNG\0\0zzleakzz\0' > image.bin
save "add image"
run_gate "$base" LEAK_PATTERN=zzleakzz
expect_leak "a binary file is searched too" "image.bin (binary)"

git checkout -q clean
run_gate "$base" LEAK_PATTERN=zzleakzz PR_TITLE="Add zzleakzz" PR_BODY=$'Adds a line.\r\nThe ZZLEAKZZ part.' PR_BRANCH=beyer/zzleakzz
expect_leak "the title, body and branch are reported by name" "the PR title" "the PR body, line 2" "the branch name"

run_gate "$line" LEAK_PATTERN=zzleakzz
expect_status "a removed line is not a leak" 0
pass "a removed line is not a leak"

run_gate "$base" LEAK_PATTERN=
expect_status "a missing pattern fails closed" 2
[[ $output == *"LEAK_PATTERN is empty"* ]] || fail "a missing pattern fails closed" "$output"
pass "a missing pattern fails closed"

run_gate "$base" LEAK_PATTERN=$'\n  \n'
expect_status "a pattern of blank lines counts as missing" 2
pass "a pattern of blank lines counts as missing"

run_gate "$base" LEAK_PATTERN= GITHUB_ACTIONS=true -- --fork
expect_status "a fork's PR passes with a warning when the pattern is missing" 0
[[ $output == "::warning::"*"by hand"* ]] || fail "a fork's PR passes with a warning when the pattern is missing" "$output"
pass "a fork's PR passes with a warning when the pattern is missing"

git checkout -q line
run_gate "$base" LEAK_PATTERN=zzleakzz -- --fork
expect_leak "a fork's PR is still checked when the pattern is there" "notes.txt:4"

run_gate "$base" LEAK_PATTERN='zzleak(zz'
expect_status "an invalid pattern fails without quoting it" 2
expect_quiet "an invalid pattern fails without quoting it"
pass "an invalid pattern fails without quoting it"

run_gate nope LEAK_PATTERN=zzleakzz
expect_status "an unknown base fails" 2
pass "an unknown base fails"
