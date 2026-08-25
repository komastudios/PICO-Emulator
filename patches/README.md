# Patch inventory

These patches remain the authoritative record of the source modifications. Each is now **also** available as a branch on a fork — see **Sources** in `README.md`. Both routes produce identical trees; use whichever suits your workflow.

| Patch | Apply in | Base commit | Equivalent fork branch | Status |
| --- | --- | --- | --- | --- |
| `pico-emulator-qemu-linux.patch` | `external/qemu` | `8ca9387f0822db1cb0dfc8ba724db212084bb2df` | `komastudios/PICO-Emulator-qemu` @ `pico-linux` (`fe8473f9`) | Required |
| `pico-emulator-gfxstream-linux.patch` | `hardware/google/gfxstream` | `17b28f4e8c38b1aaadb620072786a0cbeba7362b` | `komastudios/PICO-Emulator-gfxstream` @ `pico-linux-debug` (`3d7006f8`) | Required |
| `pico-emulator-gfxstream-yuv-readback.patch` | `hardware/google/gfxstream` | `f7f8c7ec5e03b720c09e807b6e879248cfdc9969` (`pico-linux` tip) | `komastudios/PICO-Emulator-gfxstream` @ `pico-linux` (`c7cdba8b`), `pico-linux-debug` (`c4af3b55`) | Required — fixes the `rcReadColorBufferYUV` crash (gfxstream commit 8, see **Sources** in `README.md`) |
| `experimental-swiftshader.patch` | standalone upstream SwiftShader | `6b8d31709ad185dbd64e80865e830a9dbe8e7559` | `komastudios/swiftshader` @ `pico-linux` (`20fc43c1`) | Diagnostic only; do not deploy |

The required patches were captured directly from the source trees used to build the deployed binaries. Apply them with `git apply` as shown in the top-level README.

## The gfxstream patch maps to `pico-linux-debug`, not `pico-linux`

`pico-emulator-gfxstream-linux.patch` includes commit `3d7006f`, which dumps every SPIR-V shader module to `/var/lib/android/pico-shaders/` and logs descriptor-set bindings to stderr. That instrumentation is present in the deployed `libgfxstream_backend.so`, so the patch reproduces the deployed binary exactly — but it is not something you want to keep building.

- To reproduce the **deployed** binary: apply the patch, or check out `pico-linux-debug`.
- To build a **clean** host: check out `pico-linux`, or apply the patch and then revert `3d7006f`. The resulting `libgfxstream_backend.so` will not match the hash in `MANIFEST.md`.

## Commit structure on the forks

The two required patches are each split into logical commits on their branches, so individual changes can be reviewed, reverted, or rebased independently. The fork branches listed above carry every commit with its subject and files.
