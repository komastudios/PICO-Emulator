#!/usr/bin/env bash
# Install, configure, or update the PICO Spatial emulator on this host.
#
# Safe to re-run. Every step is idempotent: an existing service user, group
# membership, directory, symlink, or unit file is checked and brought up to
# date rather than recreated. Nothing is removed that the installer does not
# own — in particular the proprietary guest image directory is never touched.
#
# Usage:
#   sudo scripts/install-pico-emulator.sh [options]
#
#   --source DIR     Package to install from. Default: ./dist/linux-pico-package
#                    (produced by `task extract`).
#   --prefix DIR     Install root. Default: /opt/android/PICO
#   --state DIR      Mutable state root. Default: /var/lib/android
#   --user NAME      Service user. Default: android
#   --restart        Restart the emulator when the install changed something.
#   --no-restart     Never restart; print the commands instead.
#   --dry-run        Show what would change and exit without touching anything.
#   --skip-units     Install the package only, leave systemd alone.
#   --own-root       Reset the install directories and package tree to the
#                    documented root:root ownership and modes. Off by default:
#                    an existing deployment may deliberately use different
#                    ownership, and this script does not second-guess it.
#   --prune          Also remove files under picoemulator/ that this package
#                    does not contain. Off by default: a live deployment may
#                    hold hand-placed rollback libraries the build knows
#                    nothing about. Listed before removal.
#   -h, --help       This text.
#
# With neither --restart nor --no-restart: prompts on a terminal, restarts
# automatically when run non-interactively.
set -euo pipefail

SOURCE_DIR=""
PREFIX=/opt/android/PICO
STATE_DIR=/var/lib/android
SVC_USER=android
SVC_GROUP=android
RESTART_MODE=ask
DRY_RUN=0
SKIP_UNITS=0
PRUNE=0
OWN_ROOT=0

repo_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"

die()  { printf 'error: %s\n' "$*" >&2; exit 1; }
info() { printf '  %s\n' "$*"; }
step() { printf '\n== %s\n' "$*"; }
run()  { if [ "$DRY_RUN" -eq 1 ]; then printf '  would run: %s\n' "$*"; else "$@"; fi; }

usage() { sed -n '2,35p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'; exit 0; }

while [ $# -gt 0 ]; do
  case "$1" in
    --source)     SOURCE_DIR="${2:?--source needs a directory}"; shift 2 ;;
    --prefix)     PREFIX="${2:?--prefix needs a directory}"; shift 2 ;;
    --state)      STATE_DIR="${2:?--state needs a directory}"; shift 2 ;;
    --user)       SVC_USER="${2:?--user needs a name}"; SVC_GROUP="$2"; shift 2 ;;
    --restart)    RESTART_MODE=yes; shift ;;
    --no-restart) RESTART_MODE=no; shift ;;
    --dry-run)    DRY_RUN=1; shift ;;
    --skip-units) SKIP_UNITS=1; shift ;;
    --prune)      PRUNE=1; shift ;;
    --own-root)   OWN_ROOT=1; shift ;;
    -h|--help)    usage ;;
    *)            die "unknown option: $1 (try --help)" ;;
  esac
done

[ -n "$SOURCE_DIR" ] || SOURCE_DIR="$repo_dir/dist/linux-pico-package"
PACKAGE="$PREFIX/linux-pico-package"
UNIT_DIR=/etc/systemd/system
UNITS="pico-display.service android-adb.service pico-emulator.service"
GUEST_DIR="$PACKAGE/swan_rls_spaceos_oversea_K_pico_emulator_win64_20260731_ide/system-images/system-images"

changed_pkg=0
changed_meta=0
changed_units=0
warnings=()
warn() { warnings+=("$1"); printf '  warning: %s\n' "$1" >&2; }

# --------------------------------------------------------------- preflight --
step "Preflight"
[ "$DRY_RUN" -eq 1 ] || [ "$(id -u)" -eq 0 ] || die "must run as root (use sudo), or pass --dry-run"
command -v rsync >/dev/null || die "rsync is required"
[ -d "$SOURCE_DIR" ] || die "package not found: $SOURCE_DIR (run 'make' first)"
[ -x "$SOURCE_DIR/picoemulator/emulator" ] || die "not a PICO package: $SOURCE_DIR/picoemulator/emulator is missing"
for f in start-pico-linux.sh wait-pico-display.sh wait-pico-boot.sh; do
  [ -f "$SOURCE_DIR/$f" ] || die "package is incomplete: $f is missing"
done
info "source:  $SOURCE_DIR"
info "prefix:  $PREFIX"
info "state:   $STATE_DIR"
if [ -f "$SOURCE_DIR/.build-variant" ]; then
  variant="$(cat "$SOURCE_DIR/.build-variant")"
  info "variant: $variant"
  [ "$variant" = "debug" ] && warn "this is the debug build; it dumps every SPIR-V shader module to $STATE_DIR/pico-shaders/"
