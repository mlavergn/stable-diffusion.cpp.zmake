###############################################
#
# Makefile — stablediffusioncpp
#
# Zig build system for stable-diffusion.cpp. The sources are not modified:
# they are the `stablediffusion_cpp` and `ggml` packages in build.zig.zon,
# which zig build fetches on first use into zig-pkg/<hash>.
#
# `make cli` generates an SDXL image, `make web` serves SDXL over HTTP, and
# `make validate` (from the styleguide include) is the pre-commit gate.
#
# Conventions: UPPER_CASE variables are settings, overridable on the command
# line (`?=`); lower_case ones are internal helpers. Every target has a
# one-line comment, and each group declares its own .PHONY targets.
#
###############################################

# Optional include to extend the makefile targets
-include ../styleguide/Makefile.in

.DEFAULT_GOAL := all

# ---------------------------------------------
# Configuration: project
# ---------------------------------------------

# The only Zig sources this project owns, besides build.zig.
ZIG_DIRS := zig

# The released version, read from build.zig.zon (the source of truth).
VERSION := $(shell sed -n -E 's/^[[:space:]]*\.version[[:space:]]*=[[:space:]]*"([^"]+)".*/\1/p' build.zig.zon)

# Passed to every build. A Debug stable-diffusion.cpp is far too slow to
# generate with; override to build unoptimized, e.g. `make cli RELEASE=`.
RELEASE ?= --release=fast

# ---------------------------------------------
# Configuration: pinned sources
# ---------------------------------------------

# The pinned release tag, read back from its URL in build.zig.zon. Re-pin
# with `make pin SD_CPP_TAG=<tag>`.
SD_CPP_TAG ?= $(shell sed -n 's|.*stable-diffusion.cpp/archive/refs/tags/\(.*\)\.tar\.gz",$$|\1|p' build.zig.zon)

# A dependency's hash in build.zig.zon: $(call zon_hash,<name>).
zon_hash = $(shell sed -n '/\.$(1) = /,/\.hash/ s/.*\.hash = "\(.*\)",/\1/p' build.zig.zon)

