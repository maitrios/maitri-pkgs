#!/bin/bash
# GitHub release helpers shared by the build and publish steps.
#
#   source release-api.sh                          # functions below
#   release-api.sh fetch <channel> <dir> <glob>...  # download matching assets
#
# GITHUB_TOKEN gets 1,000 API requests an hour for the repository, and every
# asset upload, delete and metered download is one request. Back-to-back
# publishes (a pkgbuilds push plus the maitri-dev builds) blew that budget, so
# everything here spends as few requests as it can and waits out the bucket
# instead of failing when it is empty.
set -euo pipefail

repo=${GITHUB_REPOSITORY:?}
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT

# Sleeps and returns 0 when a failed gh command's stderr shows a primary or
# secondary rate limit; returns 1 for any other failure. gh itself only
# retries 5xx and network errors. The rate_limit endpoint is not metered and
# reports the same reset time as the X-RateLimit-Reset header on the refused
# request, so a drained bucket waits exactly until it refills; a secondary
# limit (bucket not empty) backs off exponentially from one minute.
rate_limit_pause() {
  local errfile=$1 attempt=$2 remaining= reset= now delay
  grep -qiE 'rate limit|HTTP 429' "$errfile" || return 1
  read -r remaining reset < <(gh api rate_limit -q '.resources.core | "\(.remaining) \(.reset)"' 2>/dev/null || echo) || true
  now=$(date +%s)
  if [[ ${remaining:-1} == 0 && ${reset:-0} -gt $now ]]; then
    delay=$(( reset - now + 15 ))
  else
    delay=$(( 60 << (attempt - 1) ))
  fi
  (( delay > 3900 )) && delay=3900
  echo "rate limited: $(head -1 "$errfile")" >&2
  echo "waiting ${delay}s for the API bucket (attempt $attempt)" >&2
  sleep "$delay"
}

# Run a gh command, waiting out rate limits up to five times.
gh_retry() {
  local attempt
  for attempt in 1 2 3 4 5; do
    "$@" 2>"$tmp/gh_err" && return 0
    rate_limit_pause "$tmp/gh_err" "$attempt" && continue
    cat "$tmp/gh_err" >&2
    return 1
  done
  cat "$tmp/gh_err" >&2
  return 1
}

# The channel's release as JSON (one request, assets embedded), or nothing
# when the channel has no release yet. Any other failure aborts: a publish
# that took an empty listing at face value would delete the whole channel
# as stale.
release_json() {
  local out
  if out=$(gh_retry gh api "repos/$repo/releases/tags/$1" 2>"$tmp/release_err"); then
    printf '%s' "$out"
    return 0
  fi
  grep -q 'HTTP 404' "$tmp/release_err" && return 0
  cat "$tmp/release_err" >&2
  return 1
}

# name, id, sha256, download URL per asset, tab separated, from release JSON.
assets_tsv() {
  jq -r '.assets[] | [.name, .id, ((.digest // "") | ltrimstr("sha256:")), .browser_download_url] | @tsv'
}

fetch_one() {
  local dir=$1 name=$2 sha=$3 url=$4 got
  if ! curl -fsSL --retry 5 --retry-all-errors --retry-delay 3 -o "$dir/$name.part" "$url"; then
    echo "download failed: $name" >&2
    rm -f "$dir/$name.part"
    return 1
  fi
  got=$(sha256sum "$dir/$name.part" | cut -d' ' -f1)
  if [[ $sha != - && $got != "$sha" ]]; then
    echo "checksum mismatch: $name" >&2
    rm -f "$dir/$name.part"
    return 1
  fi
  mv "$dir/$name.part" "$dir/$name"
}
export -f fetch_one

# fetch_assets <channel> <dir> <glob>...
# Download the channel's assets matching any glob into dir. The repository is
# public, so the release download URLs are served without touching the API:
# one listing request replaces the request per asset that `gh release
# download` spends. Files already in dir are left alone, so whatever a run
# built (or fetched from stable first) wins over the release copy. Every
# download is checked against the asset's sha256.
fetch_assets() {
  local channel=$1 dir=$2 json name id sha url g
  shift 2
  json=$(release_json "$channel") || return 1
  if [[ -z $json ]]; then
    echo "no $channel release yet"
    return 0
  fi
  mkdir -p "$dir"
  : >"$tmp/fetch.txt"
  while IFS=$'\t' read -r name id sha url; do
    [[ -e $dir/$name ]] && continue
    for g in "$@"; do
      # shellcheck disable=SC2053
      if [[ $name == $g ]]; then
        printf '%s %s %s\n' "$name" "${sha:--}" "$url" >>"$tmp/fetch.txt"
        break
      fi
    done
  done < <(assets_tsv <<<"$json")
  if [[ ! -s $tmp/fetch.txt ]]; then
    echo "fetched 0 assets from $channel (all present)"
    return 0
  fi
  xargs -P 8 -L 1 bash -c 'fetch_one "$@"' _ "$dir" <"$tmp/fetch.txt"
  echo "fetched $(wc -l <"$tmp/fetch.txt") assets from $channel"
}

if [[ ${BASH_SOURCE[0]} == "$0" ]]; then
  cmd=${1:-}
  shift || true
  case $cmd in
    fetch) fetch_assets "$@" ;;
    *) echo "usage: release-api.sh fetch <channel> <dir> <glob>..." >&2; exit 2 ;;
  esac
fi
