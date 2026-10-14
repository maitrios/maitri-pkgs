#!/usr/bin/env bash
# Resolve the current Cursor stable from the vendor's download feed and pin
# the PKGBUILD. The deb lives under a per-release commit path that pkgver
# does not spell, so a plain nvchecker bump would ask for the new version
# under the old commit and 404.
set -euo pipefail

PKGBUILD_PATH="${1:-PKGBUILD}"
[[ -f $PKGBUILD_PATH ]] || { echo "Error: PKGBUILD not found at '$PKGBUILD_PATH'" >&2; exit 1; }

FEED='https://api2.cursor.sh/updates/api/download/stable/linux-x64/cursor'
json="$(curl -fsSL -H 'cache-control: no-cache' "$FEED")"

ver="$(jq -er '.version' <<<"$json")"
commit="$(jq -er '.commitSha' <<<"$json")"
deb_url="$(jq -er '.debUrl' <<<"$json")"

[[ $commit =~ ^[0-9a-f]{40}$ ]] || { echo "Error: feed gave no commit: $json" >&2; exit 1; }

# The recipe builds this URL from _commit and pkgver, so refuse a feed whose
# own deb link does not match what the recipe would ask for.
expected="https://downloads.cursor.com/production/${commit}/linux/x64/deb/amd64/deb/cursor_${ver}_amd64.deb"
[[ $deb_url == "$expected" ]] || {
  echo "Error: feed deb URL is not the one the recipe builds" >&2
  echo "  feed:   $deb_url" >&2
  echo "  recipe: $expected" >&2
  exit 1
}

current_ver="$(sed -nE 's/^pkgver=([^[:space:]#]+).*/\1/p' "$PKGBUILD_PATH" | head -n1)"
current_commit="$(sed -nE 's/^_commit=([^[:space:]#]+).*/\1/p' "$PKGBUILD_PATH" | head -n1)"
if [[ $ver == "$current_ver" && $commit == "$current_commit" ]]; then
  echo "$ver $commit (already pinned)"
  exit 0
fi

tmp="$(mktemp)"
trap 'rm -f "$tmp"' EXIT
curl -fsL --retry 3 -o "$tmp" "$expected"
sum="$(sha512sum "$tmp" | awk '{print $1}')"

sed -i -E \
  -e "s/^_commit=.*/_commit=${commit}/" \
  -e "s/^pkgver=.*/pkgver=${ver}/" \
  -e "s/^sha512sums\[0\]=.*/sha512sums[0]=${sum}/" \
  "$PKGBUILD_PATH"

if [[ $ver != "$current_ver" ]]; then
  sed -i -E 's/^pkgrel=.*/pkgrel=1/' "$PKGBUILD_PATH"
fi

# A recipe reshaped by a later sync would leave one of those seds matching
# nothing, which would ship the new version under the old checksum.
for pinned in "_commit=${commit}" "pkgver=${ver}" "sha512sums[0]=${sum}"; do
  grep -qxF "$pinned" "$PKGBUILD_PATH" || {
    echo "Error: PKGBUILD does not carry '${pinned%%=*}' after the rewrite" >&2
    exit 1
  }
done

echo "$ver $commit"
echo "x86_64 $sum"
