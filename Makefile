# Build the PICO Spatial Emulator container with podman.
#
#   make                 build the normal (non-debug) image, then extract it
#   make debug           build the debug variant (gfxstream pico-linux-debug)
#   make DEBUG=1         same as `make debug`
#   make extract         copy the built package out of the image into ./dist
#   make install         extract, then run the host installer (needs root)
#   make run             run the image (needs the guest image, see below)
#   make shell           interactive shell in the built image
#   make cache-info      show the size of the local build cache
#   make clean-cache     delete the local build cache
#   make clean           remove the built image
#
# On a host whose rootless podman has no systemd user session, prepend:
#   make PODMAN_FLAGS="--cgroup-manager=cgroupfs --events-backend=file"
#
# Repeated builds reuse $(CACHE_DIR), which holds the repo checkout (~108 GB
# once synced). The first build syncs it; later builds reuse it. Combined with
# podman's layer cache, a rebuild that only changes the deploy stage takes
# under a minute.

PODMAN        ?= podman
# Extra global podman flags, before the subcommand. Some sandboxed or
# non-systemd environments need e.g. --cgroup-manager=cgroupfs
PODMAN_FLAGS  ?=
IMAGE         ?= localhost/pico-emulator
CACHE_DIR     ?= $(CURDIR)/.cache
# Where `make extract` writes the deployable package. Named dist/ because its
# contents are exactly the distribution tree the build calls
# objs/distribution/picoemulator, plus the repository-owned scripts and seed.
DIST_DIR      ?= $(CURDIR)/dist
JOBS          ?= $(shell nproc)
DEBIAN_IMAGE  ?= docker.io/library/debian:13-slim

MANIFEST_URL    ?= https://github.com/komastudios/PICO-Emulator-manifest.git
MANIFEST_BRANCH ?= pico-linux

# Guest image directory to bind-mount for `make run`. Must be the extracted
# system-images directory from the vendor archive; see README.md section 1.
SYSTEM_IMAGES ?=
STATE_VOLUME  ?= pico-emulator-state

# DEBUG selects the manifest variant and the image tag.
DEBUG ?= 0
ifeq ($(DEBUG),1)
  MANIFEST_FILE ?= pico/emu-35-rom-debug.xml
  TAG           ?= debug
else
  MANIFEST_FILE ?= pico/emu-35-rom.xml
  TAG           ?= latest
endif

# Bump to force a re-sync and recompile even with a warm cache.
CACHE_BUST ?= 0

# Extra flags, e.g. make BUILD_FLAGS=--no-cache
BUILD_FLAGS ?=

GUEST_MOUNT = /opt/android/PICO/linux-pico-package/swan_rls_spaceos_oversea_K_pico_emulator_win64_20260731_ide/system-images/system-images

.PHONY: all build debug extract install run shell cache-info clean-cache clean config help

all: build

## Build the image. Uses $(CACHE_DIR) as a persistent build cache.
build: | $(CACHE_DIR)
	$(PODMAN) $(PODMAN_FLAGS) build \
	  --file Containerfile \
	  --target deploy \
	  --tag $(IMAGE):$(TAG) \
	  --volume $(CACHE_DIR):/cache:z \
	  --build-arg DEBIAN_IMAGE=$(DEBIAN_IMAGE) \
	  --build-arg MANIFEST_URL=$(MANIFEST_URL) \
	  --build-arg MANIFEST_BRANCH=$(MANIFEST_BRANCH) \
	  --build-arg MANIFEST_FILE=$(MANIFEST_FILE) \
	  --build-arg JOBS=$(JOBS) \
	  --build-arg CACHE_BUST=$(CACHE_BUST) \
	  $(BUILD_FLAGS) \
	  .
	@printf '\nBuilt %s:%s (manifest %s)\n' '$(IMAGE)' '$(TAG)' '$(MANIFEST_FILE)'
	@$(MAKE) --no-print-directory extract

