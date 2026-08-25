#!/usr/bin/env bash
set -euo pipefail

adb=/opt/android/PICO/sdk/platform-tools/adb
serial="${PICO_SERIAL:-emulator-5554}"
timeout="${PICO_BOOT_TIMEOUT:-180}"

for ((elapsed = 0; elapsed < timeout; elapsed++)); do
  if [[ "$($adb -s "$serial" get-state 2>/dev/null || true)" == device ]] &&
     [[ "$($adb -s "$serial" shell getprop sys.boot_completed 2>/dev/null | tr -d '\r' || true)" == 1 ]]; then
    # The Swan/SpaceOS guest defaults its proximity sensor to "far". Keep the
    # virtual headset worn and awake so the spatial runtime is allowed to run.
    $adb -s "$serial" shell svc power stayon true
    $adb -s "$serial" shell input keyevent KEYCODE_WAKEUP
    HOME=/var/lib/android $adb -s "$serial" emu sensor set proximity 0
    printf 'PICO emulator %s completed boot after %d seconds\n' "$serial" "$elapsed"
    exit 0
  fi
  sleep 1
done

printf 'Timed out after %s seconds waiting for %s to boot\n' "$timeout" "$serial" >&2
$adb devices -l >&2 || true
exit 1
