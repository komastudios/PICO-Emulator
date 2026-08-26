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

# Guard: the package must contain only what the public sources produce. The
# proprietary guest image and anything from the vendor's Windows/macOS
# packages are mounted at runtime, never shipped, so their signatures are a
# hard failure here rather than a surprise on the registry.
bad="$(cd "$out" && find picoemulator \( -iname '*.img' -o -iname '*.zip' -o -iname '*.apk' \
  -o -iname '*swan*' -o -iname '*oversea*' -o -iname '*win64*' -o -iname 'system-images' \
  -o -iname 'kernel-ranchu' -o -iname 'ramdisk*' -o -iname 'vbmeta*' -o -iname 'super*.img' \) -print)"
if [ -n "$bad" ]; then
  printf 'Build failed: the package contains vendor-image content:\n%s\n' "$bad" >&2
  exit 1
fi
printf 'Package content guard passed.\n'

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
