#!/usr/bin/env bash
# Assemble a self-contained release archive from an extracted package.
#
#   scripts/make-release.sh --package DIR --out DIR [--version V] [--lock-key K]
#
# The archive needs nothing but tar, zstd and a shell to install:
#
#   pico-emulator-linux-<version>/
#     linux-pico-package/     the package (picoemulator/, avd-api36/, start scripts, SHA256SUMS)
#     scripts/install-pico-emulator.sh
#     systemd/*.service
#     README.md               how to install and verify
#     RELEASE                 provenance: version, commit, lock, manifest, keys
#     SHA256SUMS              over every file in the archive
#
# Version: v0.<N> where N counts the commits reachable from HEAD, the way ANGLE
# and Chromium derive build numbers, so it is monotonic on a branch and needs
# no state outside git. --version overrides it.
set -euo pipefail
export LC_ALL=C

package=""; out=""; version=""; lock_key=""
while [ $# -gt 0 ]; do
  case "$1" in
    --package)  package="${2:?}"; shift 2 ;;
    --out)      out="${2:?}"; shift 2 ;;
    --version)  version="${2:?}"; shift 2 ;;
    --lock-key) lock_key="${2:?}"; shift 2 ;;
    *) printf 'unknown option: %s\n' "$1" >&2; exit 2 ;;
  esac
done
[ -d "$package/picoemulator" ] || { printf 'not a package: %s\n' "$package" >&2; exit 1; }
[ -n "$out" ] || { printf -- '--out is required\n' >&2; exit 2; }

repo_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
commit="$(git -C "$repo_dir" rev-parse HEAD)"
count="$(git -C "$repo_dir" rev-list --count HEAD)"
[ -n "$version" ] || version="v0.$count"
epoch="$(sed -n 's/^SOURCE_DATE_EPOCH=//p' "$repo_dir/revisions.lock")"
manifest_rev="$(sed -n 's/^MANIFEST_REV=//p' "$repo_dir/revisions.lock")"
[ -n "$epoch" ] || { printf 'revisions.lock has no SOURCE_DATE_EPOCH\n' >&2; exit 1; }

name="pico-emulator-linux-$version"
stage="$(mktemp -d)"
trap 'rm -rf "$stage"' EXIT
root="$stage/$name"
mkdir -p "$root/scripts" "$root/systemd"
cp -a "$package" "$root/linux-pico-package"
cp -p "$repo_dir/scripts/install-pico-emulator.sh" "$root/scripts/"
cp -p "$repo_dir"/systemd/*.service "$root/systemd/"
cp -p "$repo_dir/docs/host-install.md" "$root/README.md"

{
  printf 'version=%s\n' "$version"
  printf 'repository=https://github.com/komastudios/PICO-Emulator\n'
  printf 'commit=%s\ncommit_count=%s\n' "$commit" "$count"
  printf 'manifest_rev=%s\nsource_date_epoch=%s\n' "$manifest_rev" "$epoch"
  [ -n "$lock_key" ] && printf 'lock_key=%s\n' "$lock_key"
  printf 'variant=%s\n' "$(cat "$package/.build-variant" 2>/dev/null || echo unknown)"
  if [ -f "$package/picoemulator/.pico-provenance" ]; then
    printf '\n# projects built (path commit)\n'
    grep '^PROJECT ' "$package/picoemulator/.pico-provenance" | sed 's/^PROJECT //'
  fi
} > "$root/RELEASE"

(cd "$root" && find . -type f ! -name SHA256SUMS | sort | sed 's|^\./||' | xargs sha256sum > SHA256SUMS)

mkdir -p "$out"
archive="$out/$name.tar.zst"
tar --format=posix --sort=name --numeric-owner --owner=0 --group=0 \
    --mtime="@$epoch" \
    --pax-option=exthdr.name=%d/PaxHeaders/%f,delete=atime,delete=ctime \
    -C "$stage" -cf - "$name" \
  | zstd -q -T0 -19 -o "$archive" -f
sha256sum "$archive" | sed "s|$out/||" > "$archive.sha256"
printf 'Release %s: %s (%s)\n' "$version" "$archive" "$(du -h "$archive" | cut -f1)"
cat "$archive.sha256"