fi
if [ "$SKIP_UNITS" -eq 0 ]; then
  command -v systemctl >/dev/null || die "systemd is required (or pass --skip-units)"
  for u in $UNITS; do
    [ -f "$repo_dir/systemd/$u" ] || die "unit template missing: $repo_dir/systemd/$u"
  done
fi
[ -e /dev/kvm ] || warn "/dev/kvm is absent; the guest will fall back to very slow software emulation"

# ------------------------------------------------------------ user & groups --
step "Service user and groups"
if getent group sitegroup >/dev/null; then
  info "group sitegroup already exists"
else
  run groupadd --system sitegroup
  info "created group sitegroup"
fi

if id -u "$SVC_USER" >/dev/null 2>&1; then
  info "user $SVC_USER already exists (uid $(id -u "$SVC_USER")); leaving its account definition untouched"
  current_home="$(getent passwd "$SVC_USER" | cut -d: -f6)"
  [ "$current_home" = "$STATE_DIR" ] || \
    warn "user $SVC_USER has home '$current_home', not '$STATE_DIR'; the units set HOME=$STATE_DIR explicitly so this is tolerated"
else
  run useradd --system --home-dir "$STATE_DIR" --create-home \
      --shell /usr/sbin/nologin "$SVC_USER"
  info "created system user $SVC_USER"
fi

# usermod -aG is additive and a no-op when membership already exists.
for g in kvm sitegroup; do
  if ! getent group "$g" >/dev/null; then
    warn "group $g does not exist; skipping membership"
    continue
  fi
  if id -nG "$SVC_USER" 2>/dev/null | tr ' ' '\n' | grep -qx "$g"; then
    info "$SVC_USER is already in group $g"
  else
    run usermod -aG "$g" "$SVC_USER"
    info "added $SVC_USER to group $g"
  fi
done

# ------------------------------------------------------------- directories --
step "Directories"
# An existing directory is left exactly as it is. A deployment may deliberately
# use different ownership or a setgid group so administrators can manage the
# tree; resetting that is not this script's business. Only missing directories
# are created, with the documented owner and mode. --own-root opts into
# normalising the ones that already exist.
ensure_dir() {
  local owner="$1" group="$2" mode="$3" dir="$4"
  if [ ! -d "$dir" ]; then
    run install -d -o "$owner" -g "$group" -m "$mode" "$dir"
    info "created $dir ($owner:$group $mode)"
  elif [ "$OWN_ROOT" -eq 1 ]; then
    run chown "$owner:$group" "$dir"
    run chmod "$mode" "$dir"
    info "reset $dir to $owner:$group $mode"
  else
    info "exists, left as is: $dir ($(stat -c '%U:%G %a' "$dir" 2>/dev/null))"
  fi
}
ensure_dir "$SVC_USER" "$SVC_GROUP" 0750 "$STATE_DIR"
ensure_dir "$SVC_USER" "$SVC_GROUP" 0700 "$STATE_DIR/.android"
ensure_dir "$SVC_USER" "$SVC_GROUP" 0750 "$STATE_DIR/tmp"
# pico-emulator.service bind-mounts this over /tmp/android-android; it must exist.
ensure_dir "$SVC_USER" "$SVC_GROUP" 0750 "$STATE_DIR/tmp/android-android"
ensure_dir "$SVC_USER" "$SVC_GROUP" 0750 "$STATE_DIR/avd"
ensure_dir root root 0755 "$PREFIX"
ensure_dir root root 0755 "$PACKAGE"
ensure_dir root root 0755 "$PREFIX/sdk"