# Where Zig unpacked a package (see build.zig, `Tree`): $(call pkg_dir,<hash>).
# Deferred, so a `make fetch` earlier in the same run is seen.
pkg_dir = $(abspath $(firstword $(patsubst %/CMakeLists.txt,%,$(wildcard zig-pkg/$(1)/CMakeLists.txt zig-pkg/$(1)/*/CMakeLists.txt))))

SD_CPP_DIR = $(call pkg_dir,$(call zon_hash,stablediffusion_cpp))
GGML_DIR   = $(call pkg_dir,$(call zon_hash,ggml))

# ---------------------------------------------
# Configuration: weights and generation
# ---------------------------------------------

# The weights `make models` downloads, from Hugging Face, without a login.
MODEL_URL ?= https://huggingface.co/gpustack/stable-diffusion-xl-base-1.0-GGUF/resolve/main/stable-diffusion-xl-base-1.0-Q8_0.gguf
VAE_URL   ?= https://huggingface.co/madebyollin/sdxl-vae-fp16-fix/resolve/main/sdxl_vae.safetensors

model_default := models/$(notdir $(MODEL_URL))
vae_default   := models/$(notdir $(VAE_URL))

# What `make cli`, `make web` and `make verify` use. The VAE is the fp16-fix
# one: SDXL's own produces NaNs in fp16.
MODEL  ?= $(model_default)
VAE    ?= $(vae_default)
PROMPT ?= a lovely cat
SEED   ?= 42
STEPS  ?= 20
WIDTH  ?= 1024
HEIGHT ?= 1024

# Where `make cli` writes its image, and how it shows it; OPEN=true skips that.
OUT  ?= out/sdxl.png
OPEN ?= $(if $(filter Darwin,$(shell uname -s)),open,xdg-open)

# Where `make web` listens (sd-server's own defaults).
WEB_HOST ?= 127.0.0.1
WEB_PORT ?= 1234

# ---------------------------------------------
# Configuration: reference and verification
# ---------------------------------------------

# The CMake reference build (`make ref`). Unless CMAKE names one, a pinned
# CMake from PyPI is installed into a virtual environment beside it.
REF_DIR       ?= .ref
REF           ?= $(REF_DIR)/build/bin/sd-cli
CMAKE_VERSION ?= 4.4.4
CMAKE         ?= $(cmake_venv)
cmake_venv    := $(REF_DIR)/venv/bin/cmake

# A bounded -j: CMake's Makefiles have hundreds of independent compiles.
JOBS ?= $(shell sysctl -n hw.logicalcpu 2>/dev/null || nproc 2>/dev/null || echo 4)

# The backends `make verify` compares, and where it keeps images and logs.
# Each backend is one full generation by both builds; the CPU one takes
# minutes at 1024x1024.
VERIFY_BACKENDS ?= metal cpu
VERIFY_DIR      ?= out/verify

# The arguments both builds run with, and each backend's --backend device.
verify_args         = -m "$(MODEL)" --vae "$(VAE)" -p "$(PROMPT)" -s $(SEED) --steps $(STEPS) \
                      -W $(WIDTH) -H $(HEIGHT) --auto-fit off --flash-attn off
verify_device_metal := MTL0
verify_device_cpu   := cpu

# ---------------------------------------------
# Configuration: cross-compilation
# ---------------------------------------------

# The Linux targets: CPU backend, baseline arm64, and x86_64 with AVX2 -- what
# CMake enables by default with GGML_NATIVE off.
LINUX_TARGET     ?= aarch64-linux-gnu
LINUX_X86_TARGET ?= x86_64-linux-gnu
X86_CPU          ?= x86_64_v3

# ---------------------------------------------
# Run
# ---------------------------------------------

.PHONY: all cli web run

# Build, format, and test.
all: build format test
	@echo "done"

# Generate an SDXL image with upstream's sd-cli, downloading the weights if
# missing, and open it, e.g.
#   make cli PROMPT="a lighthouse at dusk" SEED=7 OUT=out/lighthouse.png
cli: $(MODEL) $(VAE)
	zig build cli $(RELEASE)
	@mkdir -p "$(dir $(OUT))"
	zig-out/bin/sd-cli -m "$(MODEL)" --vae "$(VAE)" -p "$(PROMPT)" -s $(SEED) \
	  --steps $(STEPS) -W $(WIDTH) -H $(HEIGHT) -o "$(OUT)"
	$(OPEN) "$(OUT)"

# Serve SDXL with upstream's sd-server until interrupted. API only: the web
# UI is a submodule the tarball does not carry, so / answers with a status
# line. See examples/server/api.md in the sources (make srcdir), e.g.
#   curl -s http://127.0.0.1:1234/sdapi/v1/txt2img -d '{"prompt":"a cat"}'
web: $(MODEL) $(VAE)
	zig build server $(RELEASE)
	@echo "sd-server: http://$(WEB_HOST):$(WEB_PORT)  (Ctrl-C stops it)"
	zig-out/bin/sd-server -m "$(MODEL)" --vae "$(VAE)" -l $(WEB_HOST) --listen-port $(WEB_PORT)

# Run sd-cli with any arguments, e.g.
#   make run ARGS="-m models/x.gguf -p 'a cat' -o out/cat.png"
run:
	zig build run $(RELEASE) -- $(ARGS)

# ---------------------------------------------
# Build
# ---------------------------------------------

.PHONY: build dist lib server pixdiff

# Libraries, header, and sd-cli (built, not run).
build:
	zig build $(RELEASE)

# Build optimized for release (the default already is).
dist:
	zig build --release=fast

# ggml and libstable-diffusion, and stable-diffusion.h, into zig-out/.
lib:
	zig build lib $(RELEASE)

# sd-server, built only; `make web` runs it.
server:
	zig build server $(RELEASE)

# pixdiff, the image comparer `make verify` runs.
pixdiff:
	zig build pixdiff

# ---------------------------------------------
# Sources and weights
# ---------------------------------------------

.PHONY: fetch pin srcdir models

# Fetch the pinned sources ahead of time; every build does it too.
fetch:
	zig build --fetch

# Re-pin build.zig.zon to another release, and ggml to the commit it points
# its submodule at, e.g. `make pin SD_CPP_TAG=master-1100-abcdef0`.
#
# The release tarball does not carry its submodules, so the ggml commit is
# read from GitHub's contents API, as `git submodule status` would report it.
# build.zig derives every version string from the two URLs.
#
# Always `zig fetch --save`, never a bare `zig fetch`: under Zig 0.17 a
# tarball the bare form leaves in the global cache is later unpacked by
# `zig build` with its top-level directory kept, under a different hash.
pin:
	@sha=$$(curl -fsSL "https://api.github.com/repos/leejet/stable-diffusion.cpp/contents/ggml?ref=$(SD_CPP_TAG)" \
	  | sed -n 's/^ *"sha": "\([0-9a-f]\{40\}\)".*/\1/p' | head -1); \
	test -n "$$sha" || { echo "make pin: cannot read the ggml submodule commit for $(SD_CPP_TAG)"; exit 1; }; \
	zig fetch --save=stablediffusion_cpp "https://github.com/leejet/stable-diffusion.cpp/archive/refs/tags/$(SD_CPP_TAG).tar.gz" && \
	zig fetch --save=ggml "https://github.com/leejet/ggml/archive/$$sha.tar.gz" && \
	echo "pinned stable-diffusion.cpp $(SD_CPP_TAG), ggml $$(echo $$sha | cut -c1-7)"

# Print the pinned sources' directories, for a CMake build of the same bytes.
srcdir: fetch
	@echo "$(SD_CPP_DIR)"
	@echo "$(GGML_DIR)"

# Download the default weights into models/ when missing.
models: $(model_default) $(vae_default)

# Download $(1) to $(2), resuming a partial .part file and renaming it only
# once complete.
define download
	@mkdir -p "$(dir $(2))"
	curl -L --fail -C - -o "$(2).part" "$(1)"
	mv "$(2).part" "$(2)"
endef

# The SDXL model.
$(model_default):
	$(call download,$(MODEL_URL),$@)

# The fp16-fix VAE.
$(vae_default):
	$(call download,$(VAE_URL),$@)

# ---------------------------------------------
# Verification
# ---------------------------------------------

.PHONY: ref verify verify-build

# The CMake reference sd-cli, from the same pinned sources, into $(REF_DIR).
# The -D flags are the configuration build.zig reproduces: Metal with its
# shaders embedded, Accelerate, no BLAS or OpenMP, the CPU baseline rather
# than the host's features, static libraries, and WebP/WebM off (their
# submodules are not in the tarball; CMake turns them off there too).
ref: fetch $(if $(filter $(cmake_venv),$(CMAKE)),$(cmake_venv))
	@test "$$(uname -s)" = Darwin || { echo "make ref: the reference is the macOS one (Metal, Accelerate)"; exit 1; }
	@mkdir -p "$(REF_DIR)/build"
	cd "$(REF_DIR)/build" && "$(abspath $(CMAKE))" "$(SD_CPP_DIR)" -G "Unix Makefiles" \
	  -DCMAKE_SYSTEM_NAME=Darwin -DCMAKE_OSX_SYSROOT=macosx \
	  -DCMAKE_OSX_ARCHITECTURES=arm64 -DCMAKE_OSX_DEPLOYMENT_TARGET=13.0 \
	  -DCMAKE_BUILD_TYPE=Release -DSD_GGML_SOURCE_DIR="$(GGML_DIR)" \
	  -DSD_METAL=ON -DSD_WEBP=OFF -DSD_WEBM=OFF \
	  -DGGML_METAL_EMBED_LIBRARY=ON -DGGML_ACCELERATE=ON -DGGML_BLAS=OFF \
	  -DGGML_OPENMP=OFF -DGGML_NATIVE=OFF -DBUILD_SHARED_LIBS=OFF
	$(MAKE) -C "$(REF_DIR)/build" -j$(JOBS) sd-cli

# A pinned CMake from PyPI, in a virtual environment.
$(cmake_venv):
	python3 -m venv "$(REF_DIR)/venv"
	"$(REF_DIR)/venv/bin/pip" install --quiet --disable-pip-version-check cmake==$(CMAKE_VERSION)

# This build's images against the reference's, pixel by pixel, once per
# backend in VERIFY_BACKENDS. REF defaults to `make ref`'s sd-cli.
#
# sd-cli decides three things at run time from timings and free memory: flash
# attention (`auto` benchmarks both kernels), the backend each module runs on,
# and where weights live (`--auto-fit`). Any of them flips between two runs
# of the same binary, so all three are pinned (verify_args, --backend).
#
# PNGs are never compared as bytes: their metadata holds sd-cli's version,
# which differs between the builds by design. pixdiff compares the pixels and
# fails on a missing or unreadable image.
verify: $(addprefix verify-,$(VERIFY_BACKENDS))
	@echo "verify: $(VERIFY_BACKENDS) matched; outputs in $(VERIFY_DIR)"

# One backend, e.g. `make verify-metal`: both builds generate, then pixdiff.
verify-%: verify-build
	@test -n "$(verify_device_$*)" || { echo "make verify: unknown backend '$*' (metal, cpu)"; exit 2; }
	@mkdir -p "$(VERIFY_DIR)"
	@echo "verify $*: reference"
	@"$(REF)" $(verify_args) --backend $(verify_device_$*) -o "$(VERIFY_DIR)/$*.ref.png" > "$(VERIFY_DIR)/$*.ref.log" 2>&1 \
	  || { tail -3 "$(VERIFY_DIR)/$*.ref.log"; echo "make verify: $*: the reference sd-cli failed"; exit 1; }
	@echo "verify $*: this build"
	@zig-out/bin/sd-cli $(verify_args) --backend $(verify_device_$*) -o "$(VERIFY_DIR)/$*.test.png" > "$(VERIFY_DIR)/$*.test.log" 2>&1 \
	  || { tail -3 "$(VERIFY_DIR)/$*.test.log"; echo "make verify: $*: sd-cli failed"; exit 1; }
	@zig-out/bin/pixdiff "$(VERIFY_DIR)/$*.ref.png" "$(VERIFY_DIR)/$*.test.png" \
	  || { echo "make verify: $*: the images differ"; exit 1; }
	@echo "SAME  $*  $(WIDTH)x$(HEIGHT), $(STEPS) steps, seed $(SEED)"

# What every verify-<backend> needs first: the weights, the reference, and
# this build's sd-cli and pixdiff.
verify-build: $(MODEL) $(VAE)
	@test -x "$(REF)" || { echo "make verify: no reference sd-cli at $(REF); run 'make ref', or pass REF=<binary>"; exit 1; }
	zig build cli pixdiff $(RELEASE)

# ---------------------------------------------
# Cross-compilation
# ---------------------------------------------

.PHONY: linux linux-x86_64 targets

# sd-cli for Linux arm64, under a prefix of its own.
linux:
	zig build cli -Dtarget=$(LINUX_TARGET) $(RELEASE) --prefix zig-out/linux

# sd-cli for Linux x86_64, under a prefix of its own.
linux-x86_64:
	zig build cli -Dtarget=$(LINUX_X86_TARGET) -Dcpu=$(X86_CPU) $(RELEASE) --prefix zig-out/linux-x86_64

# List every target Zig can build for.
targets:
	zig targets

# ---------------------------------------------
# Test
# ---------------------------------------------

.PHONY: test

# Run the unit test suite.
test:
	zig build test --summary all

# ---------------------------------------------
# Release
# ---------------------------------------------

.PHONY: tag

# Tag the build.zig.zon version (e.g. 1.0.0) and push it.
tag:
	@test -n "$(VERSION)" || { echo "make tag: cannot read .version from build.zig.zon"; exit 1; }
	git tag -a "$(VERSION)" -m "$(VERSION)"
	git push
	git push --tags

# ---------------------------------------------
# Environment
# ---------------------------------------------

.PHONY: st open github clone claude

# Open the working copy in SourceTree.
st:
	open -a SourceTree .

# Open the project in the editor.
open:
	code .

# Open the repository on GitHub.
github:
	open "https://github.com/mlavergn/stablediffusioncpp"

# Clone a fresh working copy.
clone:
	git clone git@github.com:mlavergn/stablediffusioncpp.git

# Start Claude Code here.
claude:
	claude

# ---------------------------------------------
# Housekeeping
# ---------------------------------------------

.PHONY: clean distclean

# Remove build output. The sources, weights and reference build stay.
clean:
	rm -rf .zig-cache zig-out

# Also remove the fetched sources, the reference build and generated images.
# The weights in models/ stay; they are large and change only with MODEL_URL.
distclean: clean
	rm -rf zig-pkg "$(REF_DIR)" out
