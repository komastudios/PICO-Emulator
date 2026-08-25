#!/usr/bin/env bash
# Free disk on a GitHub-hosted runner and pick the largest filesystem for the
# build cache and container storage. No-op outside GitHub Actions.
#
# Prints CACHE_DIR=<path> and GRAPHROOT=<path> on stdout (the workflow
# captures them); fails if less than MIN_FREE_GB remains.
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

# Choose the mount with the most free space.
best=/; best_free=0
for m in / /mnt "${RUNNER_TEMP:-/tmp}"; do
  [ -d "$m" ] || continue
  free="$(df -BG --output=avail "$m" | tail -1 | tr -dc '0-9')"
  if [ "${free:-0}" -gt "$best_free" ]; then best="$m"; best_free="$free"; fi
done
df -h / /mnt 2>/dev/null >&2 || true
printf 'largest filesystem: %s (%s GB free)\n' "$best" "$best_free" >&2
if [ "$best_free" -lt "$min_free" ]; then
  printf 'only %s GB free; need %s GB\n' "$best_free" "$min_free" >&2; exit 1
fi
cache="$best/pico-cache"; graph="$best/pico-containers"
sudo mkdir -p "$cache" "$graph"; sudo chown "$(id -u):$(id -g)" "$cache"
printf 'CACHE_DIR=%s\nGRAPHROOT=%s\n' "$cache" "$graph"
