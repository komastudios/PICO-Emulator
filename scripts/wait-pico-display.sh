#!/usr/bin/env bash
set -euo pipefail

display="${DISPLAY:-:99}"
for ((attempt = 0; attempt < 15; attempt++)); do
  if /usr/bin/xdpyinfo -display "$display" >/dev/null 2>&1; then
    exit 0
  fi
  sleep 1
done

printf 'X display %s did not become ready\n' "$display" >&2
exit 1
