# Host install

`scripts/install-pico-emulator.sh` installs the package produced by `task build` onto a systemd host: the service user, the directory layout, the SDK symlinks, and three units. It is idempotent — re-running only updates what changed.

```bash
task build                       # produces dist/linux-pico-package
sudo task install                # extract (if needed) + install
sudo scripts/install-pico-emulator.sh --dry-run   # show what would change
```

## Options

| Option | Default | |
| --- | --- | --- |
| `--source DIR` | `./dist/linux-pico-package` | package to install from |
| `--prefix DIR` | `/opt/android/PICO` | install root |
| `--state DIR` | `/var/lib/android` | mutable state root |
| `--user NAME` | `android` | service user |
| `--group NAME` | none | extra supplementary group for the emulator service (repeatable); must exist |
| `--config FILE` | `/etc/pico-emulator/site.conf` if present | site configuration sourced before the options: `PICO_GROUPS`, `PICO_PREFIX`, `PICO_STATE_DIR`, `PICO_USER`, `PICO_SOURCE` |
| `--restart` / `--no-restart` | prompt on a tty, restart otherwise | what to do when something changed |
| `--dry-run` | | print the plan, touch nothing |
| `--skip-units` | | install the package only, leave systemd alone |
| `--own-root` | off | reset the package tree to root:root ownership and modes |
| `--prune` | off | remove files under `picoemulator/` the package does not contain |

`--own-root` and `--prune` are off deliberately. A live deployment may use different ownership on purpose, and may hold hand-placed rollback libraries the build knows nothing about; the installer lists what it would remove rather than guessing.

## Site configuration

Anything host-specific lives outside the repository, in `/etc/pico-emulator/site.conf` (or a file passed with `--config`). It is a shell fragment:

```sh
# /etc/pico-emulator/site.conf
PICO_GROUPS="projectgroup"      # extra supplementary groups; must already exist
# PICO_PREFIX=/opt/android/PICO
# PICO_STATE_DIR=/var/lib/android
# PICO_USER=android
# PICO_SOURCE=/path/to/linux-pico-package
```

Command-line options override it. Without a site configuration the defaults apply and no extra group is involved.

## What gets created

- **Service user** `android`. Existing accounts are left untouched — group membership is added, the account definition is not rewritten. The user needs `kvm` for acceleration. If the install root is owned by a site group (for example a setgid project directory under `/opt`), name that group in the site configuration; the installer adds the service user to it and writes `pico-emulator.service.d/10-site-groups.conf` so the unit can traverse the directory. The shipped unit itself lists only `kvm`.
- **Install root** `/opt/android/PICO`, holding `linux-pico-package/` (the package) and `sdk/`, where `sdk/emulator` is a symlink to `../linux-pico-package/picoemulator` and `sdk/platform-tools` is a normal Android SDK package.
- **State root** `/var/lib/android`, holding the AVD, `picoAvdConfig/`, temp files and the ADB key. Nothing mutable lives under the install root.

## Immutable vs mutable

The split is the reason the installer is safe to re-run: everything under `/opt/android/PICO` is build output and can be replaced wholesale, while everything the running emulator writes lives under `/var/lib/android` and is never touched. The AVD is seeded from `avd-api36/` on first boot only.

## The guest image

The installer never touches the proprietary guest image. It must be present at the absolute path the AVD seed's `image.sysdir.1` names:

```
/opt/android/PICO/linux-pico-package/swan_rls_spaceos_oversea_K_pico_emulator_win64_20260731_ide/system-images/system-images
```

The path is absolute because the AVD config points at it; the installer checks for it and reports whether it is present.

## The three units

| Unit | |
| --- | --- |
| `pico-display.service` | `Xvfb :99 -screen 0 2880x1440x24` — the virtual display the emulator renders into |
| `android-adb.service` | the ADB server |
| `pico-emulator.service` | the emulator itself, `After=` the other two |

`pico-emulator.service` runs as `android:android` with supplementary group `kvm` (plus any site groups via the drop-in), `DISPLAY=:99`, and `PICO_*` variables pointing the start script at the state root, the AVD name and its seed. It starts `scripts/start-pico-linux.sh`, which seeds the AVD if needed and launches the emulator with `-no-snapshot -no-boot-anim -writable-system`.

If `/dev/kvm` is not readable and writable, the start script warns and falls back to `-accel off`, which is very slow. Add the service user to `kvm` instead.

## Verifying a deployment

```bash
systemctl status pico-emulator.service
/opt/android/PICO/sdk/platform-tools/adb devices -l
/opt/android/PICO/sdk/platform-tools/adb -s emulator-5554 shell getprop sys.boot_completed
```

A booted guest reports `1`. To see what it is rendering, capture the virtual display from the host:

```bash
DISPLAY=:99 scrot -o /tmp/pico.png
```

Note that `screencap` inside the guest can wedge permanently after an XR app crashes mid-session; restarting `pico-emulator.service` clears it.

Expected renderer, confirming the ANGLE/gfxstream → Vulkan → lavapipe path:

```
ANGLE (Mesa, Vulkan 1.4.305 (llvmpipe (LLVM 19.1.7 256 bits)))
```

## Debug builds

`task debug` produces a package whose gfxstream dumps **every** SPIR-V shader module to `$STATE_DIR/pico-shaders/` and logs descriptor-set bindings — unconditional file I/O in a hot path, with unbounded disk growth. The installer warns when it detects that variant. Use it for diagnosis, not for a deployment you intend to leave running.
