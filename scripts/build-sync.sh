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
#   SYNC_GROUPS   optional: repo manifest groups to sync (default: the Linux set)
#   EXCLUDE_FILE  optional: projects to remove from the manifest before syncing
set -euo pipefail
here="$(cd "$(dirname "$0")" && pwd)"
. "$here/lib/build-env.sh"

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

# The manifest groups the other-host prebuilts as notdefault,platform-darwin /
# platform-windows and the Linux ones as notdefault,platform-linux, so this
# selection fetches exactly the hosts the build targets. Everything it leaves
# out is also dropped by scripts/source-trim.txt, so the archive is the same
# tree either way; not downloading it is what makes the sync fit a runner.
sync_groups="${SYNC_GROUPS:-default,platform-linux}"
printf 'Manifest groups: %s\n' "$sync_groups"

cd "$src"
repo init -g "$sync_groups" \
  -u "$MANIFEST_URL" \
  -b "$manifest_rev" \
  -m "$MANIFEST_FILE" \
  --no-clone-bundle "${init_opts[@]}"

mkdir -p .repo/local_manifests
rm -f .repo/local_manifests/pins.xml .repo/local_manifests/exclude.xml
if [ -n "${PINS_FILE:-}" ]; then
  [ -f "$PINS_FILE" ] || { printf 'Build failed: PINS_FILE %s not found.\n' "$PINS_FILE" >&2; exit 1; }
  cp "$PINS_FILE" .repo/local_manifests/pins.xml
  printf 'Applied project pins from %s\n' "$PINS_FILE"
fi

# Projects with no manifest group that the trim drops anyway; removing them
# here keeps them off the disk entirely. Recorded as name/path pairs so the
# directory each one would have left behind can be recreated below.
exclude_file="${EXCLUDE_FILE:-$here/source-exclude.txt}"
excluded_paths=()
if [ -f "$exclude_file" ]; then
  {
    printf '<?xml version="1.0" encoding="UTF-8"?>\n<manifest>\n'
    while read -r name path; do
      case "$name" in ''|'#'*) continue ;; esac
      [ -n "$path" ] || { printf 'Build failed: %s: no path for %s\n' "$exclude_file" "$name" >&2; exit 1; }
      printf '  <remove-project name="%s" />\n' "$name"
      excluded_paths+=("$path")
    done < "$exclude_file"
    printf '</manifest>\n'
  } > .repo/local_manifests/exclude.xml
  printf 'Excluded %s projects from the manifest (%s)\n' "${#excluded_paths[@]}" "$exclude_file"
fi

# Remove only our exact prior overlay before repo sync; unrelated edits remain
# visible to repo and are never reset here. Archives have no .git and use compile.
if [ -f "$src/.pico-native-patch" ]; then
  patch="$here/../patches/pico-native-automation.patch"
  old="$(cat "$src/.pico-native-patch")"
  now="$(sha256sum "$patch" | cut -d' ' -f1)"
  [ "$old" = "$now" ] || { echo 'Native overlay changed; use a fresh sync cache.' >&2; exit 1; }
  git -C external/qemu apply --reverse --check "$patch"
  git -C external/qemu apply --reverse "$patch"
  rm "$src/.pico-native-patch"
fi
repo sync -c -d -j"$JOBS" --force-sync --no-clone-bundle
repo forall -c 'git lfs pull'

# An excluded project leaves no directory behind, but the trim, which only
# deletes the project itself, leaves its parent. Recreate that parent so the
# archive is byte-for-byte what a full sync followed by the trim produces.
for path in ${excluded_paths+"${excluded_paths[@]}"}; do
  mkdir -p "$(dirname "$path")"
done

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
