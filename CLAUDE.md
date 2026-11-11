# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project

**Replace stable-diffusion.cpp's CMake build with `build.zig`. Nothing else.**

Upstream sources (leejet/stable-diffusion.cpp and its `ggml` submodule, leejet's patched fork) are compiled exactly as shipped: no porting to Zig, no bug fixes, no behaviour changes, no Zig wrapper. The outputs are upstream's own `sd-cli`, `sd-server` and libraries. A binary built here must generate **pixel-identical images** to the same sources built by CMake (`make verify`). `README.md` is the user-facing overview; this file holds the implementation.

Sibling reference for the recipe: `../llama.cpp.zmake`. Requires Zig **0.17.0** and, on macOS, Xcode. Targets: macOS arm64 (Metal + CPU, verified); Linux aarch64 / x86_64 (CPU, cross-compiled, not run).

## Commands

```sh
make validate                 # pre-commit gate: clean, format, lint, build, test
make cli                      # build sd-cli, generate SDXL -> out/sdxl.png, open it (PROMPT=, SEED=, OUT=, OPEN=true, ...)
make web                      # build + run sd-server with SDXL on 127.0.0.1:1234 (API only)
make build | lib | server     # build only: zig build [<step>] $(RELEASE)
make run ARGS="..."           # zig build run -- $(ARGS)
make ref                      # CMake reference sd-cli into .ref/build (cmake from PyPI in .ref/venv)
make verify | verify-metal    # pixel-compare both builds per backend (VERIFY_BACKENDS="metal cpu")
make pin SD_CPP_TAG=<tag>     # re-pin both packages
make linux | linux-x86_64     # cross-compiled sd-cli
make test                     # pixdiff unit tests
```

Fast check while iterating: `make verify-metal WIDTH=512 HEIGHT=512 STEPS=4`. The comparable case before calling a change done is the default: SDXL Q8_0, 1024², 20 steps, seed 42, both backends (the CPU case takes minutes per build).

## Layout

```
build.zig            the whole build graph (see below)
build.zig.zon        pins: stablediffusion_cpp (release tarball), ggml (leejet/ggml at a full sha), zigbuildx
Makefile             entry points; grouped sections, each with its own .PHONY
zig/metal_embed.zig  flattens a Metal kernel byte-for-byte as ggml's cat/sed pipeline does
zig/pixdiff.zig      decodes two PNGs (stb_image from the pin) and compares pixels; exit 0 same, 1 differ, 2 error
zig/stb_image.c      the stb_image implementation unit for pixdiff
zig-pkg/<hash>/      fetched sources — read-only, gitignored
.ref/ models/ out/   CMake reference build, weights, generated images — gitignored
```

## build.zig

- `Pin`: comptime-parsed from the zon URLs → `tag` (`master-1088-32d516c`), `commit`, `ggml_commit`. Feeds `SDCPP_BUILD_VERSION` / `SDCPP_BUILD_COMMIT`. Never hand-edit versions.
- `Platform` (`macos`, `linux`): POSIX feature macros (`_XOPEN_SOURCE=600` + `_DARWIN_C_SOURCE` / `_GNU_SOURCE`).
- Source lists are explicit arrays mirroring the CMake globs (`ggml_base_*`, `ggml_cpu_*`, `ArchSources.forArch`, `ggml_metal_*`, `metal_kernels`, `sd_glob_dirs`, `onig_sources`, cli/server sources). `ggml_base` includes the fork-only `ggml-ext.cpp` / `ggml-graph.cpp`.
- `Tree`: a fetched package's root; tolerates a tarball's single top-level dir; `glob`/`list` are sorted and register directory dependencies.
- `Config`: options and the per-target builders. One compile per CMake target: `ggml-base`, `ggml-cpu`, `ggml-metal`, `ggml` (registry), `stable-diffusion` (with zip / onig / utf8proc as object libraries), `sd-cli`, `sd-server`, plus `pixdiff`.
- Option: `-Dmetal` (default on for macOS; error elsewhere). Default target is the **baseline CPU** (`GGML_NATIVE=OFF` parity) with macOS minimum 13.0.
- Steps: `lib`, `cli`, `server`, `run`, `pixdiff`, `test`. Default install = libraries + `stable-diffusion.h` + `sd-cli`.

### Flags (from CMake's `compile_commands.json`)

- `-std=gnu11` / `-std=gnu++17`; `GGML_MAX_NAME=160` on every unit; `-DNDEBUG` unless Debug; `sanitize_c = .off`.
- ggml: `GGML_SCHED_MAX_COPIES=4` + the POSIX macros. ggml-cpu: `GGML_USE_CPU_REPACK`, and on macOS `GGML_USE_ACCELERATE`, `ACCELERATE_NEW_LAPACK`, `ACCELERATE_LAPACK_ILP64`. ggml-metal: `GGML_METAL_EMBED_LIBRARY`.
- Consumers get `GGML_USE_CPU` (+ `GGML_USE_METAL`). Third party: `ONIG_STATIC`, `UTF8PROC_STATIC`.
- `SD_BACKEND_EXTENSIONS` only on `src/core/ggml_extensions.cpp`; `SDCPP_BUILD_*` only on `version.cpp`; `-fno-objc-arc` on `src/core/metal/int8.mm`.
- Cite the upstream `CMakeLists.txt` line when replicating a decision. To re-derive flags: `make ref`, then read `.ref/build/compile_commands.json`.

### Generated files (each must match CMake's output)

`ggml-version.h` (version parsed from ggml's `CMakeLists.txt`), oniguruma `config.h` (from `config.h.cmake.in`), `int8_source.h` (Metal `src/core/metal/int8*.metal`), `sd_backend_extensions.h`, the server's `recipes_builtin.h` (`recipes/*.json` as raw strings), and the embedded Metal library (`metal_embed.zig`).

### Executables link Apple's runtime, not Zig's

On macOS every executable sets `bundle_compiler_rt = false` and links `$(xcrun clang -print-resource-dir)/lib/darwin/libclang_rt.osx.a` (needed for `__isPlatformVersionAtLeast`). Zig's compiler-rt carries local `exp`/`expf`/`log`/`sin`/`cos`/… that shadow libm and round differently — that alone moved 27% of pixels. Don't remove this.

## Makefile

- `-include ../styleguide/Makefile.in` supplies `format`, `lint`, `validate` (`ZIG_DIRS := zig`); never copy them here.
- UPPER_CASE variables are user settings (`?=`); lower_case are internal (`zon_hash`, `pkg_dir`, `verify_args`, `verify_device_<backend>`, `cmake_venv`). Every target has a one-line comment; each section declares its own `.PHONY`.
- `RELEASE ?= --release=fast` on every build target; Debug is too slow to generate with.
- `ref`'s `-D` set is **the CMake configuration being matched**: Metal with embedded shaders, Accelerate, no BLAS/OpenMP, `GGML_NATIVE=OFF`, static, macOS 13.0, WebP/WebM off. `-DSD_GGML_SOURCE_DIR` points CMake at the same `zig-pkg/` dirs, so both builds compile the same bytes.
- `pin` reads the ggml submodule sha from GitHub's contents API, then `zig fetch --save` for both packages.

## Verification rules

- **Pin runtime choices.** `sd-cli` picks flash attention by timing (`auto`), and backends/weight placement by free memory (`--auto-fit`); two runs of the *same* binary can differ. `verify_args` passes `--auto-fit off --flash-attn off`; each `verify-<backend>` adds `--backend MTL0|cpu`.
- Compare decoded pixels, never PNG bytes: the metadata holds the version, which differs by design.
- `-O2` (Zig ReleaseFast) vs CMake's `-O3` was tested and does not change output.

## Decisions

- **ggml is upstream's own submodule, leejet's fork**, at the commit upstream's submodule names. sd.cpp calls fork-only APIs (`ggml_ext_*`, `ggml_graph_cpy_mapped`, …). Not used: `SD_USE_UPSTREAM_GGML` (a non-default compatibility mode that drops INT8/FP8 and the extension kernels) and `../llama.zig` (a Zig rewrite of standard ggml, not the shipped sources).
- **The release tarball has no submodules.** ggml is its own zon dependency; libwebp, libwebm, cutlass and `examples/server/frontend` are absent, so WebP/WebM are off — what CMake does when they are missing.
- **`sd-server` is API only.** Its web UI needs the frontend submodule built with Node/pnpm. Declined (2026-11-11): the build stays Zig-only.
- **No shell scripts.** Workflows live in the Makefile or Zig.
- CMake for `make ref` comes from PyPI in `.ref/venv` (`python3 -m venv`; `uv` isn't assumed).

## Gotchas

- Never modify anything under `zig-pkg/`. If upstream seems to need a change to build, the build description is wrong, not the source.
- Use `zig fetch --save` / `make pin`, never a bare `zig fetch`: a tarball it leaves in the global cache gets unpacked by `zig build` with its top-level dir kept and a different hash. `Tree` tolerates either layout.
- Deleting only part of `.zig-cache` breaks it; `make clean` removes all of it.
- The Zig test runner fails any test that logs at error level.

## Not yet implemented

- Vulkan (`-Dvulkan`): needs `glslc` and the Vulkan headers, absent on this machine; would port ggml-vulkan from `../llama.cpp.zmake` plus `src/core/vulkan`'s shaders and registrations.
- CUDA: `.cu` sources need `nvcc`; Zig can't compile them.
- WebP/WebM output; sd-server's web UI (declined).
- Linux binaries are built but have not been run or verified.