# ----------------------------------------------------------------- package --
step "Package"
# --delete is safe here: this subtree is entirely ours. The sibling vendor
# guest-image directory under $PACKAGE is never in an rsync target path.
# Distinguish real content changes from metadata-only ones. rsync's itemize
# format puts the update type first: '.' means nothing was transferred (only
# permissions/owner/time differ), while '>', '<', 'c' and '*' mean data moved,
# was created, or was deleted. Only the latter should provoke a restart — a
# chmod or a newer mtime does not change what the emulator executes.
#
# --checksum is required for that distinction to be true. Without it rsync
# decides by size+mtime, so a rebuilt-but-identical file is reported as a
# transfer and would trigger a needless restart of a running emulator. The
# extra cost is one pass over ~470 MB.
#
# --no-owner/--no-group matter just as much: the package is chowned to root
# below, so preserving the source's ownership would make rsync and chown undo
# each other and report hundreds of metadata changes on every single run.
sync_one() {
  local src="$1" dst="$2"; shift 2
  local out n_all n_data
  if [ "$DRY_RUN" -eq 1 ]; then
    out="$(rsync -a --no-owner --no-group --checksum --itemize-changes --dry-run "$@" "$src" "$dst" 2>/dev/null || true)"
  else
    out="$(rsync -a --no-owner --no-group --checksum --itemize-changes "$@" "$src" "$dst")"
  fi
  if [ -z "$out" ]; then
    info "up to date: ${dst#"$PREFIX"/}"
    return
  fi
  n_all="$(printf '%s\n' "$out" | grep -c .)"
  n_data="$(printf '%s\n' "$out" | grep -c '^[><c*]' || true)"
  if [ "$n_data" -gt 0 ]; then
    changed_pkg=1
    info "${dst#"$PREFIX"/}: $n_data content change(s), $((n_all - n_data)) metadata-only"
  else
    changed_meta=1
    info "${dst#"$PREFIX"/}: $n_all metadata-only change(s) (permissions/ownership)"
  fi
}
# --delete is opt-in. A live deployment can hold hand-placed rollback libraries
# (libvk_swiftshader.so.pico-reference-*, libgfxstream_backend.so.pre-*, ...)
# that this package does not contain; silently deleting them would discard the
# documented rollback path.
prune_args=()
if [ "$PRUNE" -eq 1 ]; then
  removals="$(rsync -a --no-owner --no-group --checksum --itemize-changes --dry-run --delete \
      "$SOURCE_DIR/picoemulator/" "$PACKAGE/picoemulator/" 2>/dev/null \
      | grep '^\*deleting' || true)"
  if [ -n "$removals" ]; then
    info "--prune will remove $(printf '%s\n' "$removals" | grep -c .) path(s):"
    printf '%s\n' "$removals" | sed 's/^\*deleting */      /'
  fi
  prune_args=(--delete)
else
  stale="$(rsync -a --no-owner --no-group --checksum --itemize-changes --dry-run --delete \
      "$SOURCE_DIR/picoemulator/" "$PACKAGE/picoemulator/" 2>/dev/null \
      | grep -c '^\*deleting' || true)"
  [ "${stale:-0}" -gt 0 ] && \
    info "$stale path(s) exist under picoemulator/ that this package does not provide; keeping them (use --prune to remove)"
fi
# --chmod=a+rX is folded into the transfer rather than applied afterwards. The
# package ships one file as mode 700, unreachable for a non-root service user.
# A follow-up chmod would fight rsync's own -p on every run; doing it here makes
# the destination mode deterministically "source | a+rX", so a repeat run is a
# genuine no-op. a+rX only adds bits and can never lock anything out.
sync_one "$SOURCE_DIR/picoemulator/" "$PACKAGE/picoemulator/" --chmod=a+rX "${prune_args[@]+"${prune_args[@]}"}"
sync_one "$SOURCE_DIR/avd-api36/"    "$PACKAGE/avd-api36/" --chmod=a+rX
for f in start-pico-linux.sh wait-pico-display.sh wait-pico-boot.sh; do
  sync_one "$SOURCE_DIR/$f" "$PACKAGE/$f" --chmod=F0755
done
[ -f "$SOURCE_DIR/SHA256SUMS" ] && run install -m 0644 "$SOURCE_DIR/SHA256SUMS" "$PACKAGE/SHA256SUMS"
unreadable="$(find "$PACKAGE/picoemulator" "$PACKAGE/avd-api36" \
    \( -type f -o -type d \) ! -perm -o+r 2>/dev/null | wc -l)"
if [ "${unreadable:-0}" -gt 0 ]; then
  warn "$unreadable path(s) under the package are not readable by others; $SVC_USER may not be able to use them"
else
  info "package is readable by $SVC_USER"
fi
if [ "$OWN_ROOT" -eq 1 ]; then
  run chown -R root:root "$PACKAGE/picoemulator" "$PACKAGE/avd-api36"
  info "package tree chowned to root:root"
else
  info "package ownership left as is (use --own-root to normalise to root:root)"
fi

# The unit puts this directory on LD_LIBRARY_PATH and angle_indirect needs the
# ANGLE GLES libraries in it. A package without it cannot render.
if [ -f "$PACKAGE/picoemulator/lib64/gles_angle_pico_linux/libangle_st.so" ]; then
  info "ANGLE GLES libraries present (lib64/gles_angle_pico_linux)"
else
  warn "lib64/gles_angle_pico_linux/libangle_st.so is missing. pico-emulator.service points LD_LIBRARY_PATH at that directory and PICO_GPU_MODE=angle_indirect needs it; rendering will fail. Rebuild with a package that includes the ANGLE prebuilt."
fi

# ------------------------------------------------------------- sdk symlinks --
step "SDK layout"
run ln -sfn ../linux-pico-package/picoemulator "$PREFIX/sdk/emulator"
info "$PREFIX/sdk/emulator -> ../linux-pico-package/picoemulator"
if [ -x "$PREFIX/sdk/platform-tools/adb" ]; then
  info "platform-tools present: $("$PREFIX/sdk/platform-tools/adb" version 2>/dev/null | head -1)"
