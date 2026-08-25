#!/usr/bin/env bash
# Build the PICO Linux host inside the container, one stage at a time.
#
#   container-build.sh [sync|trim|compile|package|all]
#
#   sync     repo init/sync governed by the lock; asserts the checkout
#   trim     drop other-host inputs and archive the tree (sources-<key>.tar.zst)
#   compile  rebuild.sh from the synced tree or from SOURCE_ARCHIVE
#   package  deterministic archive of /out/picoemulator
#   all      sync + compile (the default: one RUN step in the Containerfile,
#            so that without a /cache mount the source tree never reaches the
#            committed layer)
#
# Each stage reads its inputs from the environment; see the scripts in this
# directory for the variables. scripts/lib/build-env.sh is shared by all.
set -euo pipefail
here="$(cd "$(dirname "$0")" && pwd)"
stage="${1:-all}"

case "$stage" in
  sync|trim|compile|package)
    exec "$here/build-$stage.sh"
    ;;
  all)
    "$here/build-sync.sh"
    "$here/build-compile.sh"
    # Drop an ephemeral cache only after the output has been produced.
    . "$here/lib/build-env.sh" >/dev/null
    discard_cache_if_ephemeral
    ;;
  *)
    printf 'unknown stage: %s (sync|trim|compile|package|all)\n' "$stage" >&2
    exit 2
    ;;
esac
