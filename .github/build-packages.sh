#!/bin/bash
# Incremental package build for the [maitri] repo.
#
# /work/repo is pre-seeded with the already-published packages (downloaded from the
# "stable" release). Any package whose exact pkgver-pkgrel output is already present
# is skipped, so only changed/new PKGBUILDs recompile. Pass "true" as $1 to force a
# full rebuild (the seed step is skipped by the workflow in that case).
set -uo pipefail
FORCE="${1:-false}"
cd /work/repo
shopt -s nullglob

# Seed the local repo DB from cached packages so dependencies resolve without rebuilds.
cached=(/work/repo/*.pkg.tar.zst)
if (( ${#cached[@]} )); then
  repo-add /work/repo/maitri-local.db.tar.gz "${cached[@]}" >/dev/null 2>&1 || true
else
  repo-add /work/repo/maitri-local.db.tar.gz >/dev/null 2>&1 || true
fi
sudo pacman -Sy

# True if every package this PKGBUILD would produce is already cached.
all_cached() {
  local out f
  out=$(cd "$1" && makepkg --packagelist 2>/dev/null) || return 1
  [[ -n $out ]] || return 1
  while IFS= read -r p; do
    f=$(basename "$p" | sed 's/:/./g')   # published assets have the epoch ':' renamed to '.'
    [[ -e /work/repo/$f ]] || return 1
  done <<< "$out"
  return 0
}

built=""
for round in 1 2 3 4 5 6; do
  progress=0
  for d in /work/pkgbuilds/*/; do
    name=$(basename "$d")
    case " $built " in *" $name "*) continue ;; esac
    if [[ $FORCE != true ]] && all_cached "$d"; then
      echo "  cached: $name"; built="$built $name"; progress=1; continue
    fi
    if ( cd "$d" && makepkg -s --noconfirm --noprogressbar --skippgpcheck ) >/tmp/"$name".log 2>&1; then
      cp "$d"/*.pkg.tar.zst /work/repo/ 2>/dev/null || true
      repo-add /work/repo/maitri-local.db.tar.gz "$d"/*.pkg.tar.zst >/dev/null 2>&1 || true
      sudo pacman -Sy >/dev/null 2>&1 || true
      built="$built $name"; progress=1; echo "  built: $name"
    fi
  done
  [[ $progress -eq 0 ]] && break
done

echo "=== BUILT/CACHED:$built"
echo "=== FAILED (last 4 log lines each):"
for d in /work/pkgbuilds/*/; do
  name=$(basename "$d")
  case " $built " in *" $name "*) continue ;; esac
  echo "--- $name ---"; tail -4 /tmp/"$name".log 2>/dev/null || true
done
