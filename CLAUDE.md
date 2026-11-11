# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project

**Replace stable-diffusion.cpp's CMake build with `build.zig`. Nothing else.**

Upstream sources (leejet/stable-diffusion.cpp and its `ggml` submodule, leejet's patched fork) are compiled exactly as shipped: no porting to Zig, no bug fixes, no behaviour changes, no Zig wrapper. The outputs are upstream's own `sd-cli`, `sd-server` and libraries. A binary built here must generate **pixel-identical images** to the same sources built by CMake (`make verify`). `README.md` is the user-facing overview; this file holds the implementation.

Sibling reference for the recipe: `../llama.cpp.zmake`. Requires Zig **0.17.0** and, on macOS, Xcode. Targets: macOS arm64 (Metal + CPU, verified); Linux aarch64 on the DGX Spark / GB10 (CUDA + CPU, built on the host, verified); Linux aarch64 / x86_64 cross-compiled (CPU, not run).

## Commands

```sh
make validate                 # pre-commit gate: clean, format, lint, build, test
make cli                      # build sd-cli, generate SDXL -> out/sdxl.png, open it (PROMPT=, SEED=, OUT=, OPEN=true, ...)
make web                      # build + run sd-server with SDXL on 127.0.0.1:1234 (API only)
make build | lib | server     # build only: zig build [<step>] $(zig_flags)
make run ARGS="..."           # zig build run -- $(ARGS)
make ref                      # CMake reference sd-cli into .ref/build (cmake from PyPI in .ref/venv)
make verify | verify-metal | verify-cuda   # pixel-compare both builds per backend (VERIFY_BACKENDS)
make perf                     # time a prebuilt sd-cli's generate_image, PERF_RUNS times; 1024² 8-bit RGB PNG at 72 ppi (never builds sd-cli)
make pin SD_CPP_TAG=<tag>     # re-pin both packages
make linux | linux-x86_64     # cross-compiled sd-cli
make test                     # pixdiff and pngphys unit tests
```

Fast check while iterating: `make verify-metal WIDTH=512 HEIGHT=512 STEPS=4` (`verify-cuda` on the DGX). The comparable case before calling a change done is the default: SDXL Q8_0, 1024², 20 steps, seed 42, both backends (the CPU case takes minutes per build).

## Layout

```
build.zig            the whole build graph (see below)
build.zig.zon        pins: stablediffusion_cpp (release tarball), ggml (leejet/ggml at a full sha), zigbuildx
Makefile             entry points; grouped sections, each with its own .PHONY
zig/metal_embed.zig  flattens a Metal kernel byte-for-byte as ggml's cat/sed pipeline does
zig/pixdiff.zig      decodes two PNGs (stb_image from the pin) and compares pixels; exit 0 same, 1 differ, 2 error
zig/stb_image.c      the stb_image implementation unit for pixdiff
zig/pngphys.zig      checks a PNG is WxH 8-bit RGB and stamps a pHYs chunk (ppi) after IHDR; pixels untouched; exit 0 ok, 1 wrong shape, 2 error
zig-pkg/<hash>/      fetched sources — read-only, gitignored
.ref/ models/ out/   CMake reference build, weights, generated images — gitignored
```

## build.zig

- `Pin`: comptime-parsed from the zon URLs → `tag` (`master-1088-32d516c`), `commit`, `ggml_commit`. Feeds `SDCPP_BUILD_VERSION` / `SDCPP_BUILD_COMMIT`. Never hand-edit versions.
- `Platform` (`macos`, `linux`): POSIX feature macros (`_XOPEN_SOURCE=600` + `_DARWIN_C_SOURCE` / `_GNU_SOURCE`).
- Source lists are explicit arrays mirroring the CMake globs (`ggml_base_*`, `ggml_cpu_*`, `ArchSources.forArch`, `ggml_metal_*`, `metal_kernels`, `sd_glob_dirs`, `onig_sources`, cli/server sources). `ggml_base` includes the fork-only `ggml-ext.cpp` / `ggml-graph.cpp`.
- `Tree`: a fetched package's root; tolerates a tarball's single top-level dir; `glob`/`list` are sorted and register directory dependencies.
- `Config`: options and the per-target builders. One compile per CMake target: `ggml-base`, `ggml-cpu`, `ggml-metal`, `ggml-cuda`, `ggml` (registry), `stable-diffusion` (with zip / onig / utf8proc as object libraries, and with CUDA the `sd-cuda` objects), `sd-cli`, `sd-server`, plus `pixdiff`.
- `Cuda`: `-Dcuda` resolved into nvcc command lines and link inputs (`Cuda.init`, `gencode`, `faQuants` → `CudaFa`); `Config.nvcc` runs one cached nvcc per `.cu` with its depfile, its include paths as `NvccInclude`s. Supporting types are top-level, above the struct using them (ZIGSTYLE B.2.a), never nested.
- Options: `-Dmetal` (default on for macOS; error elsewhere). `-Dcuda` (Linux, host only), `-Dcuda-path`, `-Dcuda-arch` (required with `-Dcuda`), `-Dcuda-fa-quants`; the Makefile passes them when `CUDA=true`. Default target is the **baseline CPU** (`GGML_NATIVE=OFF` parity) with macOS minimum 13.0.
- Steps: `lib`, `cli`, `server`, `run`, `pixdiff`, `pngphys`, `test`. Default install = libraries + `stable-diffusion.h` + `sd-cli`.

### Flags (from CMake's `compile_commands.json`)

- `-std=gnu11` / `-std=gnu++17`; `GGML_MAX_NAME=160` on every unit; `-DNDEBUG` unless Debug; `sanitize_c = .off`.
- ggml: `GGML_SCHED_MAX_COPIES=4` + the POSIX macros. ggml-cpu: `GGML_USE_CPU_REPACK`, and on macOS `GGML_USE_ACCELERATE`, `ACCELERATE_NEW_LAPACK`, `ACCELERATE_LAPACK_ILP64`. ggml-metal: `GGML_METAL_EMBED_LIBRARY`.
- Consumers get `GGML_USE_CPU` (+ `GGML_USE_METAL` or `GGML_USE_CUDA`). Third party: `ONIG_STATIC`, `UTF8PROC_STATIC`.
- `SD_BACKEND_EXTENSIONS` only on `src/core/ggml_extensions.cpp`; `SDCPP_BUILD_*` only on `version.cpp`; `-fno-objc-arc` on `src/core/metal/int8.mm`; `SD_USE_CUDA` only on `src/core/ggml_extend_backend.cpp`.
- Cite the upstream `CMakeLists.txt` line when replicating a decision. To re-derive flags: `make ref`, then read `.ref/build/compile_commands.json`.

### CUDA (`-Dcuda`)

- `.cu` files go to the toolkit's `nvcc` with its default host compiler, g++, on CMake's exact command lines (defines, `includes_CUDA.rsp` spelled unnormalized, flags, `-x cu -c`). Zig's clang can't be nvcc's host: CUDA 13.0's `math_functions.hpp` clashes with libc++'s `isnan`/`isinf`. All 157 objects matched CMake's in SASS and host code.
- ggml-cuda: the 49 sorted `GGML_CUDA_FA_*` switches + `GGML_CUDA_FA_QUANTS`, `GGML_CUDA_USE_CUBLASLT_FP8`, ggml's directory defines; `-use_fast_math -extended-lambda -compress-mode=size` and `-Xcompiler` with the `GGML_ALL_WARNINGS` set.
- sd-cuda (`src/core/cuda/CMakeLists.txt`): nine generated wrappers (`#define SD_CUDA_VENDOR_CUDA 1` + `#include "core/cuda/<op>.cu"`) and `sage_attention.cu` / `sol_attention.cu`; `-Xcompiler=-fPIC --use_fast_math`. **Its architectures are not rewritten to `12Xa`**: ggml's rewrite is scoped to ggml-cuda's directory, so `121-real` gives ggml `sm_121a` and sd `sm_121`. That is why `-Dcuda-arch` is required: with none, CMake gives sd-cuda the compiler's default, which isn't reproducible here.
- CUTLASS kernels are off: the submodule isn't in the tarball, and CMake fatals unless `SD_CUDA_CUTLASS_PATH` is empty.
- Executables (`linkCuda`): shared `cudart`, `cublas`, `cublasLt`, static `culibos`, the `libcuda` stub, rpath to `targets/<triple>/lib`, then g++'s `libstdc++.so` and `libgcc.a` by path (`linkSystemLibrary("stdc++")` becomes libc++; `libgcc.a` supplies g++'s arm64 outline atomics). The sources include `-isystem` the toolkit's headers, as CMake gives every target linking a CUDA library.

