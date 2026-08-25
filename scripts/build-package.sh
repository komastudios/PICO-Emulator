#!/usr/bin/env bash
# Stage "package": archive /out/picoemulator deterministically so the compile
# stage's result can be promoted as a plain file.
#
# Inputs (environment):
#   SOURCE_DATE_EPOCH  mtime of every archive member
#   LOCK_KEY           optional; recorded in the archive name when set
# Output:
#   /out/picoemulator[-<LOCK_KEY>].tar.zst and .tar.sha256 (uncompressed content id)
set -euo pipefail
. "$(dirname "$0")/lib/build-env.sh"

: "${SOURCE_DATE_EPOCH:?package needs SOURCE_DATE_EPOCH for deterministic mtimes}"
[ -d "$out/picoemulator" ] || { printf 'Build failed: %s/picoemulator missing; run the compile stage.\n' "$out" >&2; exit 1; }

name="picoemulator${lock_key:+-$lock_key}"
cd "$out"
tar --format=posix --sort=name --numeric-owner --owner=0 --group=0 \
    --mtime="@$SOURCE_DATE_EPOCH" \
    --pax-option=exthdr.name=%d/PaxHeaders/%f,delete=atime,delete=ctime \
    -cf - picoemulator \
  | tee >(sha256sum | cut -d' ' -f1 > "$name.tar.sha256") \
  | zstd -q -T0 -12 -o "$name.tar.zst" -f
printf 'Package archive %s (%s), content sha256 %s\n' "$out/$name.tar.zst" \
  "$(du -h "$name.tar.zst" | cut -f1)" "$(cat "$name.tar.sha256")"
