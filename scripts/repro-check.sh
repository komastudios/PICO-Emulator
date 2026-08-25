#!/usr/bin/env bash
# Compare two extracted packages file by file and explain any difference.
#
#   scripts/repro-check.sh <package-a> <package-b> [report-file]
#
# Each argument is a linux-pico-package directory (the output of `task extract`).
# Exit 0 when every file is byte-identical, 1 otherwise. When diffoscope is
# installed, each differing file gets a section in the report; without it the
# report lists the differing paths only.
set -euo pipefail

a="${1:?package A}"
b="${2:?package B}"
report="${3:-}"

for d in "$a" "$b"; do
  [ -d "$d/picoemulator" ] || { printf 'not a package directory: %s\n' "$d" >&2; exit 2; }
done

list() {
  # Path, then hash, so the diff reads by file; symlinks are compared by target.
  (cd "$1" && find . -type f -o -type l | LC_ALL=C sort | while read -r p; do
    if [ -L "$p" ]; then printf '%s  link:%s\n' "$p" "$(readlink "$p")"
    else printf '%s  %s\n' "$p" "$(sha256sum "$p" | cut -d' ' -f1)"; fi
  done)
}

tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT
list "$a" > "$tmp/a"
list "$b" > "$tmp/b"

only_a="$(comm -23 <(cut -d' ' -f1 "$tmp/a") <(cut -d' ' -f1 "$tmp/b") || true)"
only_b="$(comm -13 <(cut -d' ' -f1 "$tmp/a") <(cut -d' ' -f1 "$tmp/b") || true)"
differing="$(join "$tmp/a" "$tmp/b" | awk '$2 != $3 {print $1}' || true)"

total="$(wc -l < "$tmp/a")"
if [ -z "$only_a$only_b$differing" ]; then
  printf 'reproducible: %s files identical\n' "$total"
  [ -n "$report" ] && printf 'reproducible: %s files identical\n%s\n%s\n' "$total" "$a" "$b" > "$report"
  exit 0
fi

{
  printf 'NOT reproducible\nA: %s\nB: %s\n\n' "$a" "$b"
  [ -n "$only_a" ] && printf 'only in A:\n%s\n\n' "$only_a"
  [ -n "$only_b" ] && printf 'only in B:\n%s\n\n' "$only_b"
  if [ -n "$differing" ]; then
    printf 'differing (%s of %s files):\n%s\n\n' "$(printf '%s\n' "$differing" | wc -l)" "$total" "$differing"
    if command -v diffoscope >/dev/null 2>&1; then
      while read -r p; do
        printf '=== %s\n' "$p"
        diffoscope --exclude-directory-metadata=yes --max-text-report-size 200000 \
          --text - "$a/$p" "$b/$p" 2>/dev/null | head -n 400 || true
        printf '\n'
      done <<< "$differing"
    else
      printf 'diffoscope not installed; install it for per-file analysis.\n'
    fi
  fi
} > "$tmp/report"
if [ -n "$report" ]; then cp "$tmp/report" "$report"; fi
head -n 60 "$tmp/report"
if [ "$(wc -l < "$tmp/report")" -gt 60 ]; then
  printf '\n[... %s more lines%s]\n' "$(( $(wc -l < "$tmp/report") - 60 ))" "${report:+ in $report}"
fi
exit 1
