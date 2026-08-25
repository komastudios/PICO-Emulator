# PICO Spatial Emulator for Linux

Builds the PICO OS 6 Spatial emulator host (PICO's Android-emulator fork) for Linux x86_64, CPU-rendered through ANGLE/gfxstream → Vulkan → Mesa lavapipe, and packages it for a headless systemd deployment.

The repository contains only build recipes, scripts and configuration. It ships **no** proprietary PICO content: the guest system image must be obtained from PICO and is bind-mounted at runtime.

## Required proprietary input

`pico_emulator_oversea_20260731_v6.0.0_win.zip` from
`https://lf-developer.picovr.com/obj/spatial-toolbox-mycis/oversea/emulator/pico_emulator_oversea_20260731_v6.0.0_win.zip`
(SHA-256 `61efdf8191ee09e65d75edd3c180b74b83544cd7146a8403bac28c5d15bd2f1c`). Only its API 36 guest image (`…/system-images/system-images/`) is used; the Windows host binaries are not.

## Quick start

```bash
task                 # list tasks
task build           # sync + compile + deploy image + extract to dist/
sudo task install    # install the extracted package and systemd units on this host
task run SYSTEM_IMAGES=/path/to/system-images
```

See [docs/build-pipeline.md](docs/build-pipeline.md) and [docs/host-install.md](docs/host-install.md).

## Sources

- Manifest: <https://github.com/komastudios/PICO-Emulator-manifest> (branch `pico-linux`)
- qemu fork: <https://github.com/komastudios/PICO-Emulator-qemu> (`pico-linux`)
- gfxstream fork: <https://github.com/komastudios/PICO-Emulator-gfxstream> (`pico-linux`, `pico-linux-debug`)
- Upstream: <https://github.com/Pico-Developer/PICO-Emulator-manifest>
