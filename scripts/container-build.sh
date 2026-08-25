#!/usr/bin/env bash
# Sync the PICO manifest and build the Linux host inside the container.
#
# Runs as a single RUN step so that, when no /cache bind mount is present,
# the multi-gigabyte source tree never reaches the committed layer.
#
# Inputs (environment):
#   MANIFEST_URL, MANIFEST_BRANCH, MANIFEST_FILE, JOBS
#   MANIFEST_REV  optional: manifest commit to pin instead of MANIFEST_BRANCH
#   PINS_FILE     optional: repo local manifest pinning otherwise-floating projects
#   LOCK_FILE     optional: lock to assert the synced checkout against
#   SOURCE_DATE_EPOCH optional: fixed build timestamp, from the locked commit
#   COMPILER_CACHE    "none" (default), "auto", or a path to sccache/ccache
# Output:
#   /out/picoemulator — the distribution tree consumed by the deploy stage
set -euo pipefail

: "${MANIFEST_URL:?}"
: "${MANIFEST_BRANCH:?}"
: "${MANIFEST_FILE:?}"
JOBS="${JOBS:-$(nproc)}"

# Normalize the sources of nondeterminism this build can control: a fixed
# timestamp, a fixed locale and timezone, and a fixed umask so file modes in
# the distribution tree do not depend on the invoking environment.
umask 022
export TZ=UTC LC_ALL=C
# Fixed hash seed: build-system Python (e.g. the NOTICE generator) iterates
# sets, whose order otherwise changes with every process.
export PYTHONHASHSEED=0
if [ -n "${SOURCE_DATE_EPOCH:-}" ]; then
  export SOURCE_DATE_EPOCH
  printf 'SOURCE_DATE_EPOCH=%s (%s)\n' "$SOURCE_DATE_EPOCH" \
    "$(TZ=UTC date -u -d "@$SOURCE_DATE_EPOCH" '+%Y-%m-%dT%H:%M:%SZ' 2>/dev/null || echo unknown)"
else
  printf 'SOURCE_DATE_EPOCH is unset; embedded timestamps will vary between builds.\n' >&2
fi

if mountpoint -q /cache 2>/dev/null; then
  cache=/cache
  persist=1
  printf 'Using persistent build cache at %s\n' "$cache"
else
  cache=/tmp/pico-cache
  persist=0
  printf 'No /cache mount; building in %s and discarding it afterwards.\n' "$cache"
fi

src="$cache/src"
mkdir -p "$src" /out

# --- sync ------------------------------------------------------------------
# With a lock (MANIFEST_REV + PINS_FILE, produced by scripts/write-lock.py) the
# sync is reproducible: the manifest is checked out at a commit rather than a
# branch tip, and PINS_FILE pins the projects the manifest leaves on a branch.
# Without one the branch tip is used, which is whatever it points at today.
manifest_rev="${MANIFEST_REV:-}"
if [ -n "$manifest_rev" ]; then
  printf 'Manifest pinned to %s (locked)\n' "$manifest_rev"
else
  manifest_rev="$MANIFEST_BRANCH"
  printf 'Manifest following branch %s (unlocked)\n' "$manifest_rev"
fi

cd "$src"
repo init -g all \
  -u "$MANIFEST_URL" \
  -b "$manifest_rev" \
  -m "$MANIFEST_FILE" \
  --no-clone-bundle

rm -f .repo/local_manifests/pins.xml
if [ -n "${PINS_FILE:-}" ]; then
  [ -f "$PINS_FILE" ] || { printf 'Build failed: PINS_FILE %s not found.\n' "$PINS_FILE" >&2; exit 1; }
  mkdir -p .repo/local_manifests
  cp "$PINS_FILE" .repo/local_manifests/pins.xml
  printf 'Applied project pins from %s\n' "$PINS_FILE"
fi

repo sync -c -d -j"$JOBS" --force-sync --no-clone-bundle
repo forall -c 'git lfs pull'

# The manifest pins both forks to explicit commits; prove we got them.
printf 'external/qemu            %s\n' "$(git -C external/qemu rev-parse HEAD)"
printf 'hardware/google/gfxstream %s\n' "$(git -C hardware/google/gfxstream rev-parse HEAD)"

