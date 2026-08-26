# Build pipeline

The build is a single podman image build driven by `Taskfile.yml`. It syncs the PICO emulator sources through `repo`, compiles the Linux host, and emits a self-contained package under `dist/`. No proprietary PICO content enters the image — see **Required proprietary input** in `README.md`.

```
task build            # sync + compile + deploy image + extract to dist/
task debug            # same, with the gfxstream debug variant
task config           # print the resolved configuration, build nothing
task verify           # repository completeness, script syntax, units, file modes
```

## Stages

The `Containerfile` has six stages:

| Stage | What it does |
| --- | --- |
| `base` | Debian 13 layer shared by builder and deploy |
| `builder` | toolchain: `repo`, git-lfs, cmake/ninja, zstd, and the qemu build dependencies |
| `sources` | `container-build.sh sync` + `trim`: lock-governed `repo sync`, trimmed to the Linux inputs, archived to `/cache/sources-<key>.tar.zst` (staged pipeline only) |
| `build` | `container-build.sh all`: `repo init` + `repo sync`, then `external/qemu/android/rebuild.sh`; emits the distribution tree to `/out`. With `SOURCE_ARCHIVE` set it unpacks a promoted archive instead of syncing and also runs `package` |
| `import` | unpacks a promoted `picoemulator-<key>.tar.zst` to `/out` so `deploy` can be built without compiling (`PACKAGE_STAGE=import`) |
| `deploy` | runtime image: the built binaries plus every runtime dependency |

`scripts/container-build.sh` is a dispatcher over one script per stage — `build-sync.sh`, `build-trim.sh`, `build-compile.sh`, `build-package.sh` — sharing `scripts/lib/build-env.sh` (the normalized environment and cache detection). `all` is sync + compile, which is what `task build` runs.

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

## Determinism controls

The lock fixes *what* is built; these fix *how*, so that two builds of the same lock differ as little as the toolchain allows:

| Control | Where |
| --- | --- |
| Base image pinned by digest, not by the mutable `debian:13-slim` tag | `DEBIAN_IMAGE` in `Taskfile.yml`, default in `Containerfile` |
| `SOURCE_DATE_EPOCH`, derived from the locked manifest commit's own timestamp | recorded in `revisions.lock` by `scripts/write-lock.py`, exported by `container-build.sh` |
| `TZ=UTC`, `LC_ALL=C` | `Containerfile` `ENV`, re-exported in `container-build.sh` |
| `umask 022` | `scripts/lib/build-env.sh`, so distribution file modes do not depend on the caller |
| `PYTHONHASHSEED=0` | `scripts/lib/build-env.sh`; build-system Python iterates sets (the NOTICE generator) |
| Compiler cache off (`COMPILER_CACHE=none`) | `Taskfile.yml` default; a cache hit replays a stored object and would mask a difference. `COMPILER_CACHE=auto` re-enables the bundled sccache for development builds, with its cache under `/cache/sccache` |
| Fork-side fixes | qemu `28104445` derives the SDK build number from `SOURCE_DATE_EPOCH` instead of the wall clock; qemu `fe8473f9` seeds the string-obfuscation key from it and sorts the NOTICE output; qemu `27ee429e` runs Qt autogen sequentially so moc output does not depend on uic timing |

Deriving the epoch from the reviewed commit rather than wall-clock time keeps `__DATE__`/`__TIME__` and any embedded timestamp a property of the source. Re-resolve the base image digest when you intend to move it:

```bash
podman pull docker.io/library/debian:13-slim
podman image inspect docker.io/library/debian:13-slim --format '{{index .RepoDigests 0}}'
```

Whether this makes the build byte-reproducible is measured, not assumed: see *Reproducibility status* in `MANIFEST.md` for the latest double-build result. The acceptance test is two builds in **separate** cache roots — the shared `/cache` mount is the opposite of an isolated root — with the compiler cache disabled, compared with:

```bash
task repro:check A=/path/a/dist/linux-pico-package B=/path/b/dist/linux-pico-package
```

which lists every differing file and, when `diffoscope` is installed, explains each difference in `dist/repro-report.txt`.

## What the promoted artifacts contain

Nothing proprietary is ever promoted. The source archive holds only what `repo sync` fetched from the manifest's three public remotes (`github.com/Pico-Developer`, `github.com/komastudios`, `android-review.googlesource.com`), and the trim removes the vendor guest images that ship in `PICO-Emulator-common`. The package archive holds the build output plus files copied verbatim from those same public sources: the ANGLE and netsim prebuilts and `emulatorParams.ini` from `PICO-Emulator-common`/`PICO-Emulator-qemu`, AOSP's `android-info.txt`/`LICENSE`, and the flatbuffers headers. Audited file by file on 2026-08-26 by hashing every non-compiled file in a package against the synced tree. The guest image, the AVD data and anything extracted from the vendor's Windows/macOS packages are mounted at runtime only, and `scripts/build-package.sh` fails the package stage if a file matching their signatures (`*.img`, `system-images`, `kernel-ranchu`, `ramdisk*`, `*swan*`, `*oversea*`, …) appears in the tree.

## Stages and promotion

`task build` does everything in one image build, which needs a machine that can hold the ~157 GB of checkout and objects. The same stages also run one at a time, each promoting a content-addressed artifact the next one starts from — this is what `.github/workflows/build.yml` does on GitHub-hosted runners, and every stage can be run locally:

