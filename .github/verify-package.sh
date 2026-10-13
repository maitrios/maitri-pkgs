#!/bin/bash
# Build one recipe in a fresh Arch container the way build-pkgs.yml will,
# without publishing anything. update-packages.yml runs this on every update
# before it opens or merges a PR.
#
#   verify-package.sh <recipe dir> <maitri-keyring recipe dir>
#
# Dependencies resolve from Arch and the published [maitri] stable channel.
# PKGEXT skips the recipes' maximum zstd, since nothing built here ships.
set -euo pipefail

recipe=${1:?usage: verify-package.sh <recipe dir> <keyring dir>}
keyring=${2:?usage: verify-package.sh <recipe dir> <keyring dir>}

sed -i "s/^#\?ParallelDownloads.*/ParallelDownloads = 10/" /etc/pacman.conf
pacman-key --init >/dev/null
pacman-key --populate archlinux >/dev/null
pacman-key --add "$keyring/maitri.gpg" >/dev/null
while IFS=: read -r fpr _; do
  [[ -n $fpr ]] && pacman-key --lsign-key "$fpr" >/dev/null
done <"$keyring/maitri-trusted"
printf '\n[maitri]\nServer = https://github.com/maitrios/maitri-pkgs/releases/download/stable\n' >>/etc/pacman.conf
pacman -Syu --noconfirm --needed --noprogressbar base-devel git sudo
printf 'MAKEFLAGS="-j%s"\n' "$(nproc)" >>/etc/makepkg.conf

useradd -m builder
printf 'builder ALL=(ALL) NOPASSWD: ALL\n' >/etc/sudoers.d/builder
cp -r "$recipe" /build
chown -R builder:builder /build
cd /build
sudo -u builder env PKGEXT=.pkg.tar makepkg -s --noconfirm --noprogressbar --skippgpcheck

# /bin, /lib, /usr/sbin and friends are symlinks the filesystem package owns;
# a package carrying them as directories makes pacman refuse the transaction.
status=0
for pkg in *.pkg.tar; do
  clash=$(bsdtar -tf "$pkg" | grep -E '^(bin|sbin|lib|lib64|usr/sbin|usr/lib64)(/|$)' || true)
  if [[ -n $clash ]]; then
    echo "::error::$pkg ships paths under a symlink the filesystem package owns:"
    head -20 <<<"$clash"
    status=1
  fi
  echo "built $pkg ($(du -h "$pkg" | cut -f1) uncompressed)"
done
exit $status
