# Reproducibility manifest

This file separates repository-owned configuration from proprietary/large inputs and records the known-good deployment precisely.

## Source revisions

- Manifest (original): `https://github.com/Pico-Developer/PICO-Emulator-manifest.git`, `pico/emu-35-rom.xml`
- Manifest (forked, current): `https://github.com/komastudios/PICO-Emulator-manifest.git`, branch `pico-linux`, `pico/emu-35-rom.xml` (or `pico/emu-35-rom-debug.xml`), tip `e018335`
- PICO qemu base: `8ca9387f0822db1cb0dfc8ba724db212084bb2df`
- PICO gfxstream base: `17b28f4e8c38b1aaadb620072786a0cbeba7362b`
- Experimental upstream SwiftShader base: `6b8d31709ad185dbd64e80865e830a9dbe8e7559` (not deployed)
- Reported deployed host: PICO Emulator 0.7.6, build ID 2608240227, upstream base 33.1.16

The modifications on top of those bases are maintained as fork branches on the `komastudios` forks listed under **Sources** in the [README](README.md); the branch tips below are the authoritative record.

| Component | Fork branch | Tip | Reproduces the deployed binary |
| --- | --- | --- | --- |
| qemu | `komastudios/PICO-Emulator-qemu` @ `pico-linux` | `b461fb8c` | Yes |
| gfxstream | `komastudios/PICO-Emulator-gfxstream` @ `pico-linux-debug` | `43ddfc66` | No — the recorded hashes predate commit `43ddfc66`; `3d7006f8` reproduces them |
| gfxstream | `komastudios/PICO-Emulator-gfxstream` @ `pico-linux` | `f7f8c7ec` | **No** — see below; the recorded container-build hash predates commit `f7f8c7ec` |
| SwiftShader | `komastudios/swiftshader` @ `pico-linux` | `20fc43c1` | Not deployed |

## External archive hashes

| Archive | SHA-256 | Role |
| --- | --- | --- |
| `pico_emulator_oversea_20260731_v6.0.0_win.zip` | `61efdf8191ee09e65d75edd3c180b74b83544cd7146a8403bac28c5d15bd2f1c` | Required API 36 guest image; global download URL is recorded in README |
| `pico_emulator_oversea_20260731_v6.0.0_mac.zip` | `474de313628a3d282940abe0f0f9f4961a18404ea6a8d3ebdc7fad7cb3723fe3` | Cross-check only |
| `PICOSpatial(Global)-v6.0.0-release.zip` | `677b1a88e9383b4a8794787829be4bb0d4c5cea9a55f3f18ff850bc23cb9a4a7` | Led to package discovery; not needed at runtime |
| `sparrow_rls_oversea_K_pico_emulator_win64_20250924.zip` | `09781abd181335c0c1dfb8e1fbf1a0e266af33b9b06752c0891f60f6890bc23a` | Superseded API 34 experiment |
| `picoemulatormac_0.8.3.zip` | `38cfbe062b3dce7cdb891e71379c6cddc8d26a8f9d79ace3084f038f2ac113ce` | Superseded experiment |

The archives and extracted images are intentionally absent because they are large vendor artifacts and may not be redistributable.

## Required API 36 image hashes

Relative to `swan_rls_spaceos_oversea_K_pico_emulator_win64_20260731_ide/system-images/system-images/`:

| File | SHA-256 |
| --- | --- |
| `kernel-ranchu` | `5ef699474b9b6dc6ea48b738344d73faf3726c477e67b06f89e1da2d9f642a7d` |
| `ramdisk.img` | `fad908e176aea905143a72d2736eab6f302ad827a77315fcd5b626c43cd2729b` |
| `system.img` | `d3e45bf72e9e37aa66ccfde5355e8358ce97c4458b7307df30e3b2ba923dcfb7` |
| `vendor.img` | `fb2434a1e625943e5c0080d26baf0956c957f9f6ecb7cd887f9ab677bfc4946a` |

Its `source.properties` reports API 36, extension 17, x86_64, revision 2.

## Known-good artifact hashes — original hand-built deployment (superseded)

These document the first working deployment, built by hand from the dirty source trees. **The host no longer runs these binaries**; see "Currently deployed" below.