elif command -v adb >/dev/null; then
  run install -d -m 0755 "$PREFIX/sdk/platform-tools"
  run ln -sfn "$(command -v adb)" "$PREFIX/sdk/platform-tools/adb"
  warn "linked the distribution's adb ($(command -v adb)); android-adb.service expects $PREFIX/sdk/platform-tools/adb"
else
  warn "no adb found. Install Android SDK platform-tools into $PREFIX/sdk/platform-tools, or android-adb.service will fail"
fi

# ------------------------------------------------------------- guest image --
step "Guest image"
if [ -d "$GUEST_DIR" ] && [ -n "$(ls -A "$GUEST_DIR" 2>/dev/null)" ]; then
  info "present: $GUEST_DIR"
else
  warn "the proprietary API 36 guest image is absent. The emulator cannot boot until it is extracted to:
             $GUEST_DIR
           See README.md section 1 for the archive and its SHA-256."
fi

# ------------------------------------------------------------------ units ---
if [ "$SKIP_UNITS" -eq 1 ]; then
  step "systemd units"; info "skipped (--skip-units)"
else
  step "systemd units"
  for u in $UNITS; do
    if [ -f "$UNIT_DIR/$u" ] && cmp -s "$repo_dir/systemd/$u" "$UNIT_DIR/$u"; then
      info "unchanged: $u"
    else
      run install -m 0644 "$repo_dir/systemd/$u" "$UNIT_DIR/$u"
      changed_units=1
      info "installed: $u"
    fi
  done
  if [ "$changed_units" -eq 1 ]; then
    run systemctl daemon-reload
    info "reloaded systemd"
  fi
  for u in $UNITS; do
    if systemctl is-enabled --quiet "$u" 2>/dev/null; then
      info "already enabled: $u"
    else
      run systemctl enable "$u" >/dev/null 2>&1 || warn "could not enable $u"
      info "enabled: $u"
    fi
  done
fi

# ---------------------------------------------------------------- restart ---
step "Service state"
if [ "$DRY_RUN" -eq 1 ]; then
  printf '  dry run: no changes were made\n'
  exit 0
fi

emulator_active=0
systemctl is-active --quiet pico-emulator.service 2>/dev/null && emulator_active=1
needs_restart=0
{ [ "$changed_pkg" -eq 1 ] || [ "$changed_units" -eq 1 ]; } && needs_restart=1

restart_cmd="systemctl restart pico-display.service android-adb.service pico-emulator.service"
start_cmd="systemctl start pico-display.service android-adb.service pico-emulator.service"

do_restart() {
  info "restarting services..."
  systemctl restart pico-display.service android-adb.service
  systemctl restart pico-emulator.service
}

if [ "$SKIP_UNITS" -eq 1 ]; then
  info "units were skipped; not touching running services"
elif [ "$emulator_active" -eq 0 ]; then
  info "pico-emulator.service is not running. Start it with:"
  printf '\n    sudo %s\n' "$start_cmd"
elif [ "$needs_restart" -eq 0 ]; then
  if [ "$changed_meta" -eq 1 ]; then
    info "only permissions/ownership changed; the running emulator does not need a restart"
  else
    info "nothing changed; the running emulator does not need a restart"
  fi
else
  case "$RESTART_MODE" in
    yes) do_restart ;;
    no)  info "changes require a restart to take effect. Run:"
         printf '\n    sudo %s\n' "$restart_cmd" ;;
    ask)
      if [ -t 0 ]; then
        printf '\n  The emulator is running and the installed files changed.\n'
        read -r -p "  Restart it now? [Y/n] " reply
        case "${reply:-Y}" in
          [Nn]*) info "not restarting. Run: sudo $restart_cmd" ;;
          *)     do_restart ;;
        esac
      else
        do_restart
      fi
      ;;
  esac
fi

# ----------------------------------------------------------------- summary --
step "Summary"
if [ "$SKIP_UNITS" -eq 0 ]; then
  for u in $UNITS; do
    printf '  %-26s %s\n' "$u" "$(systemctl is-active "$u" 2>/dev/null || true)"
  done
fi
if [ "${#warnings[@]}" -gt 0 ]; then
  printf '\n  %d warning(s):\n' "${#warnings[@]}"
  for w in "${warnings[@]}"; do printf '    - %s\n' "$w"; done
fi
printf '\n  Verify a booted guest with:\n'
printf '    %s/sdk/platform-tools/adb devices -l\n' "$PREFIX"
printf '    %s/sdk/platform-tools/adb -s emulator-5554 shell getprop sys.boot_completed\n' "$PREFIX"
