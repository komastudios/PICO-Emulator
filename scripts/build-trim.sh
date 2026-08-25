#!/usr/bin/env bash
# Stage "trim": reduce the synced tree to the Linux x86_64 build inputs and
# archive it deterministically.
#
# Inputs (environment):
#   SOURCE_DATE_EPOCH  mtime of every archive member
#   LOCK_KEY           names the archive: $cache/sources-<LOCK_KEY>.tar.zst
#   TRIM_FILE          drop rules (default: /opt/pico/scripts/source-trim.txt)
#   REQUIRED_FILE      post-trim assertions (default: .../source-required.txt)
#   ZSTD_LEVEL         compression level (default 12)
# Output:
#   $cache/sources-<LOCK_KEY>.tar.zst, .tar.sha256 (uncompressed content id),
#   .list (every archived file with its size)
set -euo pipefail
. "$(dirname "$0")/lib/build-env.sh"

here="$(cd "$(dirname "$0")" && pwd)"
trim_file="${TRIM_FILE:-$here/source-trim.txt}"
required_file="${REQUIRED_FILE:-$here/source-required.txt}"
: "${SOURCE_DATE_EPOCH:?trim needs SOURCE_DATE_EPOCH for deterministic mtimes}"
key="${lock_key:-unkeyed}"

cd "$src"
[ -f .pico-provenance ] || { printf 'Build failed: %s is not a synced tree (no .pico-provenance).\n' "$src" >&2; exit 1; }

# --- drop ------------------------------------------------------------------
before="$(du -sk --apparent-size . | cut -f1)"
dropped=0
while read -r pattern; do
  case "$pattern" in ''|'#'*) continue ;; esac
  # shellcheck disable=SC2086
  for p in $pattern; do
    [ -e "$p" ] || [ -L "$p" ] || continue
    rm -rf -- "$p"
    dropped=$((dropped + 1))
  done
done < "$trim_file"
# Every project's .git is a link into .repo (already gone); remove the stubs.
find . -name .git \( -type l -o -type d -o -type f \) -prune -exec rm -rf -- {} + 2>/dev/null || true
after="$(du -sk --apparent-size . | cut -f1)"
printf 'Trimmed %s paths: %s MB -> %s MB\n' "$dropped" "$((before / 1024))" "$((after / 1024))"

# --- assert ----------------------------------------------------------------
rc=0
while read -r p; do
  case "$p" in ''|'#'*) continue ;; esac
  if [ ! -e "$p" ]; then printf 'missing after trim: %s\n' "$p" >&2; rc=1; fi
done < "$required_file"
[ "$rc" -eq 0 ] || { printf 'Build failed: the trimmed tree lacks required inputs.\n' >&2; exit 1; }
printf 'Required inputs present.\n'
# The trim rules are part of the archive's identity, so the key is (re)written
# here, after the sync stage's provisional value.
printf '%s\n' "$key" > .pico-lock-key

# --- archive ---------------------------------------------------------------
# Deterministic: sorted members, fixed owner and mtime, no atime/ctime headers.
# The sha256 of the *uncompressed* stream is the archive's identity; zstd
# output can differ between zstd versions.
archive="$cache/sources-$key.tar.zst"
cd "$cache"
find src -type f -o -type l | LC_ALL=C sort | while read -r f; do
  printf '%s %s\n' "$(stat -c %s "$f" 2>/dev/null || echo 0)" "$f"
done > "$archive.list.tmp"
tar --format=posix --sort=name --numeric-owner --owner=0 --group=0 \
    --mtime="@$SOURCE_DATE_EPOCH" \
    --pax-option=exthdr.name=%d/PaxHeaders/%f,delete=atime,delete=ctime \
    -cf - src \
  | tee >(sha256sum | cut -d' ' -f1 > "$archive.sha256.tmp") \
  | zstd -q -T0 "-${ZSTD_LEVEL:-12}" --long=27 -o "$archive.tmp" -f
mv "$archive.tmp" "$archive"
mv "$archive.sha256.tmp" "${archive%.zst}.sha256"
mv "$archive.list.tmp" "$archive.list"
printf 'Source archive %s (%s), content sha256 %s\n' "$archive" \
  "$(du -h "$archive" | cut -f1)" "$(cat "${archive%.zst}.sha256")"