| Relative path under `/opt/android/PICO/linux-pico-package` | SHA-256 |
| --- | --- |
| `picoemulator/emulator` | `2a350e61b159239266d1f49fa9027a8cd3eedf29ded3a52474b64da8eae558c4` |
| `picoemulator/qemu/linux-x86_64/qemu-system-x86_64` | `aede972e65b7c3c67da5c581dae24c26b71d72c683efda5ec089ae9acdda18d3` |
| `picoemulator/lib64/libgfxstream_backend.so` | `fe5e19c8f34e42b6794c8ecc144828ddf38bc39925d2558b3d994a76255a6293` |
| `picoemulator/lib64/vulkan/libvulkan_lvp.so` | `0004262f4dc95585492d55925face67a79a7c869ad8760b42ae01bd0bdb807a2` |

The lavapipe hash is distro-build-specific. A different supported Mesa build need not match if it exposes at least eight bound descriptor sets and `shaderInt64`.

> **The `libgfxstream_backend.so` hash belongs to `pico-linux-debug`, not `pico-linux`.** The deployed library was built from a tree that still contained the SPIR-V shader-dumping instrumentation (gfxstream commit `3d7006f`), which writes every shader module to `/var/lib/android/pico-shaders/` and logs descriptor-set bindings to stderr. That commit is present in `patches/pico-emulator-gfxstream-linux.patch` and on the `pico-linux-debug` branch; it is deliberately absent from `pico-linux`.
>
> - Building from `pico-linux-debug` or applying the patch reproduces `fe5e19c8f34e42b6794c8ecc144828ddf38bc39925d2558b3d994a76255a6293`.
> - Building from `pico-linux` produces a clean host with a different hash.
>
> **The host has since been moved to `pico-linux`.** The current binaries are in "Currently deployed artifacts" below, and a rendered cold boot was verified against them. The hash above now describes only the superseded build.

## Currently deployed artifacts (container build, `pico-linux`)

Built by `task build` from the forked manifest `pico/emu-35-rom.xml` on Debian 13 and installed with `scripts/install-pico-emulator.sh`. This is what the host runs now. Rebuilt 2026-08-25 from gfxstream `pico-linux` @ `c7cdba8b` (the YUV readback crash fix); `libgfxstream_backend.so` now has Build ID `09f3c1b841357837d86fe5f8652c13d20c07e3c5`. `emulator` and `qemu-system-x86_64` also changed hash: the cache-busted rebuild recompiled the whole tree and these binaries are not bit-reproducible across builds, even though no source of theirs changed. Only lavapipe, copied in verbatim by the deploy stage, is unchanged. A rebuild needs `make CACHE_BUST=$(date +%s) build` — without it podman reuses the cached build layer and silently ships the previous library.

| Relative path under `picoemulator/` | SHA-256 |
| --- | --- |
| `emulator` | `374306fc2ffd100942dac348786a4fe9e32390d17ba9bf2d6b6d8158948795bf` |
| `qemu/linux-x86_64/qemu-system-x86_64` | `72a9faf22107f16574a4c2d807c3a0a4d74c017c4b01b3848392f8f032375be5` |
| `lib64/libgfxstream_backend.so` | `d86f223336fd960345c0fdafa2f9a63b288b13f39326e7546752b96907c0c1f8` |
| `lib64/vulkan/libvulkan_lvp.so` | `0004262f4dc95585492d55925face67a79a7c869ad8760b42ae01bd0bdb807a2` |

The lavapipe hash is unchanged — it is the distribution's own Mesa build, copied in by the deploy stage.

**These hashes are a record, not an acceptance test.** The emulator embeds a timestamped build ID (this one reports `0.7.6.0 (build_id 2608241632)`), so a rebuild produces different hashes by construction. Accept a container build with the functional checks in the clean-room checklist, not hash equality.

### Verified after installation

Cold restart of all three units, then:

- `adb devices -l` shows `emulator-5554  device product:swan_oversea model:swan_oversea_x86_64`
- `sys.boot_completed = 1`
- Renderer reported by the emulator: `ANGLE (Mesa, Vulkan 1.4.305 (llvmpipe (LLVM 19.1.7 256 bits)))` — the intended PICO ANGLE/gfxstream → Vulkan loader → lavapipe path
- Guest screenshot shows the furnished Spatial home with the status bar and all five launcher labels

