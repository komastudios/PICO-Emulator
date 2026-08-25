#!/usr/bin/env bash
# Container entrypoint: bring up a virtual display and ADB, then launch the
# emulator through the same start script the systemd deployment uses.
#
# With no arguments the emulator is started. Any argument is executed instead,
# so `podman run <image> bash` still gives a shell.
set -euo pipefail

package_dir="${PACKAGE:-/opt/android/PICO/linux-pico-package}"
state_root="${PICO_STATE_DIR:-/var/lib/android}"
display="${PICO_DISPLAY:-:99}"
screen="${PICO_SCREEN:-2880x1440x24}"
sysdir="$package_dir/swan_rls_spaceos_oversea_K_pico_emulator_win64_20260731_ide/system-images/system-images"

if [ "$#" -gt 0 ]; then
  exec "$@"
fi

if [ ! -d "$sysdir" ] || [ -z "$(ls -A "$sysdir" 2>/dev/null)" ]; then
  cat >&2 <<EOF
The proprietary API 36 guest image is not present.

This image intentionally ships no vendor blobs. Bind-mount the extracted
system-images directory at exactly:

  $sysdir

That path is absolute because the AVD seed's image.sysdir.1 points at it.
See README.md section 1 for the archive and its SHA-256.
EOF
  exit 1
fi

if [ ! -r /dev/kvm ] || [ ! -w /dev/kvm ]; then
  printf 'Warning: /dev/kvm is not usable; the guest will run in slow software emulation.\n' >&2
  printf 'Pass --device /dev/kvm to podman run for normal speed.\n' >&2
fi

mkdir -p "$state_root/tmp" "$state_root/.android"

cleanup() {
  [ -n "${emulator_pid:-}" ] && kill "$emulator_pid" 2>/dev/null || true
  [ -n "${adb_pid:-}" ] && kill "$adb_pid" 2>/dev/null || true
  [ -n "${xvfb_pid:-}" ] && kill "$xvfb_pid" 2>/dev/null || true
}
trap cleanup EXIT INT TERM

Xvfb "$display" -screen 0 "$screen" -nolisten tcp &
xvfb_pid=$!
export DISPLAY="$display"
"$package_dir/wait-pico-display.sh"

adb -a -L tcp:5037 server nodaemon &
adb_pid=$!

"$package_dir/start-pico-linux.sh" "$@" &
emulator_pid=$!
wait "$emulator_pid"
