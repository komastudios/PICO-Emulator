#!/usr/bin/env bash
# Stage "sync": check the locked PICO manifest out into $src.
#
# Inputs (environment):
#   MANIFEST_URL, MANIFEST_BRANCH, MANIFEST_FILE, JOBS
#   MANIFEST_REV  optional: manifest commit to pin instead of MANIFEST_BRANCH
#   PINS_FILE     optional: repo local manifest pinning otherwise-floating projects
#   LOCK_FILE     optional: lock to assert the synced checkout against
#   LOCK_KEY      optional: recorded in the tree as .pico-lock-key
#   SYNC_DEPTH    optional: shallow history depth for every project (e.g. 1)
#   SYNC_PARTIAL  optional: 1 = partial clone (blob:none) to shrink .repo
set -euo pipefail
. "$(dirname "$0")/lib/build-env.sh"

: "${MANIFEST_URL:?}"
: "${MANIFEST_BRANCH:?}"
: "${MANIFEST_FILE:?}"

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

init_opts=()
if [ -n "${SYNC_DEPTH:-}" ]; then
  init_opts+=(--depth="$SYNC_DEPTH")
  printf 'Shallow sync: depth %s\n' "$SYNC_DEPTH"
fi
if [ "${SYNC_PARTIAL:-0}" = 1 ]; then
  init_opts+=(--partial-clone --clone-filter=blob:none)
  printf 'Partial clone: blob:none\n'
fi

cd "$src"
repo init -g all \
  -u "$MANIFEST_URL" \
  -b "$manifest_rev" \
  -m "$MANIFEST_FILE" \
  --no-clone-bundle "${init_opts[@]}"

rm -f .repo/local_manifests/pins.xml
if [ -n "${PINS_FILE:-}" ]; then
  [ -f "$PINS_FILE" ] || { printf 'Build failed: PINS_FILE %s not found.\n' "$PINS_FILE" >&2; exit 1; }
  mkdir -p .repo/local_manifests
  cp "$PINS_FILE" .repo/local_manifests/pins.xml
  printf 'Applied project pins from %s\n' "$PINS_FILE"
fi

repo sync -c -d -j"$JOBS" --force-sync --no-clone-bundle
repo forall -c 'git lfs pull'

# The manifest pins both forks to explicit commits; prove we got them, and
# record every project HEAD so the compile stage can report them even after
# the git metadata has been trimmed away.
printf 'external/qemu            %s\n' "$(git -C external/qemu rev-parse HEAD)"
printf 'hardware/google/gfxstream %s\n' "$(git -C hardware/google/gfxstream rev-parse HEAD)"
{
  printf 'MANIFEST_URL=%s\nMANIFEST_REV=%s\nMANIFEST_FILE=%s\n' "$MANIFEST_URL" "$manifest_rev" "$MANIFEST_FILE"
  repo forall -c 'printf "PROJECT %s %s\n" "$REPO_PATH" "$(git rev-parse HEAD)"' | LC_ALL=C sort
} > .pico-provenance
printf '%s\n' "$lock_key" > .pico-lock-key

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