### Generated files (each must match CMake's output)

`ggml-version.h` (version parsed from ggml's `CMakeLists.txt`), oniguruma `config.h` (from `config.h.cmake.in`), `int8_source.h` (Metal `src/core/metal/int8*.metal`), `sd_backend_extensions.h`, the server's `recipes_builtin.h` (`recipes/*.json` as raw strings), and the embedded Metal library (`metal_embed.zig`).

### Executables link Apple's runtime, not Zig's

On macOS every executable sets `bundle_compiler_rt = false` and links `$(xcrun clang -print-resource-dir)/lib/darwin/libclang_rt.osx.a` (needed for `__isPlatformVersionAtLeast`). Zig's compiler-rt carries local `exp`/`expf`/`log`/`sin`/`cos`/… that shadow libm and round differently — that alone moved 27% of pixels. Don't remove this.

## Makefile

- `-include ../styleguide/Makefile.in` supplies `format`, `lint`, `validate` (`ZIG_DIRS := zig`); never copy them here.
- UPPER_CASE variables are user settings (`?=`); lower_case are internal (`zon_hash`, `pkg_dir`, `verify_args`, `verify_device_<backend>`, `cmake_venv`). Every target has a one-line comment; each section declares its own `.PHONY`.
- `RELEASE ?= --release=fast` on every build target; Debug is too slow to generate with.
- `ref`'s `-D` set is **the CMake configuration being matched**: no BLAS/OpenMP, `GGML_NATIVE=OFF`, static, WebP/WebM off, then `ref_flags_<uname -s>`. Darwin: Metal with embedded shaders, Accelerate, macOS 13.0. Linux: `zig cc`/`zig c++` at `-mcpu=baseline` as the C/C++ compiler, and with `CUDA=true` `SD_CUDA`, g++ as nvcc's host, `SD_CUDA_CUTLASS_PATH=` and g++'s runtime in `CMAKE_CXX_STANDARD_LIBRARIES`.
- `CUDA` defaults to true on Linux when `$(CUDA_PATH)/bin/nvcc` exists; `CUDA_ARCH` comes from `nvidia-smi`'s compute capability. Host build targets pass `$(zig_flags)` = `$(RELEASE) $(cuda_flags)`; the cross-compile targets don't. `-DSD_GGML_SOURCE_DIR` points CMake at the same `zig-pkg/` dirs, so both builds compile the same bytes.
- `pin` reads the ggml submodule sha from GitHub's contents API, then `zig fetch --save` for both packages.

## Verification rules

- **Pin runtime choices.** `sd-cli` picks flash attention by timing (`auto`), and backends/weight placement by free memory (`--auto-fit`); two runs of the *same* binary can differ. `verify_args` passes `--auto-fit off --flash-attn off`; each `verify-<backend>` adds `--backend MTL0|cpu`.
- Compare decoded pixels, never PNG bytes: the metadata holds the version, which differs by design.
- `-O2` (Zig ReleaseFast) vs CMake's `-O3` was tested and does not change output.
- **Linux reference uses Zig's clang, not gcc** (2026-11-11). Against a gcc reference the CUDA image differed in 96% of pixels (the same picture, drifted) although all CUDA objects were identical and math came from glibc on both sides; `-ffp-contract=fast` didn't close it. With CMake driving `zig c++` it is identical. Plain `zig cc` targets the native CPU (SVE, i8mm), which broke the CPU case until `-mcpu=baseline`.
- Log lines' `file:line` differ between gcc and clang builds (multi-line macro `__LINE__`); not a source mismatch.

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
- CUDA's CUTLASS kernels (submodule absent); CUDA on x86_64 Linux (layout handled, never built).
- WebP/WebM output; sd-server's web UI (declined).
- Cross-compiled Linux binaries have not been run; the host-built DGX ones are verified.