## Copy the deployable package out of the built image into $(DIST_DIR).
## Runs automatically at the end of `make build`.
extract:
	@command -v $(PODMAN) >/dev/null || { echo "podman not found" >&2; exit 1; }
	@$(PODMAN) $(PODMAN_FLAGS) image exists $(IMAGE):$(TAG) || \
	  { echo "image $(IMAGE):$(TAG) not found; run 'make build' first" >&2; exit 1; }
	@rm -rf $(DIST_DIR)/linux-pico-package
	@mkdir -p $(DIST_DIR)
	@cid=$$($(PODMAN) $(PODMAN_FLAGS) create $(IMAGE):$(TAG)) && \
	  trap "$(PODMAN) $(PODMAN_FLAGS) rm -f $$cid >/dev/null 2>&1" EXIT && \
	  $(PODMAN) $(PODMAN_FLAGS) cp \
	    $$cid:/opt/android/PICO/linux-pico-package $(DIST_DIR)/linux-pico-package && \
	  $(PODMAN) $(PODMAN_FLAGS) rm -f $$cid >/dev/null
	@printf '%s\n' '$(TAG)' > $(DIST_DIR)/linux-pico-package/.build-variant
	@cd $(DIST_DIR)/linux-pico-package && sha256sum \
	  picoemulator/emulator \
	  picoemulator/qemu/linux-x86_64/qemu-system-x86_64 \
	  picoemulator/lib64/libgfxstream_backend.so \
	  picoemulator/lib64/vulkan/libvulkan_lvp.so > SHA256SUMS
	@printf 'Extracted to %s (%s)\n' '$(DIST_DIR)/linux-pico-package' \
	  "$$(du -sh $(DIST_DIR)/linux-pico-package | cut -f1)"
	@cat $(DIST_DIR)/linux-pico-package/SHA256SUMS

## Install the extracted package onto this host (systemd units, android user).
## Requires root; re-running is safe and only updates what changed.
install: extract
	sudo scripts/install-pico-emulator.sh --source $(DIST_DIR)/linux-pico-package

## Build the debug variant: gfxstream pinned to pico-linux-debug, which dumps
## every SPIR-V shader module to /var/lib/android/pico-shaders/.
debug:
	$(MAKE) build DEBUG=1

$(CACHE_DIR):
	mkdir -p $@

## Run the emulator. Requires SYSTEM_IMAGES to point at the extracted
## proprietary guest image; the container ships none.
run:
ifeq ($(strip $(SYSTEM_IMAGES)),)
	$(error SYSTEM_IMAGES is not set. Pass the extracted system-images directory, e.g. make run SYSTEM_IMAGES=/srv/pico/system-images)
endif
	$(PODMAN) $(PODMAN_FLAGS) run --rm -it \
	  --device /dev/kvm \
	  --volume $(SYSTEM_IMAGES):$(GUEST_MOUNT):ro,z \
	  --volume $(STATE_VOLUME):/var/lib/android:z \
	  --publish 5037:5037 \
	  $(IMAGE):$(TAG)

## Interactive shell in the built image, for inspecting the distribution.
shell:
	$(PODMAN) $(PODMAN_FLAGS) run --rm -it --entrypoint /bin/bash $(IMAGE):$(TAG)

## Show what the build cache is holding.
cache-info:
	@if [ -d $(CACHE_DIR) ]; then \
	  du -sh $(CACHE_DIR) 2>/dev/null; \
	  du -sh $(CACHE_DIR)/* 2>/dev/null || true; \
	else \
	  echo "no cache at $(CACHE_DIR)"; \
	fi

## Delete the build cache. The next build re-syncs from scratch.
clean-cache:
	rm -rf $(CACHE_DIR)

clean:
	-$(PODMAN) $(PODMAN_FLAGS) rmi $(IMAGE):$(TAG)
	rm -rf $(DIST_DIR)

## Print the resolved configuration without building.
config:
	@printf '%-16s %s\n' \
	  PODMAN          '$(PODMAN) $(PODMAN_FLAGS)' \
	  IMAGE           '$(IMAGE):$(TAG)' \
	  DEBUG           '$(DEBUG)' \
	  MANIFEST_URL    '$(MANIFEST_URL)' \
	  MANIFEST_BRANCH '$(MANIFEST_BRANCH)' \
	  MANIFEST_FILE   '$(MANIFEST_FILE)' \
	  CACHE_DIR       '$(CACHE_DIR)' \
	  JOBS            '$(JOBS)' \
	  DEBIAN_IMAGE    '$(DEBIAN_IMAGE)' \
	  DIST_DIR        '$(DIST_DIR)' \
	  SYSTEM_IMAGES   '$(SYSTEM_IMAGES)'

help:
	@grep -B1 -E '^[a-z-]+:' $(MAKEFILE_LIST) | grep -E '^(##|[a-z-]+:)' | \
	  sed -e 's/^## //' -e 's/:.*//' | paste - - 2>/dev/null || \
	  grep -E '^[a-z-]+:' $(MAKEFILE_LIST) | cut -d: -f1
