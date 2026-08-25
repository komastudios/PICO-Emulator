#!/usr/bin/env bash
set -euo pipefail

repo_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$repo_dir"

required=(
  README.md MANIFEST.md Taskfile.yml
  docs/build-pipeline.md docs/host-install.md
  patches/README.md
  Containerfile .containerignore
  scripts/container-build.sh scripts/container-entrypoint.sh
  scripts/install-pico-emulator.sh
  patches/pico-emulator-qemu-linux.patch
  patches/pico-emulator-gfxstream-linux.patch
  patches/pico-emulator-gfxstream-yuv-readback.patch
  patches/experimental-swiftshader.patch
  scripts/start-pico-linux.sh scripts/wait-pico-display.sh
  scripts/wait-pico-boot.sh
  systemd/android-adb.service systemd/pico-display.service
  systemd/pico-emulator.service
  config/avd-api36/Pico_36_Linux.avd/config.ini
  config/vulkan/vk_swiftshader_icd.json
  config/vendor-metadata/pico-host-emulatorParams.ini
  config/vendor-metadata/pico-host-source.properties
  config/vendor-metadata/swan-host-source.properties
  config/vendor-metadata/swan-system-image-source.properties
  scripts/write-lock.py
  manifests/pins.xml manifests/pins-debug.xml
  revisions.lock revisions-debug.lock
)
for path in "${required[@]}"; do
  test -f "$path" || { printf 'missing: %s\n' "$path" >&2; exit 1; }
done

bash -n scripts/*.sh
if command -v systemd-analyze >/dev/null; then
  systemd-analyze verify systemd/*.service
fi

# Only files that carry an executable bit may be executable, and only scripts.
while IFS= read -r -d '' path; do
  case "$path" in
    ./scripts/*.sh|./scripts/*.py) ;;
    *) printf 'unexpected executable file: %s\n' "$path" >&2; exit 1 ;;
  esac
done < <(find . -path ./.git -prune -o -type f -perm -u+x -print0)

printf '%s\n' 'repository completeness checks passed'
