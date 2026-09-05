#!/usr/bin/env bash
# Apply the reviewed native API overlay to the locked public qemu base.
# Does not silently accept an unrelated source tree or a stale patch marker.
set -euo pipefail
here="$(cd "$(dirname "$0")" && pwd)"
recipe="$(cd "$here/.." && pwd)"
src_root="${1:?source tree root}"
patch="$recipe/patches/pico-native-automation.patch"
lock="$recipe/native/patch.lock"
want="$(sed -n 's/^PATCH_SHA256=//p' "$lock")"
base="$(sed -n 's/^QEMU_BASE=//p' "$lock")"
got="$(sha256sum "$patch" | cut -d' ' -f1)"
[ "$got" = "$want" ] || { echo 'native patch checksum mismatch' >&2; exit 1; }
recorded="$(awk '$1 == "PROJECT" && $2 == "external/qemu" {print $3}' "$src_root/.pico-provenance")"
[ "$recorded" = "$base" ] || { echo 'native patch qemu base mismatch' >&2; exit 1; }
qemu="$src_root/external/qemu"
if git -C "$qemu" apply --check "$patch" 2>/dev/null; then
  git -C "$qemu" apply "$patch"
elif ! git -C "$qemu" apply --reverse --check "$patch" 2>/dev/null; then
  echo 'native patch neither applies cleanly nor matches the current tree' >&2; exit 1
fi
# A source archive deliberately excludes .git; preserve base + overlay identity.
python_bin="$src_root/prebuilts/python/linux-x86/bin/python3"
"$python_bin" - "$src_root/.pico-provenance" "$want" <<'PY'
from pathlib import Path
import sys
p = Path(sys.argv[1])
lines = [line for line in p.read_text().splitlines() if not line.startswith('PATCH pico-native-automation ')]
lines.append('PATCH pico-native-automation ' + sys.argv[2])
p.write_text('\n'.join(lines) + '\n')
PY
printf '%s\n' "$want" > "$src_root/.pico-native-patch"
printf 'Native automation overlay verified: %s\n' "$want"