| Stage | Task | Input | Promoted output |
| --- | --- | --- | --- |
| sources | `task sources` | the lock, `scripts/source-exclude.txt` and `scripts/source-trim.txt` | `CACHE_DIR/sources-<LOCK_KEY>.tar.zst` (+ `.tar.sha256`, `.list`); `task sources:push` sends it to `ghcr.io/komastudios/pico-emulator-sources:<LOCK_KEY>` as an OCI artifact |
| builder | `task builder:image` | the `builder` stage of the `Containerfile` | `ghcr.io/komastudios/pico-emulator-builder:<BUILDER_KEY>` |
| compile | `task compile` | the source archive (`task sources:pull` fetches it) and `BUILDER_IMAGE` | `dist/picoemulator-<LOCK_KEY>.tar.zst` (+ `.tar.sha256`) |
| package | `task package PACKAGE=…` | the package archive | the `deploy` image and `dist/linux-pico-package` with `SHA256SUMS` |

`task lock:key` prints the keys. `LOCK_KEY` is a hash of the lock, the pins, the exclusion and trim rules and the sync/trim scripts, so any change to what the archive would contain names a new archive; `BUILDER_KEY` hashes the builder stage and the base image digest.

The sources stage removes what a Linux x86_64 host build never reads — `.repo` (39 GB of git objects), the guest system images, and the clang, Qt and dependency prebuilts for other hosts (`scripts/source-trim.txt`) — taking the tree from roughly 118 GB to 18 GB, then asserts that every input the build needs is still there (`scripts/source-required.txt`). The archive is a deterministic tar (sorted, fixed owner, mtimes at `SOURCE_DATE_EPOCH`); its identity is the sha256 of the uncompressed stream, since zstd output may vary between versions. Because object files embed their paths, the compile stage always unpacks it at `/cache/src`, exactly where a synced tree lives.

On a hosted runner the sync itself is the tight spot, because the trim only runs once everything has landed: a full checkout is ~116 GB of working tree and `.repo` objects, and the largest filesystem a runner offers is ~66 GB. Three things bring it down to ~52 GB, and none of them changes the archive, because everything they leave out is dropped by the trim anyway:

- `SYNC_DEPTH=1` (`repo init --depth=1`), which the workflow always passes. `SYNC_PARTIAL=1` (`--partial-clone --clone-filter=blob:none`) is available too but buys little here, since a checkout materialises the blobs regardless.
- `SYNC_GROUPS`, default `default,platform-linux`. The manifest groups the other-host prebuilts as `notdefault,platform-darwin` / `platform-windows`, so this fetches only the host the build targets — about 18 GB of clang, cmake, python and bazel trees and their objects.
- `scripts/source-exclude.txt`, a list of `<project name> <path>` pairs turned into a `<remove-project>` local manifest before the sync. It covers what carries no manifest group: the guest system images (41 GB with objects) and the Studio JDK. The sync recreates the directory each removed project would have left behind, so the trimmed tree is byte-for-byte what a full sync produces.

The lock assertion still holds: it names four projects, all of them synced, and `scripts/source-required.txt` fails the stage if a narrower sync ever drops something the build reads. `.pico-provenance` records the projects that were actually synced, so it is shorter than one from a full sync — the only part of the archive these settings change.

`.github/workflows/build.yml` runs on `workflow_dispatch` and on pushes to `main` that touch the lock, manifests, `Containerfile`, `Taskfile.yml` or `scripts/`. It resolves the keys, skips the sources and builder stages when their promotions already exist, compiles **twice on independent runners**, and compares the two packages with `task repro:check` — a cross-machine reproducibility check on every run. `scripts/ci-cleanup.sh` removes the preinstalled toolchains and puts the build cache on the runner's larger disk and container storage on the other, since the compile needs ~55 GB for the source tree and its build output. The dispatch inputs `sources_ref` and `builder_ref` re-run the later stages from a chosen promotion. `.github/workflows/ci.yml` runs `task verify` and `task lock:check` on every push and pull request.

### Branches and releases

| Branch | What `build.yml` does |
| --- | --- |
| any branch (`main` included) | one compile leg, package, `SHA256SUMS` — a build, not a proof |
| `snapshot` (protected) | two compile legs on independent runners; the package job fails unless `task repro:check` finds them byte-identical; only then `task release` assembles the archive and publishes it as a GitHub Release tagged `v0.<N>` |

`N` is the number of commits reachable from the released commit (`git rev-list --count HEAD`), the scheme ANGLE and Chromium use for build numbers: monotonic on a branch, no counter to store. The release archive `pico-emulator-linux-v0.<N>.tar.zst` is self-contained — `linux-pico-package/`, `scripts/install-pico-emulator.sh`, the systemd units, a README, a `RELEASE` provenance file (commit, manifest, epoch, lock key, every project commit) and a `SHA256SUMS` over all of it — and installs with nothing but tar, zstd and a shell:

```bash
tar --zstd -xf pico-emulator-linux-v0.42.tar.zst
cd pico-emulator-linux-v0.42 && sha256sum -c --quiet SHA256SUMS
sudo scripts/install-pico-emulator.sh          # reads /etc/pico-emulator/site.conf if present
```

`task release PACKAGE_DIR=dist/linux-pico-package` builds the same archive locally. A dispatch of `build.yml` with `run_second_build` and `publish` set does the same on any branch.

Measured on the first runs (2026-08-26, `ubuntu-24.04` runners, one 145 GB volume with ~118 GB free after `task ci:cleanup`): keys 14 s; builder 1 m 43 s including the push; sources 22 m (repo sync ~10 m, tar+zstd ~8.5 m, push 23 s; peak 53 GB); compile 1 h 03 m – 1 h 22 m per leg (archive pull 71 s, unpack 46 s, ninja ~1 h 18 m; peak 85 GB used). With the sources and builder promotions already present a push runs only the two compile legs and the package job. The hosted-runner binaries matched the local isolated-root builds hash for hash — see *Reproducibility status* in `MANIFEST.md`.

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
