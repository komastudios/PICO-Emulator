#!/usr/bin/env bash
set -euo pipefail

package_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
sdk_root="${PICO_SDK_ROOT:-$package_dir/../sdk}"
state_root="${PICO_STATE_DIR:-/var/lib/android}"
avd_root="$state_root/avd"
avd_name="${PICO_AVD_NAME:-Pico_36_Linux}"
avd_target="${PICO_AVD_TARGET:-android-36}"
avd_seed="${PICO_AVD_SEED:-$package_dir/avd-api36}"
gpu_mode="${PICO_GPU_MODE:-angle_indirect}"

if [[ ! -d "$state_root" || ! -w "$state_root" ]]; then
  printf 'PICO state directory must exist and be writable: %s\n' "$state_root" >&2
  exit 1
fi

mkdir -p "$state_root/picoAvdConfig" "$state_root/tmp" "$avd_root"
if [[ ! -f "$avd_root/$avd_name.avd/config.ini" ]]; then
  if [[ ! -f "$avd_seed/$avd_name.avd/config.ini" ]]; then
    printf 'PICO AVD seed is missing: %s\n' "$avd_seed/$avd_name.avd/config.ini" >&2
    exit 1
  fi
  rm -rf "$avd_root/$avd_name.avd"
  rsync -rltS --chmod=Du=rwx,Dgo=rx,Fu=rw,Fgo=r \
    "$avd_seed/" "$avd_root/"
  rm -f "$avd_root/$avd_name.avd/hardware-qemu.ini" \
        "$avd_root/$avd_name.avd/multiinstance.lock"
fi

printf '%s\n' \
  'avd.ini.encoding=UTF-8' \
  "path=$avd_root/$avd_name.avd" \
  "path.rel=avd/$avd_name.avd" \
  "target=$avd_target" >"$avd_root/$avd_name.ini"

export ANDROID_HOME="$sdk_root"
export ANDROID_SDK_ROOT="$sdk_root"
export ANDROID_SDK_HOME="${PICO_CONFIG_HOME:-$state_root}"
export ANDROID_AVD_HOME="$avd_root"
built_emulator="$sdk_root/emulator/emulator"
emulator="${PICO_EMULATOR:-$built_emulator}"

if [[ "${PICO_USE_STOCK_EMULATOR:-0}" == "1" ]]; then
  # The sanitizer shim and PICO GLES search path are host-build-specific.
  # Do not inject either into an upstream Android Emulator process.
  unset LD_PRELOAD LD_LIBRARY_PATH
fi

if [[ ! -x "$emulator" ]]; then
  printf 'PICO emulator binary is not executable: %s\n' "$emulator" >&2
  exit 1
fi

args=(-avd "$avd_name" -no-snapshot -no-boot-anim -writable-system -feature -GLPipeChecksum)

if [[ ! -r /dev/kvm || ! -w /dev/kvm ]]; then
  printf '%s\n' 'Warning: KVM is unavailable to this user; using slow software emulation.' >&2
  printf '%s\n' 'For normal speed, add the user to kvm and log in again: sudo usermod -aG kvm "$USER"' >&2
  args+=(-accel off)
fi

if [[ -z "${DISPLAY:-}" && -z "${WAYLAND_DISPLAY:-}" ]]; then
  printf '%s\n' 'The PICO Linux headless UI currently crashes during window setup.' >&2
  printf '%s\n' 'Run from a desktop session, or set DISPLAY to a usable X display.' >&2
  exit 1
fi

args+=(-no-audio -gpu "$gpu_mode")
if [[ "${PICO_NO_WINDOW:-0}" == "1" ]]; then
  args+=(-no-window)
fi
exec "$emulator" "${args[@]}" "$@"
