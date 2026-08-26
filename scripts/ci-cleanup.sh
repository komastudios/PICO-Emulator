#!/usr/bin/env bash
# Free disk on a GitHub-hosted runner and place the build cache and container
# storage on the filesystems with the most room. No-op outside GitHub Actions.
#
# A hosted runner has two disks: the root volume (~25 GB free, ~50 GB once the
# preinstalled toolchains are gone) and the temp volume at /mnt (~65 GB free).
# The compile stage needs ~55 GB on CACHE_DIR (18 GB source tree plus 37 GB of
# build output), so CACHE_DIR takes the larger disk and container storage goes
# on the other one rather than competing for the same space.
#
# Prints CACHE_DIR=<path> and GRAPHROOT=<path> on stdout (the workflow captures
# them as step outputs); everything else goes to stderr. Fails if the cache
# filesystem has less than MIN_FREE_GB free.
set -euo pipefail
[ -n "${GITHUB_ACTIONS:-}" ] || { printf 'not on GitHub Actions; nothing to do\n'; exit 0; }
min_free="${MIN_FREE_GB:-45}"

# Preinstalled toolchains this build never uses (~30-40 GB).
for d in /usr/share/dotnet /usr/local/lib/android /opt/ghc /opt/hostedtoolcache/CodeQL \
         /usr/local/.ghcup /usr/share/swift /usr/local/share/boost /usr/lib/jvm \
         /usr/local/share/powershell /usr/local/lib/node_modules /opt/az /usr/share/miniconda; do
  [ -e "$d" ] && sudo rm -rf "$d"
done
sudo docker system prune -af >/dev/null 2>&1 || true
sudo apt-get clean >/dev/null 2>&1 || true

free_gb() { df -BG --output=avail "$1" | tail -1 | tr -dc '0-9'; }
device()  { df --output=source "$1" | tail -1; }

# Rank the candidate mounts by free space, one entry per underlying device.
ranked=""; seen=""
for m in / /mnt "${RUNNER_TEMP:-/tmp}"; do
  [ -d "$m" ] || continue
  dev="$(device "$m")"
  case " $seen " in *" $dev "*) continue ;; esac
  seen="$seen $dev"
  ranked="$ranked$(free_gb "$m") $m"$'\n'
done
ranked="$(printf '%s' "$ranked" | sort -rn)"
df -h / /mnt 2>/dev/null >&2 || true
printf 'candidate filesystems (GB free):\n%s\n' "$ranked" >&2

cache_free="$(printf '%s\n' "$ranked" | sed -n 1p | cut -d' ' -f1)"
cache_mount="$(printf '%s\n' "$ranked" | sed -n 1p | cut -d' ' -f2-)"
graph_mount="$(printf '%s\n' "$ranked" | sed -n 2p | cut -d' ' -f2-)"
# Container storage only needs room for the toolchain image; keep it off the
# cache disk when there is a second one, but not on a disk that is nearly full.
graph_free="$(printf '%s\n' "$ranked" | sed -n 2p | cut -d' ' -f1)"
if [ -z "$graph_mount" ] || [ "${graph_free:-0}" -lt 10 ]; then graph_mount="$cache_mount"; fi

if [ "${cache_free:-0}" -lt "$min_free" ]; then
  printf 'only %s GB free on %s; need %s GB\n' "$cache_free" "$cache_mount" "$min_free" >&2; exit 1
fi
cache="${cache_mount%/}/pico-cache"; graph="${graph_mount%/}/pico-containers"
sudo mkdir -p "$cache" "$graph"; sudo chown "$(id -u):$(id -g)" "$cache"
printf 'cache on %s (%s GB free), container storage on %s (%s GB free)\n' \
  "$cache_mount" "$cache_free" "$graph_mount" "${graph_free:-$cache_free}" >&2
printf 'CACHE_DIR=%s\nGRAPHROOT=%s\n' "$cache" "$graph"
