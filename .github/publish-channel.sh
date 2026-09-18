#!/bin/bash
# Publish /work/repo as the [maitri] pacman repository for one channel.
#
#   publish-channel.sh <stable|edge>
#
# /work/repo holds the channel's current assets plus whatever this run built.
# stable never carries the dev pair; edge keeps the newest dev pair it has
# (build-edge-dev.yml owns those). Packages and signatures upload before the
# database so a consumer mid-publish never sees a database naming a file that
# is not there yet, and stale assets go last so it never names one that is
# already gone.
#
# Only assets whose bytes differ from the release copy are touched (see
# release-api.sh for the request budget). A signature that still verifies
# against its package is kept, so an unchanged package costs no requests at
# all; a rebuilt package fails that check and is signed and uploaded again.
set -euo pipefail

channel=${1:?usage: publish-channel.sh <stable|edge>}
source "$(dirname "$(readlink -f "$0")")/release-api.sh"
cd /work/repo

rm -f maitri-local.* maitri.db* maitri.files*

if [[ $channel == stable ]]; then
  rm -f maitri-dev-* maitri-settings-dev-*
fi

# GitHub release assets cannot contain ":" (pacman epoch); rename so the DB
# %FILENAME% matches the uploaded asset name.
for f in *:*; do [[ -e $f ]] && mv -- "$f" "${f//:/.}"; done

# Drop packages whose recipe no longer exists; the cache seed would otherwise
# carry a retired package on the channel forever. Match on the pkgbase each
# recipe declares, not its directory name (pkgbuilds/yaru-icon-theme builds
# pkgbase yaru).
if [[ -n ${PKGBUILDS_DIR:-} && -d $PKGBUILDS_DIR ]]; then
  known=$(for d in "$PKGBUILDS_DIR"/*/; do
    [[ -f $d/PKGBUILD ]] || continue
    (cd "$d" && bash -c 'source ./PKGBUILD 2>/dev/null; echo "${pkgbase:-${pkgname[0]}}"')
  done)
  for p in *.pkg.tar.zst; do
    base=$(bsdtar -xOf "$p" .PKGINFO 2>/dev/null | sed -n 's/^pkgbase = //p' | head -1)
    [[ -n $base ]] || continue
    grep -qxF "$base" <<<"$known" && continue
    echo "retired recipe $base: dropping $p"
    rm -f -- "$p" "$p.sig"
  done
fi

# Keep only the newest build of each package; a rebuilt PKGBUILD leaves the
# previous version behind (the cache seed re-downloads it).
paccache --remove --keep 1 --nocolor --cachedir . || true
for s in *.sig; do [[ -e ${s%.sig} ]] || rm -f "$s"; done

signed=0
for p in *.pkg.tar.zst; do
  [[ -e $p.sig ]] && gpg --batch --quiet --verify "$p.sig" "$p" 2>/dev/null && continue
  gpg --batch --yes --detach-sign --no-armor "$p"
  signed=$((signed + 1))
done
echo "signed $signed packages; the rest keep their published signature"
repo-add maitri.db.tar.gz *.pkg.tar.zst
cp --remove-destination maitri.db.tar.gz maitri.db
cp --remove-destination maitri.files.tar.gz maitri.files

release=$(release_json "$channel")
if [[ -z $release ]]; then
  gh_retry gh release create "$channel" -R "$repo" -t "maitri packages — $channel" -n "Rolling maitri package channel: $channel."
fi

# upload_changed <file>...
# Upload, in one gh invocation, the files whose name or sha256 is not on the
# release, then list again and repeat until nothing differs. A batch cut
# short by a rate limit resumes with only what is still missing instead of
# clobbering every asset a second time. The last listing is left in
# $tmp/assets.tsv for the stale-asset pass.
upload_changed() {
  local pass json pending
  sha256sum -- "$@" | awk '{print $2 "\t" $1}' >"$tmp/local.tsv"
  for pass in 1 2 3 4 5; do
    json=$(release_json "$channel") || return 1
    assets_tsv <<<"$json" >"$tmp/assets.tsv"
    mapfile -t pending < <(awk -F'\t' -v A="$tmp/assets.tsv" '
      FILENAME == A { have[$1] = $3; next }
      !($1 in have) || have[$1] != $2 { print $1 }' "$tmp/assets.tsv" "$tmp/local.tsv")
    (( ${#pending[@]} )) || return 0
    echo "uploading ${#pending[@]} of $# files to $channel (pass $pass)"
    gh release upload "$channel" -R "$repo" --clobber "${pending[@]}" 2>"$tmp/gh_err" && continue
    rate_limit_pause "$tmp/gh_err" "$pass" && continue
    cat "$tmp/gh_err" >&2
    return 1
  done
  echo "::error::$channel assets still differ from the local set after $pass passes"
  return 1
}

upload_changed *.pkg.tar.zst *.sig
upload_changed maitri.db maitri.db.tar.gz maitri.files maitri.files.tar.gz

# Delete release assets no longer present locally (superseded versions,
# retired recipes, the dev pair on stable): one request each, by id from the
# listing the final verification pass just fetched.
ls >"$tmp/keep.txt"
while IFS=$'\t' read -r name id _; do
  grep -qxF "$name" "$tmp/keep.txt" && continue
  echo "deleting stale asset: $name"
  gh_retry gh api -X DELETE "repos/$repo/releases/assets/$id" >/dev/null
done <"$tmp/assets.tsv"
