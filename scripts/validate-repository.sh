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
  scripts/write-lock.py scripts/repro-check.sh
  scripts/build-sync.sh scripts/build-trim.sh scripts/build-compile.sh
  scripts/build-package.sh scripts/lib/build-env.sh
  scripts/source-trim.txt scripts/source-required.txt
  scripts/promote.sh scripts/ci-cleanup.sh
  .github/workflows/ci.yml .github/workflows/build.yml
  .github/actions/setup-tools/action.yml
  manifests/pins.xml manifests/pins-debug.xml
  revisions.lock revisions-debug.lock
)
for path in "${required[@]}"; do
  test -f "$path" || { printf 'missing: %s\n' "$path" >&2; exit 1; }
done

bash -n scripts/*.sh scripts/lib/*.sh
python3 -m py_compile scripts/write-lock.py
rm -rf scripts/__pycache__
if command -v actionlint >/dev/null; then
  actionlint
fi
if command -v systemd-analyze >/dev/null; then
  systemd-analyze verify systemd/*.service
fi

# Only scripts may carry an executable bit. Checked against what git tracks,
# so build output under dist/ and a local .cache/ are out of scope.
if git rev-parse --git-dir >/dev/null 2>&1; then
  while IFS= read -r mode _ _ path; do
    [ "$mode" = 100755 ] || continue
    case "$path" in
      scripts/*.sh|scripts/*.py) ;;
      *) printf 'unexpected executable file: %s\n' "$path" >&2; exit 1 ;;
    esac
  done < <(git ls-files -s)
else
  printf 'not a git checkout; skipping the file mode check\n' >&2
fi

printf '%s\n' 'repository completeness checks passed'
