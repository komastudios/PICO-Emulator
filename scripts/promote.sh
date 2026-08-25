#!/usr/bin/env bash
# Promote stage artifacts through an OCI registry with oras.
#
#   promote.sh push-sources <cache-dir> <lock-key> <ref>
#   promote.sh pull-sources <cache-dir> <lock-key> <ref>
#   promote.sh exists <ref>
#
# The source archive is split into parts of at most PART_SIZE (default 1900M)
# so every layer stays well under registry per-layer limits and upload
# timeouts. The uncompressed content hash and the file list travel as extra
# layers; the content hash is also an annotation on the manifest.
set -euo pipefail

cmd="${1:?command}"
part_size="${PART_SIZE:-1900M}"
oras="${ORAS:-oras}"

need_oras() {
  command -v "$oras" >/dev/null 2>&1 || {
    printf 'oras is not installed; see https://oras.land/docs/installation\n' >&2; exit 1; }
}

case "$cmd" in
  exists)
    ref="${2:?ref}"
    need_oras
    "$oras" manifest fetch "$ref" >/dev/null 2>&1
    ;;
  push-sources)
    cache="${2:?cache dir}"; key="${3:?lock key}"; ref="${4:?ref}"
    need_oras
    archive="$cache/sources-$key.tar.zst"
    [ -f "$archive" ] || { printf 'no archive at %s\n' "$archive" >&2; exit 1; }
    sha="$(cat "${archive%.zst}.sha256")"
    work="$(mktemp -d "$cache/promote.XXXXXX")"
    trap 'rm -rf "$work"' EXIT
    cp "${archive%.zst}.sha256" "$work/sources.tar.sha256"
    cp "$archive.list" "$work/sources.list"
    split -b "$part_size" -d -a 3 "$archive" "$work/sources.tar.zst.part-"
    (
      cd "$work"
      files=(sources.tar.sha256:text/plain sources.list:text/plain)
      for p in sources.tar.zst.part-*; do files+=("$p:application/zstd"); done
      printf 'pushing %s layers to %s\n' "${#files[@]}" "$ref"
      "$oras" push "$ref" \
        --artifact-type application/vnd.pico.emulator.sources.v1 \
        --annotation "dev.pico.lock-key=$key" \
        --annotation "dev.pico.tar-sha256=$sha" \
        --annotation "org.opencontainers.image.source=https://github.com/komastudios/PICO-Emulator" \
        "${files[@]}"
    )
    ;;
  pull-sources)
    cache="${2:?cache dir}"; key="${3:?lock key}"; ref="${4:?ref}"
    need_oras
    archive="$cache/sources-$key.tar.zst"
    if [ -f "$archive" ] && [ -f "${archive%.zst}.sha256" ]; then
      printf 'archive already present at %s\n' "$archive"; exit 0
    fi
    work="$(mktemp -d "$cache/promote.XXXXXX")"
    trap 'rm -rf "$work"' EXIT
    "$oras" pull "$ref" -o "$work"
    cat "$work"/sources.tar.zst.part-* > "$archive.tmp"
    want="$(cat "$work/sources.tar.sha256")"
    got="$(zstd -dc --long=27 "$archive.tmp" | sha256sum | cut -d' ' -f1)"
    if [ "$want" != "$got" ]; then
      printf 'content hash mismatch: manifest says %s, archive is %s\n' "$want" "$got" >&2
      rm -f "$archive.tmp"; exit 1
    fi
    mv "$archive.tmp" "$archive"
    cp "$work/sources.tar.sha256" "${archive%.zst}.sha256"
    cp "$work/sources.list" "$archive.list"
    printf 'pulled %s (%s), content sha256 %s\n' "$archive" "$(du -h "$archive" | cut -f1)" "$got"
    ;;
  *)
    printf 'unknown command: %s\n' "$cmd" >&2; exit 2 ;;
esac