**This settles the instrumentation question.** The deployed gfxstream is now built from `pico-linux`, without the SPIR-V shader-dumping commit, and the scene renders correctly. The instrumentation was never required for rendering; `pico-linux-debug` is needed only to reproduce the original binary's hash.

`picoemulator/lib64/gles_angle_pico_linux/` is not produced by the build. It is a verbatim copy of `prebuilts/android-emulator-build/common/ANGLE/linux-x86_64/lib/`, which `container-build.sh` places into the distribution because `pico-emulator.service` puts that directory on `LD_LIBRARY_PATH` and `PICO_GPU_MODE=angle_indirect` needs the ANGLE GLES libraries in it. Its `libEGL.so`, `libGLESv2.so`, `libGLESv1_CM.so`, `libangle_st.so` and `libshadertranslator.so` are byte-identical to the deployed copies.

Verified against this image: lavapipe loads through the packaged ICD and reports `maxBoundDescriptorSets = 8` and `shaderInt64 = true` on `llvmpipe`, Mesa 25.0.7-2+deb13u1, LLVM 19.1.7. The only unresolved sonames are `libtiff.so.5` (Qt's optional TIFF plugin) and `libtinfo.so.5` (`lib64/gles_mesa/libGL.so`, unused on the ANGLE/gfxstream path); the reference host provides neither and runs correctly.

## Known host versions

The verified Debian 13 host used:

- `mesa-vulkan-drivers 25.0.7-2+deb13u1`
- `xvfb 2:21.1.16-1.3+deb13u3`
- `xauth 1:1.1.2-1.1`
- `x11-utils 7.7+7`
- `rsync 3.4.1+ds1-5+deb13u4`
- Android platform-tools/ADB 36.0.2-14143358
- LLVM 19.1.7 as the lavapipe backend

Lavapipe remains dynamically dependent on the distribution's LLVM, DRM, XCB, Wayland, compression, XML, and C/C++ runtime libraries; copying only `libvulkan_lvp.so` does not make it libc-independent.

## Repository-to-deployment mapping

- `patches/`: exact source modifications, mirrored as fork branches (see **Sources** in the [README](README.md))
- `Containerfile`, `.containerignore`, `Taskfile.yml`: end-to-end container build; the deploy image contains the built binaries and runtime dependencies but no vendor blobs
- `scripts/install-pico-emulator.sh`: idempotent host installer for the extracted package, its service user, and the three systemd units
- `scripts/`: copied to `linux-pico-package/`
- `config/avd-api36/`: immutable AVD seed copied to the package
- `config/vulkan/`: lavapipe ICD copied to the package
- `config/vendor-metadata/`: reference metadata from the vendor/build package
- `systemd/`: installed in `/etc/systemd/system/`

The SDK layout is deliberate: `/opt/android/PICO/sdk/platform-tools` is a normal Android SDK package, while `/opt/android/PICO/sdk/emulator` is a symlink to `../linux-pico-package/picoemulator`. This ensures `emulator-check` and `emulator` both come from the rebuilt PICO distribution.

## Clean-room acceptance checklist

1. Verify the vendor archive hash before extraction.
2. Sync the forked manifest (`repo init -b pico-linux -m pico/emu-35-rom.xml`), or verify the base commits and apply both required patches with no rejects. Note which gfxstream branch you chose — it determines whether step 3's output matches the recorded `libgfxstream_backend.so` hash.
3. Build a complete `objs/distribution/picoemulator` tree.
4. Assemble only immutable inputs under `/opt/android/PICO`; keep AVD, keys, temp files, and runtime configuration under `/var/lib/android`.
5. Confirm `sdk/emulator` resolves to the packaged PICO emulator and `sdk/platform-tools/adb` is executable.
6. Confirm the service user has KVM access and all three units start.
7. Confirm ADB is online and `sys.boot_completed=1`.
8. Capture a guest screenshot after a cold boot. Reject black HUD and loading-ring-only states.
9. Confirm the scene includes the Spatial environment and launcher labels.
10. Reboot the host once and repeat steps 6–9.
