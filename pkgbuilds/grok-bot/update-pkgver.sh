#!/usr/bin/env bash
# Resolve current Grok Bot stable from Cursor's update feed and pin PKGBUILD.
# The linux-x64 feed publishes the AppImage; the .debs live at the same commit.
set -euo pipefail

PKGBUILD_PATH="${1:-PKGBUILD}"
[[ -f "${PKGBUILD_PATH}" ]] || { echo "Error: PKGBUILD not found at '${PKGBUILD_PATH}'" >&2; exit 1; }

FEED='https://api2.cursor.sh/updates/api/update/linux-x64/sand/0.0.0/00000000-0000-0000-0000-000000000000/stable'
json="$(curl -fsSL -H 'cache-control: no-cache' "${FEED}")"

ver="$(jq -er '.version // .name' <<<"${json}")"
feed_url="$(jq -er '.url' <<<"${json}")"
commit="$(sed -nE 's@.*/(grokbot|sand)/stable/([0-9a-f]{40})/.*@\2@p' <<<"${feed_url}")"

[[ -n "${ver}" && -n "${commit}" ]] || {
  echo "Error: could not parse version/commit from feed: ${json}" >&2
  exit 1
}

tmp="$(mktemp)"
trap 'rm -f "${tmp}"' EXIT

deb_sum() {
  local url="https://downloads.cursor.com/grokbot/stable/${commit}/linux/$1/grok-bot_${ver}_$2.deb"
  local code
  code="$(curl -fsSIL -o /dev/null -w '%{http_code}' "${url}")"
  [[ "${code}" == "200" ]] || {
    echo "Error: Linux deb not fetchable (${code}): ${url}" >&2
    exit 1
  }
  curl -fsL --retry 3 -o "${tmp}" "${url}"
  sha256sum "${tmp}" | awk '{print $1}'
}

sum_x86_64="$(deb_sum x64 amd64)"
sum_aarch64="$(deb_sum arm64 arm64)"

current_ver="$(sed -nE 's/^pkgver=([^[:space:]#]+).*/\1/p' "${PKGBUILD_PATH}" | head -n1)"

sed -i -E \
  -e "s/^_commit=.*/_commit=${commit}/" \
  -e "s/^pkgver=.*/pkgver=${ver}/" \
  -e "s/^sha256sums_x86_64=.*/sha256sums_x86_64=('${sum_x86_64}')/" \
  -e "s/^sha256sums_aarch64=.*/sha256sums_aarch64=('${sum_aarch64}')/" \
  "${PKGBUILD_PATH}"

if [[ "${ver}" != "${current_ver}" ]]; then
  sed -i -E 's/^pkgrel=.*/pkgrel=1/' "${PKGBUILD_PATH}"
fi

echo "${ver} ${commit}"
echo "x86_64  ${sum_x86_64}"
echo "aarch64 ${sum_aarch64}"
