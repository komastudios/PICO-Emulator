# Build pipeline

The build is a single podman image build driven by `Taskfile.yml`. It syncs the PICO emulator sources through `repo`, compiles the Linux host, and emits a self-contained package under `dist/`. No proprietary PICO content enters the image — see **Required proprietary input** in `README.md`.

```
task build            # sync + compile + deploy image + extract to dist/
task debug            # same, with the gfxstream debug variant
task config           # print the resolved configuration, build nothing
task verify           # repository completeness, script syntax, units, file modes
```

## Stages

The `Containerfile` has four stages:

| Stage | What it does |
| --- | --- |
| `base` | Debian 13 layer shared by builder and deploy |
| `builder` | toolchain: `repo`, git-lfs, cmake/ninja, and the qemu build dependencies |
| `build` | runs `scripts/container-build.sh`: `repo init` + `repo sync`, then `external/qemu/android/rebuild.sh`; emits the distribution tree to `/out` |
| `deploy` | runtime image: the built binaries plus every runtime dependency |

`task build` targets `deploy`, then runs `task extract`, which copies `/opt/android/PICO/linux-pico-package` out of the image into `dist/`, writes `.build-variant`, and records `SHA256SUMS` over the four binaries that matter (`emulator`, `qemu-system-x86_64`, `libgfxstream_backend.so`, `libvulkan_lvp.so`).

## The build cache

`repo sync` produces roughly 108 GB of checkout, so it is kept outside the image: the Taskfile bind-mounts `CACHE_DIR` (default `./.cache`) at `/cache`, and the source tree lives at `/cache/src`. The first build syncs it; later builds reuse it, and the compile is incremental.

Two caches interact:

- **The bind mount** (`/cache`) keeps the checkout and object files across builds.
- **podman's layer cache** skips the `build` stage entirely when neither the stage's inputs nor its build args changed — so editing only the deploy stage rebuilds in under a minute.

That second one is a trap when you change a *fork* rather than this repository: the manifest URL and branch are unchanged, so podman reuses the cached layer and you get the old binaries. Bump `CACHE_BUST` to force the stage to re-run:

```bash
task build CACHE_BUST=1
```

`task cache-info` reports the cache size; `task clean-cache` deletes it.

Without the `/cache` mount the build still works, but nothing is reused and the source tree is removed before the layer is committed.

## Reproducible sync: the lock

`repo` normally follows branch tips, so two syncs a day apart can produce different binaries. `scripts/write-lock.py` resolves everything to commits and writes:

| File | Contents |
| --- | --- |
| `revisions.lock` | manifest URL, branch, file, the manifest **commit**, and one `PROJECT <path> <commit>` line per asserted project |
| `manifests/pins.xml` | a `repo` local manifest with `<extend-project revision=…>` for the projects the manifest leaves on a branch (`aemu`, `common`) |

`revisions-debug.lock` and `manifests/pins-debug.xml` are the same for the debug manifest.

The Taskfile reads `MANIFEST_REV` out of the lock and passes it, the lock, and the pins into the build. `container-build.sh` then:

1. runs `repo init -b <manifest commit>` instead of `-b <branch>`,
2. copies the pins file to `.repo/local_manifests/pins.xml` so floating projects check out the recorded commits,
3. after syncing, **asserts** that every `PROJECT` line in the lock matches the actual `HEAD`, and fails the build if not.

If the lock files are absent the build still works — it follows the branch tips and says so (`Manifest following branch pico-linux (unlocked)`).

```bash
task lock          # re-resolve both variants against the current tips
task lock:check    # fail with a diff if the lock is stale; good for CI
```

Update the lock deliberately, as its own commit: it is the record of what a released binary was built from.

## Tolerated build failure

`rebuild.sh` runs an acceleration check at the very end that cannot load `libnvidia-ml.so.1` on a CPU-only host, so it exits non-zero *after* the distribution is complete. `container-build.sh` tolerates exactly that case: it verifies `emulator`, `qemu-system-x86_64` and `libgfxstream_backend.so` all exist and are non-empty, and only then treats the exit status as the known NVML check. Any other failure is fatal.

## ANGLE prebuilt

The build does not emit `lib64/gles_angle_pico_linux`, but `pico-emulator.service` puts exactly that directory on `LD_LIBRARY_PATH` and `PICO_GPU_MODE=angle_indirect` needs the ANGLE GLES libraries in it. `container-build.sh` copies them verbatim from the ANGLE prebuilt shipped in `PICO-Emulator-common`. Without it a container-built package cannot render, so the script fails loudly if the prebuilt is missing — usually a sign that `git lfs pull` did not run.

## Rootless podman

On a host whose login has no systemd user session, podman cannot use the systemd cgroup manager. Pass the flags through rather than changing the default:

```bash
PODMAN_FLAGS="--cgroup-manager=cgroupfs --events-backend=file" task build
```

## Where the sources come from

Only two projects carry Linux-port changes; both are forks pinned by the manifest, and both are also mirrored as patch files under `patches/`, inventoried in `patches/README.md`. See **Sources** in `README.md` for the fork URLs and branches.
