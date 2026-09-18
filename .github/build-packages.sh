#!/bin/bash
# Incremental package build for the [maitri] repo.
#
# /work/repo is pre-seeded with the already-published packages (downloaded from the
# "stable" release). Any package whose exact pkgver-pkgrel output is already present
# is skipped, so only changed/new PKGBUILDs recompile.
#
#   FORCE=true       rebuild everything (the workflow skips the cache seed then)
#   LANE=core|heavy  core builds everything except the heavy lane and the dev pair;
#                    heavy builds only the long compiles listed in HEAVY
#   ONLY="a b"       build exactly these packages (workflow_dispatch `packages`)
#   EXCLUDE="a b"    never build these here (the dev pair has its own workflow)
#
# Every package built in this run is listed in /work/built.txt so the workflow
# uploads only new artifacts, never the seeded cache.
set -uo pipefail
FORCE="${FORCE:-${1:-false}}"
LANE="${LANE:-core}"
ONLY="${ONLY:-}"
EXCLUDE="${EXCLUDE:-maitri-dev maitri-settings-dev}"
cd /work/repo
shopt -s nullglob

# Long compiles get their own runner so a full rebuild of the rest never waits
# on a kernel build.
HEAVY="linux-ptl sunshine"
# VCS packages that follow a branch look "uncached" on every run; they only
# build when named explicitly or on a forced rebuild. libfprint-git is not
# one of them: it pins a commit, so its pkgver is stable and it caches like
# any other package. The fingerprint setup installs it from this repo.
ON_DEMAND="libretro-cap32-git libretro-fbneo-git libretro-uae-git libretro-vice-git libretro-database-git retroarch-joypad-autoconfig-git"

in_list() { case " $2 " in *" $1 "*) return 0 ;; esac; return 1; }

selected() {
  local name=$1
  in_list "$name" "$EXCLUDE" && return 1
  if [[ -n $ONLY ]]; then in_list "$name" "$ONLY"; return; fi
  if [[ $LANE == heavy ]]; then in_list "$name" "$HEAVY"; return; fi
  in_list "$name" "$HEAVY" && return 1
  if in_list "$name" "$ON_DEMAND" && [[ $FORCE != true ]]; then return 1; fi
  return 0
}

# Seed the local repo DB from cached packages so dependencies resolve without rebuilds.
cached=(/work/repo/*.pkg.tar.zst)
if (( ${#cached[@]} )); then
  repo-add /work/repo/maitri-local.db.tar.gz "${cached[@]}" >/dev/null 2>&1 || true
else
  repo-add /work/repo/maitri-local.db.tar.gz >/dev/null 2>&1 || true
fi
sudo pacman -Sy

# True if every package this PKGBUILD would produce is already cached.
# Derive the expected names by sourcing the PKGBUILD rather than calling
# `makepkg --packagelist`, which can report the host arch for `any` packages (and
# otherwise misbehave), making 'any' and split packages rebuild every run. We match on
# name-ver-rel and glob the arch field so a published '-any' or '-x86_64' both count.
all_cached() {
  local meta n ver matches
  meta=$(cd "$1" && bash -c '
    source ./PKGBUILD 2>/dev/null || exit 1
    v="${epoch:+$epoch:}${pkgver}-${pkgrel}"
    for n in "${pkgname[@]}"; do printf "%s %s\n" "$n" "$v"; done
  ') || return 1
  [[ -n $meta ]] || return 1
  while read -r n ver; do
    ver=${ver//:/.}   # published assets have the epoch ':' renamed to '.'
    matches=(/work/repo/"$n-$ver"-*.pkg.tar.zst)
    (( ${#matches[@]} )) || return 1
  done <<< "$meta"
  return 0
}

: >/work/built.txt
built=""
skipped=""
for round in 1 2 3 4 5 6; do
  progress=0
  for d in /work/pkgbuilds/*/; do
    name=$(basename "$d")
    case " $built $skipped " in *" $name "*) continue ;; esac
    if ! selected "$name"; then
      skipped="$skipped $name"; continue
    fi
    if [[ $FORCE != true ]] && all_cached "$d"; then
      echo "  cached: $name"; built="$built $name"; progress=1; continue
    fi
    if ( cd "$d" && makepkg -s --noconfirm --noprogressbar --skippgpcheck ) >/tmp/"$name".log 2>&1; then
      cp "$d"/*.pkg.tar.zst /work/repo/ 2>/dev/null || true
      for pkg in "$d"/*.pkg.tar.zst; do basename "$pkg" >>/work/built.txt; done
      repo-add /work/repo/maitri-local.db.tar.gz "$d"/*.pkg.tar.zst >/dev/null 2>&1 || true
      sudo pacman -Sy >/dev/null 2>&1 || true
      built="$built $name"; progress=1; echo "  built: $name"
    fi
  done
  [[ $progress -eq 0 ]] && break
done

echo "=== LANE=$LANE BUILT/CACHED:$built"
echo "=== SKIPPED (other lane / on demand / excluded):$skipped"
failed=0
echo "=== FAILED (last 4 log lines each):"
for d in /work/pkgbuilds/*/; do
  name=$(basename "$d")
  case " $built $skipped " in *" $name "*) continue ;; esac
  failed=1
  echo "--- $name ---"; tail -4 /tmp/"$name".log 2>/dev/null || true
done
exit $failed
