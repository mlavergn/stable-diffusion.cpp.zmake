# stable-diffusion.cpp.zmake

> Build [stable-diffusion.cpp](https://github.com/leejet/stable-diffusion.cpp) with Zig instead of CMake, and generate SDXL images with it.

## Overview

stable-diffusion.cpp is a C/C++ implementation of Stable Diffusion and related
image models, built on the ggml tensor library. Upstream builds it with CMake.
This project builds it with the Zig toolchain, one `zig build` and nothing
else: no CMake and no Xcode project, and the same build cross-compiles for
Linux.

It replaces the build and only the build. The upstream sources are compiled as
they ship, unmodified, and what comes out is upstream's own programs:

- `sd-cli`, the command-line generator
- `sd-server`, the HTTP API server
- `libstable-diffusion` and ggml, with the `stable-diffusion.h` header

The sources are pinned to one upstream release, together with the ggml that
release uses (leejet's patched fork, carried upstream as a git submodule).

A build counts as correct only when it generates **the same image, pixel for
pixel**, as upstream's CMake build of the same sources, model, prompt and seed.
`make verify` checks exactly that, on Metal and on the CPU.

### Status

| Platform | Backends | State |
| -------- | -------- | ----- |
| macOS, Apple Silicon | Metal, CPU | Built and verified identical to CMake |
| Linux arm64, x86_64 | CPU | Cross-compiled; not yet run |

Not available: Vulkan and CUDA backends; WebP/WebM output (PNG and JPEG
work); `sd-server`'s browser UI (its API works). The last two depend on
upstream submodules that are not in the release download.

## Requirements

- Zig 0.17.0
- macOS on Apple Silicon with Xcode
- `curl`, for downloading the model weights (about 5.4 GB)
- `python3`, only for `make ref`, which builds the CMake reference to verify
  against
- The sibling checkout `../styleguide`, only for `make format`, `make lint`
  and `make validate`

## Setup

```sh
git clone git@github.com:mlavergn/stablediffusioncpp.git
cd stablediffusioncpp
make cli       # fetch the sources, build sd-cli, download SDXL, generate and open out/sdxl.png
```

The first run downloads the pinned sources and the weights; later runs only
generate.

## Configuration

Everything is a `make` variable, overridable on the command line:

| Variable | Default | Used by |
| -------- | ------- | ------- |
| `PROMPT` | `a lovely cat` | `cli`, `verify` |
| `SEED`, `STEPS` | `42`, `20` | `cli`, `verify` |
| `WIDTH`, `HEIGHT` | `1024`, `1024` | `cli`, `verify` |
| `OUT` | `out/sdxl.png` | `cli` |
| `OPEN` | `open` on macOS, else `xdg-open`; `true` skips it | `cli` |
| `MODEL` | `models/stable-diffusion-xl-base-1.0-Q8_0.gguf` | `cli`, `web`, `verify` |
| `VAE` | `models/sdxl_vae.safetensors` | `cli`, `web`, `verify` |
| `MODEL_URL`, `VAE_URL` | the Hugging Face files below | `models` |
| `WEB_HOST`, `WEB_PORT` | `127.0.0.1`, `1234` | `web` |
| `RELEASE` | `--release=fast` (`RELEASE=` builds Debug) | every build |
| `VERIFY_BACKENDS` | `metal cpu` | `verify` |
| `VERIFY_DIR` | `out/verify` | `verify` |

**Weights.** `make models` (or any target that needs them) downloads SDXL base
as a Q8_0 GGUF from `gpustack/stable-diffusion-xl-base-1.0-GGUF`, and the
fp16-fix VAE from `madebyollin/sdxl-vae-fp16-fix`; neither needs a login. The
fp16-fix VAE is used because SDXL's own produces NaNs in fp16. The same GGUF
repository has `Q4_0`, `Q4_1` and `FP16` files; point `MODEL_URL` at one, or
`MODEL` at a file you already have. To quantize the original
`stabilityai/stable-diffusion-xl-base-1.0` safetensors yourself:

```sh
make run ARGS="-M convert -m sd_xl_base_1.0.safetensors -o models/sdxl-q8_0.gguf --type q8_0"
```

No secrets are involved.

## Usage

Generate an image (written to `OUT` and opened):

```sh
make cli
make cli PROMPT="a lighthouse at dusk" SEED=7 OUT=out/lighthouse.png
```

Serve SDXL over HTTP until Ctrl-C. The API is upstream's, documented in
`examples/server/api.md` of the sources (`make srcdir` prints where they are):

```sh
make web
curl -s http://127.0.0.1:1234/sdapi/v1/txt2img \
  -d '{"prompt":"a lovely cat","width":1024,"height":1024,"steps":20}'
```

Run `sd-cli` with any of its arguments:

```sh
make run ARGS="--help"
```

Build without running:

```sh
make build     # libraries, header and sd-cli, into zig-out/
make lib       # ggml and libstable-diffusion, plus the header
make server    # sd-server
make linux linux-x86_64     # sd-cli for Linux, into zig-out/linux*/
```

Check this build against CMake. `make ref` builds upstream's CMake `sd-cli`
from the same sources into `.ref/`; `make verify` has both generate the same
images and compares them pixel by pixel. The CPU case takes minutes at
1024x1024; `make verify-metal` runs Metal alone.

```sh
make ref
make verify
```

Move to another upstream release (the version strings follow the pin):

```sh
make pin SD_CPP_TAG=master-<N>-<commit>
```

## Architecture

```
build.zig            the build: ggml, libstable-diffusion, sd-cli, sd-server
build.zig.zon        the pins: stable-diffusion.cpp, its ggml, zigbuildx
Makefile             every entry point above
zig/                 small Zig tools the build and make verify use
zig-pkg/<hash>/      the fetched upstream sources (gitignored, never edited)
models/              downloaded weights (gitignored)
out/                 generated images (gitignored)
.ref/                the CMake reference build (gitignored)
```

`make` drives `zig build`, which fetches the pinned sources into `zig-pkg/`
and compiles them as upstream's CMake does: the same targets, sources, flags
and generated headers. The implementation notes are in `CLAUDE.md`. The same
approach builds llama.cpp in the sibling project `../llama.cpp.zmake`.
