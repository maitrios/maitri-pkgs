#!/bin/bash

# Fail when a change carries one of the forbidden names. LEAK_PATTERN holds
# them as extended regexes, one per line, matched case-insensitively against
# the lines <head> adds over its merge base with <base>, the names of the files
# it adds, copies or renames, its commit messages, and PR_TITLE, PR_BODY and
# PR_BRANCH when set. Only where something matched is printed, never the
# pattern or the text it matched. Exits 1 on a match and 2 when it can't check.
#
#   LEAK_PATTERN=... leak-gate.sh <base> <head>

set -euo pipefail

say() {
  if [[ ${GITHUB_ACTIONS:-} == "true" ]]; then
    echo "::$1::${2//%/%25}"
  else
    echo "leak-gate: $2" >&2
  fi
}

die() {
  say error "$1"
  exit 2
}

(( $# == 2 )) || die "usage: leak-gate.sh <base> <head>"
base=$(git rev-parse --verify --quiet "$1^{commit}") || die "$1 is not a commit in this clone"
head=$(git rev-parse --verify --quiet "$2^{commit}") || die "$2 is not a commit in this clone"

work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
patterns="$work/patterns"

# A blank line in a -f pattern file matches every line.
printf '%s\n' "${LEAK_PATTERN:-}" | tr -d '\r' | sed '/^[[:space:]]*$/d' > "$patterns"
unset LEAK_PATTERN

[[ -s $patterns ]] || die "LEAK_PATTERN is empty. Set it in the leak-gate environment from the pattern file: gh secret set LEAK_PATTERN --env leak-gate -R ${GITHUB_REPOSITORY:-<owner>/<repo>} < <file>"

# grep's own error for a bad regex can quote the pattern, so it never reaches the log.
status=0
grep -q -i -E -f "$patterns" </dev/null 2>/dev/null || status=$?
(( status == 1 )) || die "LEAK_PATTERN is not a valid extended regex"

matches() {
  grep -q -a -i -E -f "$patterns" 2>/dev/null
}

matching_lines() {
  { grep -n -a -h -i -E --color=never -f "$patterns" 2>/dev/null || true; } | cut -d: -f1
}

escape_property() {
  local value=${1//%/%25}
  value=${value//:/%3A}
  printf '%s' "${value//,/%2C}"
}

found=0
numbered=0
report() {
  local where=$1 file=${2:-} line=${3:-}

  if (( ! found )); then
    found=1
    echo "These match the forbidden-names pattern (the pattern and the text it matched are never printed):"
  fi
  if [[ ${GITHUB_ACTIONS:-} == "true" && -n $file ]]; then
    echo "::error file=$(escape_property "$file"),line=$line::${where//%/%25}"
  elif [[ ${GITHUB_ACTIONS:-} == "true" ]]; then
    echo "::error::${where//%/%25}"
  else
    echo "  $where"
  fi
}

diff_args=(-c core.quotePath=false diff -M --no-color --no-ext-diff --no-textconv --src-prefix=a/ --dst-prefix=b/)

# Numbered by both the quoted and the raw (-z) spelling of each name.
declare -A file_number
mapfile -t changed < <(git "${diff_args[@]}" --name-only "$base...$head")
mapfile -d '' -t changed_raw < <(git "${diff_args[@]}" --name-only -z "$base...$head")
for i in "${!changed[@]}"; do
  file_number[${changed[i]}]=$(( i + 1 ))
  if [[ -n ${changed_raw[i]:-} ]]; then
    file_number[${changed_raw[i]}]=$(( i + 1 ))
  fi
done

name_file() {
  name=$1
  if matches <<<"$1"; then
    numbered=1
    name="changed file #${file_number[$1]:-?}"
  fi
}

mapfile -t added < <(git "${diff_args[@]}" --name-only --diff-filter=ACR "$base...$head")
for path in "${added[@]}"; do
  if matches <<<"$path"; then
    numbered=1
    report "the name of changed file #${file_number[$path]:-?}"
  fi
done

# Added lines, with where each one lands in <head>. Header lines are only read
# between "diff --git" and the first hunk, so an added line that starts with
# "++" isn't taken for one.
git "${diff_args[@]}" -U0 "$base...$head" | awk -v text="$work/added" -v where="$work/where" '
  /^diff --git / { header = 1; next }
  header && /^\+\+\+ / {
    path = substr($0, 5)
    if (path == "/dev/null") path = ""
    else if (substr(path, 1, 3) == "\"b/") path = "\"" substr(path, 4)
    else if (substr(path, 1, 2) == "b/") path = substr(path, 3)
    next
  }
  /^@@ / { header = 0; match($0, /\+[0-9]+/); line = substr($0, RSTART + 1, RLENGTH - 1) + 0; next }
  header { next }
  /^\+/ { print substr($0, 2) > text; print path "\t" line > where; line++ }
'
if [[ -s $work/added ]]; then
  while IFS=$'\t' read -r path line; do
    name_file "$path"
    if [[ $name == "$path" ]]; then
      report "$path:$line" "$path" "$line"
    else
      report "$name, line $line"
    fi
  done < <(awk 'NR == FNR { hit[$1]; next } FNR in hit' <(matching_lines < "$work/added") "$work/where")
fi

# Binary files, by their raw names so cat-file finds them. Deleted ones are
# left out, so a blob that can't be read is an error, not a skip.
while IFS= read -r -d '' entry; do
  [[ ${entry%%$'\t'*} == "-" ]] || continue
  path=${entry#*$'\t'}
  path=${path#*$'\t'}
  number=${file_number[$path]:-}
  blob=$(git rev-parse --verify --quiet "$head:$path") || die "can't read changed file #${number:-?} at ${head:0:12}"
  if matches < <(git cat-file blob "$blob"); then
    shown=$path
    [[ -n $number ]] && shown=${changed[number - 1]}
    name_file "$shown"
    report "$name (binary)"
  fi
done < <(git diff --no-renames --no-ext-diff --no-textconv --diff-filter=d --numstat -z "$base...$head")

while read -r commit; do
  while read -r line; do
    report "commit ${commit:0:12} message, line $line"
  done < <(git log -1 --format=%B "$commit" | matching_lines)
done < <(git rev-list "$base..$head")

if [[ -n ${PR_TITLE:-} ]] && matches <<<"$PR_TITLE"; then
  report "the PR title"
fi
while read -r line; do
  report "the PR body, line $line"
done < <(matching_lines <<<"${PR_BODY:-}")
if [[ -n ${PR_BRANCH:-} ]] && matches <<<"$PR_BRANCH"; then
  report "the branch name"
fi

if (( found )); then
  (( numbered )) && echo "File numbers count the lines of: git diff -M --name-only ${base:0:12}...${head:0:12}"
  exit 1
fi
echo "No forbidden names in ${base:0:12}...${head:0:12}"
