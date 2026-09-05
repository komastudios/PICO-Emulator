# PICO Spatial Emulator on Linux — end-to-end container build.
#
# Stages:
#   base    common Debian 13 layer shared by builder and deploy
#   builder toolchain needed to sync and compile the PICO host
#   sources repo sync + trim; emits sources-<key>.tar.zst onto /cache
#   build   repo sync + rebuild.sh (or rebuild.sh from a promoted source
#           archive); emits the distribution tree to /out
#   import  unpacks a promoted picoemulator archive to /out instead of building
#   deploy  runtime image: built binaries + every runtime dependency
#
# `task build` runs builder -> build -> deploy in one go. The staged pipeline
# (task sources / compile / package, and the GitHub workflow) runs the same
# stages one at a time, promoting the archive between them.
#
# The image deliberately contains NO proprietary vendor blobs. The API 36
# guest image and any AVD data must be bind-mounted at runtime; see the
# "Runtime" notes at the bottom of this file and the Taskfile.
#
# Build cache: bind-mount a host directory at /cache (the Taskfile does this
# by default). The repo checkout lives there and is reused across builds — it
# is ~108 GB once synced. Without the mount the build still works, but nothing
# is reused and the source tree is removed before the layer is committed.

# Pinned by digest, not tag: a tag is mutable, and the toolchain layer it
# produces is an input to every binary this build emits.
ARG DEBIAN_IMAGE=docker.io/library/debian@sha256:abc9cb88a5587630d7f915f47b23b0668fe250fbfc6457aa4d52b534c1bbf73f
# A prebuilt builder image (by digest) lets the compile stage run without
# rebuilding the toolchain layer; the default is the local builder stage.
ARG BUILDER_IMAGE=builder
# Where the deploy stage takes the distribution tree from: the build stage,
# or "import" to use a promoted picoemulator archive from the build context.
ARG PACKAGE_STAGE=build

# ---------------------------------------------------------------- base ----
FROM ${DEBIAN_IMAGE} AS base
ENV DEBIAN_FRONTEND=noninteractive LANG=C.UTF-8
RUN rm -f /etc/apt/apt.conf.d/docker-clean && \
    printf 'Binary::apt::APT::Keep-Downloaded-Packages "true";\n' \
      > /etc/apt/apt.conf.d/keep-downloads

# ------------------------------------------------------------- builder ----
FROM base AS builder
# The `repo` tool lives in Debian's contrib component, which the slim image
# does not enable. Handle both the deb822 and the legacy sources format.
RUN if [ -f /etc/apt/sources.list.d/debian.sources ]; then \
      sed -i -E 's/^(Components:.*)$/\1 contrib/' /etc/apt/sources.list.d/debian.sources; \
    elif [ -f /etc/apt/sources.list ]; then \
      sed -i -E 's/^(deb .*[[:space:]]main)$/\1 contrib/' /etc/apt/sources.list; \
    else \
      echo "no apt sources found" >&2; exit 1; \
    fi
RUN --mount=type=cache,target=/var/cache/apt,sharing=locked \
    --mount=type=cache,target=/var/lib/apt/lists,sharing=locked \
    apt-get update && apt-get install -y --no-install-recommends \
      ca-certificates curl git git-lfs repo \
      build-essential cmake ninja-build pkg-config \
      python3 python3-venv \
      bison flex texinfo \
      zlib1g-dev libglib2.0-dev libpixman-1-dev libssl-dev \
      libx11-dev libxcb1-dev libxkbcommon-dev \
      rsync unzip xz-utils zstd file procps \
    && git lfs install --system

# repo refuses to run without an identity, and colour output corrupts logs.
RUN git config --system user.name  "PICO container build" && \
    git config --system user.email "build@localhost" && \
    git config --system color.ui false && \
    git config --system advice.detachedHead false

