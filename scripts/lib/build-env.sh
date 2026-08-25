#!/usr/bin/env bash
# Shared environment for the container build stages. Sourced, not executed.
#
# Normalizes the sources of nondeterminism the build can control and locates
# the build cache. Sets: cache, persist, src, out.

# Fixed timestamp, locale, timezone, umask and Python hash seed, so nothing in
# the distribution tree depends on when or where the build ran.
umask 022
export TZ=UTC LC_ALL=C
export PYTHONHASHSEED=0
if [ -n "${SOURCE_DATE_EPOCH:-}" ]; then
  export SOURCE_DATE_EPOCH
  printf 'SOURCE_DATE_EPOCH=%s (%s)\n' "$SOURCE_DATE_EPOCH" \
    "$(TZ=UTC date -u -d "@$SOURCE_DATE_EPOCH" '+%Y-%m-%dT%H:%M:%SZ' 2>/dev/null || echo unknown)"
else
  printf 'SOURCE_DATE_EPOCH is unset; embedded timestamps will vary between builds.\n' >&2
fi

JOBS="${JOBS:-$(nproc)}"

if mountpoint -q /cache 2>/dev/null; then
  cache=/cache
  persist=1
  printf 'Using persistent build cache at %s\n' "$cache"
else
  cache=/tmp/pico-cache
  persist=0
  printf 'No /cache mount; building in %s and discarding it afterwards.\n' "$cache"
fi

# The source tree must live at exactly this path: it is embedded in objects
# and debug info, so a promoted source archive is only valid here.
src="$cache/src"
out=/out
mkdir -p "$src" "$out"

# The key naming the promoted source archive: content hash of the lock, pins
# and trim rules. Optional; the Taskfile passes it (task lock:key).
lock_key="${LOCK_KEY:-}"

discard_cache_if_ephemeral() {
  if [ "${persist:-0}" -eq 0 ]; then
    rm -rf "$cache"
  fi
}
