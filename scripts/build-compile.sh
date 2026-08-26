#!/usr/bin/env bash
# Stage "compile": build the Linux host from $src and emit the distribution
# tree to /out/picoemulator.
#
# Inputs (environment):
#   JOBS
#   SOURCE_ARCHIVE    optional: a promoted source archive (from the trim stage)
#                     to unpack into $src instead of using a synced tree
#   DISCARD_SOURCE_ARCHIVE  optional: 1 = delete SOURCE_ARCHIVE once unpacked
#   LOCK_KEY          optional: must match the key recorded in the tree
#   SOURCE_DATE_EPOCH optional: fixed build timestamp, from the locked commit
#   COMPILER_CACHE    "none" (default), "auto", or a path to sccache/ccache
set -euo pipefail
. "$(dirname "$0")/lib/build-env.sh"

# --- source ----------------------------------------------------------------
if [ -n "${SOURCE_ARCHIVE:-}" ]; then
  [ -f "$SOURCE_ARCHIVE" ] || { printf 'Build failed: SOURCE_ARCHIVE %s not found.\n' "$SOURCE_ARCHIVE" >&2; exit 1; }
  have="$(cat "$src/.pico-lock-key" 2>/dev/null || true)"
  if [ -n "$lock_key" ] && [ "$have" = "$lock_key" ] && [ -f "$src/.pico-provenance" ]; then
    printf 'Source tree already unpacked for key %s; reusing it.\n' "$lock_key"
  else
    printf 'Unpacking %s into %s\n' "$SOURCE_ARCHIVE" "$src"
    rm -rf "$src"
    zstd -dc --long=27 "$SOURCE_ARCHIVE" | tar -C "$cache" -xf -
    have="$(cat "$src/.pico-lock-key" 2>/dev/null || true)"
    if [ -n "$lock_key" ] && [ "$have" != "$lock_key" ]; then
      printf 'Build failed: archive was made for key %s, expected %s.\n' "${have:-none}" "$lock_key" >&2
      exit 1
    fi
    # The build writes ~37 GB of objects next to the 18 GB source tree, which
    # on a hosted runner leaves no room for the archive it came from.
    if [ "${DISCARD_SOURCE_ARCHIVE:-0}" = 1 ]; then
      rm -f "$SOURCE_ARCHIVE"
      printf 'Removed %s; the unpacked tree is the input from here on.\n' "$SOURCE_ARCHIVE"
    fi
  fi
fi
[ -f "$src/.pico-provenance" ] || [ -d "$src/.repo" ] || {
  printf 'Build failed: no source tree at %s (run the sync stage or pass SOURCE_ARCHIVE).\n' "$src" >&2
  exit 1
}
if [ -f "$src/.pico-provenance" ]; then
  grep -E '^PROJECT (external/qemu|hardware/google/gfxstream) ' "$src/.pico-provenance" || true
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

# rebuild.sh has no build-jobs flag (--test_jobs only drives CTest, which is
# disabled here); cmake --build honours this variable, so JOBS reaches ninja.
export CMAKE_BUILD_PARALLEL_LEVEL="$JOBS"

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
rm -rf "$out/picoemulator"
cp -a "$dist" "$out/picoemulator"

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
mkdir -p "$out/picoemulator/lib64/gles_angle_pico_linux"
cp -a "$angle_prebuilt/." "$out/picoemulator/lib64/gles_angle_pico_linux/"
printf 'Added lib64/gles_angle_pico_linux from the ANGLE prebuilt (%s files).\n' \
  "$(find "$out/picoemulator/lib64/gles_angle_pico_linux" -type f | wc -l)"

# Provenance travels with the output.
[ -f "$src/.pico-provenance" ] && cp "$src/.pico-provenance" "$out/picoemulator/.pico-provenance"