# With a lock, assert every recorded project commit actually got checked out.
if [ -n "${LOCK_FILE:-}" ] && [ -f "$LOCK_FILE" ]; then
  rc_lock=0
  while read -r kw path want; do
    [ "$kw" = "PROJECT" ] || continue
    got="$(git -C "$path" rev-parse HEAD 2>/dev/null || echo missing)"
    if [ "$got" != "$want" ]; then
      printf 'lock mismatch: %s is %s, lock says %s\n' "$path" "$got" "$want" >&2
      rc_lock=1
    fi
  done < "$LOCK_FILE"
  [ "$rc_lock" -eq 0 ] || { printf 'Build failed: the checkout does not match %s.\n' "$LOCK_FILE" >&2; exit 1; }
  printf 'Checkout matches %s\n' "$LOCK_FILE"
fi

# --- build -----------------------------------------------------------------
# The emulator's CMakeLists sets RULE_LAUNCH_COMPILE from OPTION_CCACHE, so a
# compiler cache fronts *every* compile when one is found. rebuild.sh asks for
# "auto"; our flag comes later on the command line and wins.
#
# Default off: a cache hit replays a stored object instead of compiling, which
# would mask a reproducibility difference rather than prove its absence, and
# the bundled sccache 0.3.0 fails the build outright when its server is slow to
# start. Set COMPILER_CACHE=auto for a fast development build.
compiler_cache="${COMPILER_CACHE:-none}"
if [ "$compiler_cache" != "none" ]; then
  # Keep the cache in the persisted mount; the container's HOME is discarded.
  export SCCACHE_DIR="${SCCACHE_DIR:-$cache/sccache}"
  mkdir -p "$SCCACHE_DIR"
  printf 'Compiler cache: %s (SCCACHE_DIR=%s)\n' "$compiler_cache" "$SCCACHE_DIR"
else
  printf 'Compiler cache: disabled\n'
fi

cd "$src/external/qemu"
rc=0
./android/rebuild.sh \
  --target linux-x86_64 \
  --test_jobs "$JOBS" \
  --ccache "$compiler_cache" \
  --task-disable Clean \
  --task-disable CTest || rc=$?

dist="$src/external/qemu/objs/distribution/picoemulator"

# rebuild.sh is known to fail its final acceleration check on a CPU-only host
# (emulator-check cannot load libnvidia-ml.so.1) *after* the distribution has
# already been produced. Tolerate that specific outcome only, by requiring a
# complete tree; any other failure is fatal.
if [ "$rc" -ne 0 ]; then
  printf 'rebuild.sh exited %d; verifying the distribution is complete.\n' "$rc" >&2
  for required in \
      "$dist/emulator" \
      "$dist/qemu/linux-x86_64/qemu-system-x86_64" \
      "$dist/lib64/libgfxstream_backend.so"; do
    if [ ! -s "$required" ]; then
      printf 'Build failed: %s is missing.\n' "$required" >&2
      exit "$rc"
    fi
  done
  printf 'Distribution is complete; treating the exit status as the known NVML check.\n' >&2
fi

test -x "$dist/emulator"
cp -a "$dist" /out/picoemulator

# The build does not emit lib64/gles_angle_pico_linux, but pico-emulator.service
# puts exactly that directory on LD_LIBRARY_PATH and PICO_GPU_MODE=angle_indirect
# needs the ANGLE GLES libraries in it. It is a verbatim copy of the ANGLE
# prebuilt shipped in PICO-Emulator-common (verified byte-identical to the
# working deployment for libEGL, libGLESv2, libGLESv1_CM, libangle_st and
# libshadertranslator). Without it a container-built package cannot render.
angle_prebuilt="$src/prebuilts/android-emulator-build/common/ANGLE/linux-x86_64/lib"
if [ ! -f "$angle_prebuilt/libangle_st.so" ]; then
  printf 'Build failed: ANGLE prebuilt not found at %s\n' "$angle_prebuilt" >&2
  printf 'It ships in PICO-Emulator-common; check that git lfs pull succeeded.\n' >&2
  exit 1
fi
mkdir -p /out/picoemulator/lib64/gles_angle_pico_linux
cp -a "$angle_prebuilt/." /out/picoemulator/lib64/gles_angle_pico_linux/
printf 'Added lib64/gles_angle_pico_linux from the ANGLE prebuilt (%s files).\n' \
  "$(find /out/picoemulator/lib64/gles_angle_pico_linux -type f | wc -l)"

if [ "$persist" -eq 0 ]; then
  rm -rf "$cache"
fi
