#!/bin/bash

# Fail when a change carries one of the forbidden names. LEAK_PATTERN holds
# them as extended regexes, one per line, matched case-insensitively against
# everything <head> brings in over <base>: the lines its net diff adds, the
# lines each of its commits adds (so a match added and removed again still
# counts, and so does a merge's own resolution), the binary files they add,
# the raw names of files they add, copy or rename, their commit messages, and
# PR_TITLE, PR_BODY and PR_BRANCH when set. Only where something matched is
# printed, as file numbers and line numbers: never a name, the pattern or the
# text it matched. --quiet prints only whether it matched. Exits 1 on a match
# and 2 when it can't check.
#
#   LEAK_PATTERN=... leak-gate.sh [--quiet] <base> <head>

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

quiet=0
if [[ ${1:-} == "--quiet" ]]; then
  quiet=1
  shift
fi
(( $# == 2 )) || die "usage: leak-gate.sh [--quiet] <base> <head>"
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

found=0
report() {
  if (( ! found )) && (( ! quiet )); then
    echo "These match the forbidden-names pattern (the pattern and the text it matched are never printed):"
  fi
  found=$(( found + 1 ))
  (( quiet )) || echo "  $1"
}

commit=""
git_diff() {
  local spec=$1
  shift
  case $spec in
    net) git -c core.quotePath=false diff -M --no-color --no-ext-diff --no-textconv "$@" "$base...$head" ;;
    commit) git -c core.quotePath=false diff-tree -r --root -M --no-commit-id "$@" "$commit" ;;
    merge) git -c core.quotePath=false diff-tree --cc --no-commit-id "$@" "$commit" ;;
  esac
}

# Added lines from a patch on stdin, as "<path as git quotes it>\t<line>" in
# $work/where and the text in $work/added. Header lines are only read between
# "diff --" and the first hunk, so an added line that starts with "++" isn't
# taken for one. A combined (merge) diff has a prefix column per parent; a line
# counts when no column removes it and at least one adds it.
added_lines() {
  awk -v text="$work/added" -v where="$work/where" '
    /^diff --(git|cc|combined) / { header = 1; next }
    header && /^\+\+\+ / {
      path = substr($0, 5)
      if (path == "/dev/null") path = ""
      else if (substr(path, 1, 3) == "\"b/") path = "\"" substr(path, 4)
      else if (substr(path, 1, 2) == "b/") path = substr(path, 3)
      next
    }
    /^@@+ / {
      header = 0
      parents = 0
      while (substr($0, parents + 1, 1) == "@") parents++
      parents--
      match($0, / \+[0-9]+/)
      line = substr($0, RSTART + 2, RLENGTH - 2) + 0
      next
    }
    header || /^\\/ { next }
    {
      prefix = substr($0, 1, parents)
      if (prefix ~ /-/) next
      if (prefix ~ /\+/) { print substr($0, parents + 1) > text; print path "\t" line > where }
      line++
    }
  '
}

# A merge only brings in what none of its parents has: a name, or a blob at
# that path.
in_a_parent() {
  local object=$1 path=$2 parent
  for parent in "${parents[@]}"; do
    if [[ $object == "name" ]]; then
      git cat-file -e "$parent:$path" 2>/dev/null && return 0
    elif [[ $(git rev-parse --verify --quiet "$parent:$path" || true) == "$object" ]]; then
      return 0
    fi
  done
  return 1
}

# scan_diff <net|commit|merge> <label>: one diff's added names, lines and
# binary files. Files are numbered by their line in --name-only, and both
# spellings of a name (quoted, and raw from -z) map to the same number.
scan_diff() {
  local spec=$1 label=$2 i path raw line entry blob shown
  local -a quoted raws
  local -A number

  mapfile -t quoted < <(git_diff "$spec" --name-only)
  mapfile -d '' -t raws < <(git_diff "$spec" --name-only -z)
  (( ${#raws[@]} )) || return 0
  for i in "${!quoted[@]}"; do
    number[${quoted[i]}]=$(( i + 1 ))
    if [[ -n ${raws[i]:-} ]]; then
      number[${raws[i]}]=$(( i + 1 ))
    fi
  done
  parents=()
  if [[ $spec == "merge" ]]; then
    mapfile -t parents < <(git rev-parse "$commit^@")
  fi

  # Raw names, so git's quoting can't hide a match.
  if [[ $spec == "merge" ]]; then
    for raw in "${raws[@]}"; do
      if ! in_a_parent name "$raw" && matches <<<"$raw"; then
        report "$label file #${number[$raw]}, name"
      fi
    done
  else
    while IFS= read -r -d '' raw; do
      if matches <<<"$raw"; then
        report "$label file #${number[$raw]:-?}, name"
      fi
    done < <(git_diff "$spec" --name-only -z --diff-filter=ACR)
  fi

  : > "$work/added"
  : > "$work/where"
  git_diff "$spec" -p -U0 --src-prefix=a/ --dst-prefix=b/ | added_lines
  if [[ -s $work/added ]]; then
    while IFS=$'\t' read -r path line; do
      report "$label file #${number[$path]:-?}, line $line"
    done < <(awk 'NR == FNR { hit[$1]; next } FNR in hit' <(matching_lines < "$work/added") "$work/where")
  fi

  # Binary files by their raw names, so cat-file finds them. Deleted ones are
  # left out, so a blob that can't be read is an error, not a skip.
  while IFS= read -r -d '' entry; do
    [[ ${entry%%$'\t'*} == "-" ]] || continue
    path=${entry#*$'\t'}
    path=${path#*$'\t'}
    shown="$label file #${number[$path]:-?}"
    blob=$(git rev-parse --verify --quiet "${commit:-$head}:$path") || die "can't read $shown"
    if [[ $spec == "merge" ]] && in_a_parent "$blob" "$path"; then
      continue
    fi
    if matches < <(git cat-file blob "$blob"); then
      report "$shown, binary content"
    fi
  done < <(
    case $spec in
      net) git diff --no-renames --no-ext-diff --no-textconv --diff-filter=d --numstat -z "$base...$head" ;;
      commit) git diff-tree -r --root --no-commit-id --no-renames --diff-filter=d --numstat -z "$commit" ;;
      merge) git diff-tree -r --no-commit-id --no-renames --diff-filter=d --numstat -z "$commit^1" "$commit" ;;
    esac
  )
}

net_numbered=0
commit_numbered=0

scan_diff net "changed"
(( found )) && net_numbered=1

while read -r commit; do
  before=$found
  if (( $(git rev-list --parents -n 1 "$commit" | wc -w) > 2 )); then
    scan_diff merge "commit ${commit:0:12}"
  else
    scan_diff commit "commit ${commit:0:12}"
  fi
  (( found > before )) && commit_numbered=1
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
  if (( quiet )); then
    say error "Forbidden names found. Locations aren't shown for PRs from forks."
    exit 1
  fi
  if (( net_numbered )); then
    echo "Changed file numbers count the lines of: git diff -M --name-only ${base:0:12}...${head:0:12}"
  fi
  if (( commit_numbered )); then
    echo "A commit's file numbers count the lines of: git show -M --format= --name-only <commit>"
  fi
  if [[ ${GITHUB_ACTIONS:-} == "true" ]]; then
    echo "::error::Forbidden names found; the lines above say where."
  fi
  exit 1
fi
echo "No forbidden names in ${base:0:12}...${head:0:12}"