# ------------------------------------------------------------- sources ----
# Sync and trim only; the archive lands on the /cache mount, never in a layer.
FROM builder AS sources
ARG MANIFEST_URL=https://github.com/komastudios/PICO-Emulator-manifest.git
ARG MANIFEST_BRANCH=pico-linux
ARG MANIFEST_FILE=pico/emu-35-rom.xml
ARG JOBS=8
ARG CACHE_BUST=0
ARG MANIFEST_REV=
ARG LOCK_FILE=
ARG PINS_FILE=
ARG SOURCE_DATE_EPOCH=
ARG LOCK_KEY=
ARG SYNC_DEPTH=
ARG SYNC_PARTIAL=0
ARG ZSTD_LEVEL=12
ENV TZ=UTC LC_ALL=C LANG=C.UTF-8
COPY scripts/container-build.sh scripts/build-sync.sh scripts/build-trim.sh \
     scripts/source-trim.txt scripts/source-required.txt scripts/source-exclude.txt \
     /opt/pico/scripts/
COPY scripts/lib/build-env.sh /opt/pico/scripts/lib/build-env.sh
COPY manifests /opt/pico/manifests
COPY revisions.lock revisions-debug.lock /opt/pico/
COPY native/patch.lock /opt/pico/native/patch.lock
COPY patches/pico-native-automation.patch /opt/pico/patches/pico-native-automation.patch
COPY scripts/apply-native-patch.sh /opt/pico/scripts/apply-native-patch.sh
RUN chmod 0755 /opt/pico/scripts/*.sh
RUN MANIFEST_URL="${MANIFEST_URL}" \
    MANIFEST_BRANCH="${MANIFEST_BRANCH}" \
    MANIFEST_FILE="${MANIFEST_FILE}" \
    MANIFEST_REV="${MANIFEST_REV}" \
    LOCK_FILE="${LOCK_FILE}" \
    PINS_FILE="${PINS_FILE}" \
    SOURCE_DATE_EPOCH="${SOURCE_DATE_EPOCH}" \
    LOCK_KEY="${LOCK_KEY}" \
    SYNC_DEPTH="${SYNC_DEPTH}" \
    SYNC_PARTIAL="${SYNC_PARTIAL}" \
    ZSTD_LEVEL="${ZSTD_LEVEL}" \
    JOBS="${JOBS}" \
    CACHE_BUST="${CACHE_BUST}" \
    sh -c '/opt/pico/scripts/container-build.sh sync && /opt/pico/scripts/container-build.sh trim'

# ---------------------------------------------------------------- build ----
FROM ${BUILDER_IMAGE} AS build

# Which manifest to sync. The debug variant pins gfxstream to
# pico-linux-debug, which additionally dumps every SPIR-V shader module.
ARG MANIFEST_URL=https://github.com/komastudios/PICO-Emulator-manifest.git
ARG MANIFEST_BRANCH=pico-linux
ARG MANIFEST_FILE=pico/emu-35-rom.xml
ARG JOBS=8
# Bump to force a re-sync and rebuild even when the cache is warm.
ARG CACHE_BUST=0
# Reproducible sync. Empty means "follow MANIFEST_BRANCH"; the Taskfile fills
# these in from revisions.lock / manifests/pins.xml (see `task lock`).
ARG MANIFEST_REV=
ARG LOCK_FILE=
ARG PINS_FILE=
# Normalized build environment. SOURCE_DATE_EPOCH comes from the locked
# manifest commit, so __DATE__/__TIME__ and any timestamp the build embeds are
# a property of the reviewed source rather than of when it was compiled.
ARG SOURCE_DATE_EPOCH=
# "none" keeps compilation deterministic and avoids the bundled sccache 0.3.0;
# "auto" trades that for speed on development builds.
ARG COMPILER_CACHE=none
# Staged pipeline: a promoted source archive on /cache (from the sources
# stage) replaces the sync; LOCK_KEY must match the key recorded in it.
ARG SOURCE_ARCHIVE=
ARG LOCK_KEY=
# 1 deletes SOURCE_ARCHIVE once it is unpacked. The build writes ~37 GB of
# objects next to the 18 GB tree, which on a hosted runner leaves no room for
# the 5 GB archive as well.
ARG DISCARD_SOURCE_ARCHIVE=0
ENV TZ=UTC LC_ALL=C LANG=C.UTF-8

COPY scripts/container-build.sh scripts/build-sync.sh scripts/build-compile.sh \
     scripts/build-package.sh /opt/pico/scripts/
COPY scripts/lib/build-env.sh /opt/pico/scripts/lib/build-env.sh
COPY manifests /opt/pico/manifests
COPY revisions.lock revisions-debug.lock /opt/pico/
COPY native/patch.lock /opt/pico/native/patch.lock
COPY patches/pico-native-automation.patch /opt/pico/patches/pico-native-automation.patch
COPY scripts/apply-native-patch.sh /opt/pico/scripts/apply-native-patch.sh
RUN chmod 0755 /opt/pico/scripts/*.sh && \
    ln -sf /opt/pico/scripts/container-build.sh /usr/local/bin/container-build.sh

# The compiler cache is opt-in (COMPILER_CACHE); see build-compile.sh. The
# reuse that matters comes from the /cache bind mount (the repo checkout) and
# podman's own layer cache.
RUN MANIFEST_URL="${MANIFEST_URL}" \
    MANIFEST_BRANCH="${MANIFEST_BRANCH}" \
    MANIFEST_FILE="${MANIFEST_FILE}" \
    MANIFEST_REV="${MANIFEST_REV}" \
    LOCK_FILE="${LOCK_FILE}" \
    PINS_FILE="${PINS_FILE}" \
    SOURCE_DATE_EPOCH="${SOURCE_DATE_EPOCH}" \
    COMPILER_CACHE="${COMPILER_CACHE}" \
    SOURCE_ARCHIVE="${SOURCE_ARCHIVE}" \
    DISCARD_SOURCE_ARCHIVE="${DISCARD_SOURCE_ARCHIVE}" \
    LOCK_KEY="${LOCK_KEY}" \
    JOBS="${JOBS}" \
    CACHE_BUST="${CACHE_BUST}" \
    sh -c 'if [ -n "$SOURCE_ARCHIVE" ]; then \
             /opt/pico/scripts/container-build.sh compile && \
             /opt/pico/scripts/container-build.sh package; \
           else \
             /opt/pico/scripts/container-build.sh all; \
           fi'

# --------------------------------------------------------------- import ----
# Deploy from a promoted package archive instead of compiling: put
# picoemulator-<key>.tar.zst in the build context and pass
# --build-arg PACKAGE_STAGE=import --build-arg PICOEMULATOR_TAR=<path>.
FROM base AS import
ARG PICOEMULATOR_TAR=dist/picoemulator.tar.zst
RUN --mount=type=cache,target=/var/cache/apt,sharing=locked \
    --mount=type=cache,target=/var/lib/apt/lists,sharing=locked \
    apt-get update && apt-get install -y --no-install-recommends zstd
COPY ${PICOEMULATOR_TAR} /in/picoemulator.tar.zst
RUN mkdir -p /out && zstd -dc /in/picoemulator.tar.zst | tar -C /out -xf - && \
    test -x /out/picoemulator/emulator

# -------------------------------------------------------------- package ----
# Indirection so deploy can take the distribution tree from either `build`
# or `import` (PACKAGE_STAGE); a variable in FROM is reliable, one in
# COPY --from is not.
FROM ${PACKAGE_STAGE} AS package

# --------------------------------------------------------------- deploy ----
FROM base AS deploy

# The runtime set below was derived from `ldd` over every binary and shared
# object in a known-good distribution tree, with the bundled lib64, lib64/qt/lib
# and lib64/gles_angle_pico_linux directories on the search path, then resolved
# back to Debian packages. mesa-vulkan-drivers supplies lavapipe, the actual CPU
# rasteriser. libnss3/libnspr4 are not optional: qemu-system-x86_64 links them
# directly through Qt WebEngine.
#
# Two sonames remain deliberately unsatisfied because the verified reference
# host does not provide them either, and the emulator runs there:
#   libtiff.so.5  -> Qt's optional TIFF image-format plugin
#   libtinfo.so.5 -> lib64/gles_mesa/libGL.so, unused on the ANGLE/gfxstream path
# Debian 13 ships libtiff.so.6 and libtinfo.so.6; forcing the old sonames in
# would be a fabrication, not a fix.
RUN --mount=type=cache,target=/var/cache/apt,sharing=locked \
    --mount=type=cache,target=/var/lib/apt/lists,sharing=locked \
    apt-get update && apt-get install -y --no-install-recommends \
      libc6 libstdc++6 libgcc-s1 libffi8 libcap2 libdbus-1-3 libsystemd0 \
      libx11-6 libx11-xcb1 libxau6 libxcb1 libxdmcp6 libwayland-client0 \
      libxdamage1 libxfixes3 \
      libnss3 libnspr4 \
      libasyncns0 libflac14 libmp3lame0 libmpg123-0t64 libogg0 libopus0 \
      libpulse0 libsndfile1 libvorbis0a libvorbisenc2 \
      mesa-vulkan-drivers libvulkan1 \
      xvfb xauth x11-utils \
      adb rsync procps ca-certificates tini \
    && rm -rf /var/lib/apt/lists/*

ENV PICO_ROOT=/opt/android/PICO
ENV PACKAGE=${PICO_ROOT}/linux-pico-package

COPY --from=package /out/picoemulator ${PACKAGE}/picoemulator

# Repository-owned inputs (README section 5).
COPY config/avd-api36/Pico_36_Linux.avd/config.ini \
     ${PACKAGE}/avd-api36/Pico_36_Linux.avd/config.ini
COPY config/vulkan/vk_swiftshader_icd.json \
     ${PACKAGE}/picoemulator/lib64/vulkan/vk_swiftshader_icd.json
COPY scripts/start-pico-linux.sh scripts/wait-pico-display.sh \
     scripts/wait-pico-boot.sh ${PACKAGE}/
COPY scripts/container-entrypoint.sh /usr/local/bin/pico-entrypoint

RUN set -eux; \
    chmod 0755 ${PACKAGE}/*.sh /usr/local/bin/pico-entrypoint; \
    # ANDROID_EMU_VK_ICD=swiftshader selects this ICD slot; the JSON loads
    # Mesa lavapipe. The filename is deliberately misleading — see README.
    cp /usr/lib/x86_64-linux-gnu/libvulkan_lvp.so \
       ${PACKAGE}/picoemulator/lib64/vulkan/libvulkan_lvp.so; \
    # qemu-system-x86_64 links libnvidia-ml.so.1. The distribution ships a
    # compatibility blob without the SONAME symlink; provide it rather than
    # pulling an NVIDIA runtime into a CPU-only image.
    if [ -e ${PACKAGE}/picoemulator/lib64/libnvidia-ml.so ] && \
       [ ! -e ${PACKAGE}/picoemulator/lib64/libnvidia-ml.so.1 ]; then \
      ln -s libnvidia-ml.so ${PACKAGE}/picoemulator/lib64/libnvidia-ml.so.1; \
    fi; \
    install -d ${PICO_ROOT}/sdk; \
    ln -sfn ../linux-pico-package/picoemulator ${PICO_ROOT}/sdk/emulator; \
    install -d ${PICO_ROOT}/sdk/platform-tools; \
    ln -sfn /usr/lib/android-sdk/platform-tools/adb ${PICO_ROOT}/sdk/platform-tools/adb \
      || ln -sfn /usr/bin/adb ${PICO_ROOT}/sdk/platform-tools/adb; \
    install -d -m 0750 /var/lib/android /var/lib/android/tmp; \
    install -d -m 0700 /var/lib/android/.android

ENV PICO_STATE_DIR=/var/lib/android \
    PICO_SDK_ROOT=${PICO_ROOT}/sdk \
    PICO_GPU_MODE=angle_indirect \
    PICO_NO_WINDOW=0 \
    PICO_DISPLAY=:99 \
    PICO_SCREEN=2880x1440x24 \
    ANDROID_EMU_VK_ICD=swiftshader \
    ADB_MDNS_AUTO_CONNECT=0

VOLUME ["/var/lib/android"]
EXPOSE 5037 5554 5555

ENTRYPOINT ["/usr/bin/tini", "--", "/usr/local/bin/pico-entrypoint"]

# Runtime (see Taskfile `task run`):
#   podman run --rm --device /dev/kvm \
#     -v /path/to/system-images:${PACKAGE}/swan_rls_spaceos_oversea_K_pico_emulator_win64_20260731_ide/system-images/system-images:ro \
#     -v pico-state:/var/lib/android -p 5037:5037 <image>
# The guest image path is absolute because the AVD's image.sysdir.1 points at
# it; mounting it anywhere else requires editing config.ini.
