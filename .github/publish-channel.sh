#!/bin/bash
# Publish /work/repo as the [maitri] pacman repository for one channel.
#
#   publish-channel.sh <stable|edge>
#
# /work/repo holds the channel's current assets plus whatever this run built.
# stable never carries the dev pair; edge keeps the newest dev pair it has
# (build-edge-dev.yml owns those). Packages and signatures upload before the
# database so a consumer mid-publish never sees a database naming a file that
# is not there yet. Every package is re-signed each run: a rebuilt package
# overwrites its .pkg and a stale .sig would fail verification.
set -euo pipefail

channel=${1:?usage: publish-channel.sh <stable|edge>}
repo=${GITHUB_REPOSITORY:?}
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

for p in *.pkg.tar.zst; do gpg --batch --yes --detach-sign --no-armor "$p"; done
repo-add maitri.db.tar.gz *.pkg.tar.zst
cp --remove-destination maitri.db.tar.gz maitri.db
cp --remove-destination maitri.files.tar.gz maitri.files

gh release view "$channel" -R "$repo" >/dev/null 2>&1 ||
  gh release create "$channel" -R "$repo" -t "maitri packages — $channel" -n "Rolling maitri package channel: $channel."

gh release upload "$channel" -R "$repo" --clobber ./*.pkg.tar.zst ./*.sig
gh release upload "$channel" -R "$repo" --clobber maitri.db maitri.db.tar.gz maitri.files maitri.files.tar.gz

# Delete release assets no longer present locally (superseded versions).
ls > /tmp/keep.txt
gh release view "$channel" -R "$repo" --json assets -q '.assets[].name' |
  while read -r asset; do
    grep -qxF "$asset" /tmp/keep.txt || {
      echo "deleting stale asset: $asset"
      gh release delete-asset "$channel" "$asset" -R "$repo" -y
    }
  done
