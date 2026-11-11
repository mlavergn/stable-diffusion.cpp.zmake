//! Zig build system for stable-diffusion.cpp, replacing CMake.
//!
//! Builds the stock C, C++, and Objective-C sources unmodified. Nothing here
//! ports code -- the only thing being replaced is the build description, and
//! a binary built here must generate pixel-identical images to the same
//! sources built by CMake (`make verify`).
//!
//! # Sources
//!
//! Two packages in `build.zig.zon`, both read-only: upstream's release tarball
//! (`stablediffusion_cpp`) and the `ggml` submodule it points at, leejet's
//! patched fork, which the tarball does not carry. CMake reaches the second
//! through `SD_GGML_SOURCE_DIR`; here every path into either goes through a
//! `Tree`.
//!
//! # Targets
//!
//! The CMake targets, one archive each, with the flags CMake compiles each
//! with (`compile_commands.json` of the `make ref` build):
//!
//!   ggml-base, ggml-cpu, ggml-metal, ggml   ggml/src/CMakeLists.txt
//!   stable-diffusion                        CMakeLists.txt, with the zip,
//!                                           onig and sd-utf8proc objects
//!   sd-cli                                  examples/cli/CMakeLists.txt
//!   sd-server                               examples/server/CMakeLists.txt
//!
//! # Configuration
//!
//! Matches the `-D` flags `make ref` drives CMake with: static libraries,
//! `SD_WEBP`/`SD_WEBM` off (their submodules are not in the tarball, so CMake
//! turns them off too), BLAS and OpenMP off, `GGML_NATIVE` off.
//!
//!   macOS  Metal on (`-Dmetal=false` for CPU only), shaders embedded,
//!          Accelerate on
//!   Linux  CPU backend only, arm64 and x86_64, `_GNU_SOURCE` on
//!
//! # Steps
//!
//!   zig build            libraries, header, sd-cli
//!   zig build lib        libraries and header only
//!   zig build cli        sd-cli
//!   zig build server     sd-server (API only; no web UI)
//!   zig build run -- ... build and run sd-cli
//!   zig build pixdiff    the image comparer `make verify` uses
//!   zig build test       pixdiff's unit tests

const std = @import("std");
const log = std.log.scoped(.stablediffusioncpp_build);
const zon = @import("build.zig.zon");
const zigbuildx = @import("zigbuildx");

/// What the pins in `build.zig.zon` say, derived at comptime so re-pinning
/// needs no edit here.
const Pin = struct {
    const Self = @This();
    /// Upstream's release tag, e.g. `master-1088-32d516c`. CMake embeds
    /// `git describe` as `SDCPP_BUILD_VERSION`; a tarball has no git, so this
    /// build embeds the tag it was pinned to instead.
    const tag = archiveName(zon.dependencies.stablediffusion_cpp.url);
    /// The upstream commit the tag names, its last `-` field.
    const commit = tag[(std.mem.findScalarLast(u8, tag, '-').? + 1)..];
    /// The ggml fork's commit, abbreviated as `git rev-parse --short` does.
    const ggml_commit = archiveName(zon.dependencies.ggml.url)[0..7];

    /// The archive a GitHub tarball URL names, without `.tar.gz`.
    ///
    /// - `url`: The URL.
    /// - Returns: Its last path component, the suffix removed.
    fn archiveName(comptime url: []const u8) []const u8 {
        const base = url[(std.mem.findScalarLast(u8, url, '/').? + 1)..];
        return std.mem.cutSuffix(u8, base, ".tar.gz") orelse @compileError("not a .tar.gz URL: " ++ url);
    }
};

/// The platforms this build knows how to configure.
const Platform = enum {
    const Self = @This();
    macos,
    linux,

    /// Map a resolved target onto a configuration this build supports.
    ///
    /// - `target`: The target `-Dtarget` resolved to.
    /// - Returns: The platform, or null for an OS this build has no
    ///   configuration for.
    fn detect(target: std.Target) ?Self {
        return switch (target.os.tag) {
            .macos => .macos,
            .linux => .linux,
            else => null,
        };
    }

    /// The feature-test macros ggml/src/CMakeLists.txt:131-167 adds for this
    /// platform, directory-wide, so to every ggml target.
    ///
    /// - Returns: The `-D` flags.
    fn posixDefines(self: *const Self) []const []const u8 {
        return switch (self.*) {
            .macos => &.{ "-D_XOPEN_SOURCE=600", "-D_DARWIN_C_SOURCE" },
            .linux => &.{ "-D_XOPEN_SOURCE=600", "-D_GNU_SOURCE" },
        };
    }
};

/// Warnings that fire on these sources under Zig's clang and bundled libc++
/// but say nothing useful. Silenced so real diagnostics stay visible; no
/// warning flag changes code generation.
const quiet = [_][]const u8{
    "-Wno-nullability-completeness",
    "-Wno-deprecated-declarations",
    "-Wno-unused-function",
    "-Wno-unused-variable",
    "-Wno-unused-but-set-variable",
    "-Wno-unused-parameter",
    "-Wno-missing-field-initializers",
};

/// CMake's dialects. `CMAKE_C_STANDARD 11` and `CMAKE_CXX_STANDARD 17` leave
/// the extensions on, so CMake passes the GNU ones everywhere.
const c_std = [_][]const u8{"-std=gnu11"} ++ quiet;
const cxx_std = [_][]const u8{"-std=gnu++17"} ++ quiet;

/// Defined for every target: CMakeLists.txt:351, `add_definitions` before any
/// subdirectory is added (see ggml/ggml#682).
const global_defines = [_][]const u8{"-DGGML_MAX_NAME=160"};

/// The rest of ggml/src/CMakeLists.txt:4's directory-wide definitions.
const ggml_defines = [_][]const u8{"-DGGML_SCHED_MAX_COPIES=4"};

/// ggml-cpu's own (ggml-cpu/CMakeLists.txt): the repack buffer type, on by
/// default, and on Apple the Accelerate framework.
const cpu_defines = [_][]const u8{"-DGGML_USE_CPU_REPACK"};
const accelerate_defines = [_][]const u8{
    "-DGGML_USE_ACCELERATE",
    "-DACCELERATE_NEW_LAPACK",
    "-DACCELERATE_LAPACK_ILP64",
};

/// The `onig` and `sd-utf8proc` object libraries' PUBLIC definitions
/// (thirdparty/CMakeLists.txt), which reach everything linking them.
const thirdparty_defines = [_][]const u8{ "-DONIG_STATIC", "-DUTF8PROC_STATIC" };

// -----------------------------------------------------------------------------
// Source lists
//
// Taken from the CMakeLists.txt each target lives in. Files CMake adds only
// for an option this build leaves off are omitted.

/// ggml-base (ggml/src/CMakeLists.txt:192-211).
const ggml_base_c = [_][]const u8{ "src/ggml.c", "src/ggml-alloc.c", "src/ggml-quants.c" };
const ggml_base_cxx = [_][]const u8{
    "src/ggml.cpp",           "src/ggml-backend.cpp",      "src/ggml-ext.cpp",
    "src/ggml-graph.cpp",     "src/ggml-backend-meta.cpp", "src/ggml-opt.cpp",
    "src/ggml-threading.cpp", "src/gguf.cpp",
};

/// ggml (ggml/src/CMakeLists.txt:360): backend registration.
const ggml_reg_cxx = [_][]const u8{ "src/ggml-backend-dl.cpp", "src/ggml-backend-reg.cpp" };

/// ggml-cpu (ggml/src/ggml-cpu/CMakeLists.txt), less its per-arch pair.
const ggml_cpu_c = [_][]const u8{ "src/ggml-cpu/ggml-cpu.c", "src/ggml-cpu/quants.c" };
const ggml_cpu_cxx = [_][]const u8{
    "src/ggml-cpu/ggml-cpu.cpp",    "src/ggml-cpu/repack.cpp",
    "src/ggml-cpu/hbm.cpp",         "src/ggml-cpu/traits.cpp",
    // amx compiles to nothing on ARM, but CMake lists it unconditionally.
    "src/ggml-cpu/amx/amx.cpp",     "src/ggml-cpu/amx/mmq.cpp",
    "src/ggml-cpu/tiled/tiled.cpp", "src/ggml-cpu/tiled/tiled-kernel.cpp",
    "src/ggml-cpu/binary-ops.cpp",  "src/ggml-cpu/unary-ops.cpp",
    "src/ggml-cpu/vec.cpp",         "src/ggml-cpu/ops.cpp",
};

/// The CPU backend's per-architecture sources, one pair per
/// `GGML_SYSTEM_ARCH`. On x86 CMake adds `arch/x86/cpu-feats.cpp` only for
/// `GGML_BACKEND_DL`, which is off.
const ArchSources = struct {
    const Self = @This();
    c: []const []const u8,
    cxx: []const []const u8,

    /// The arch sources for `arch`.
    ///
    /// - `arch`: The target's CPU architecture.
    /// - Returns: Its sources, or null for one this build has no list for.
    fn forArch(arch: std.Target.Cpu.Arch) ?Self {
        return switch (arch) {
            .aarch64 => .{ .c = &.{"src/ggml-cpu/arch/arm/quants.c"}, .cxx = &.{"src/ggml-cpu/arch/arm/repack.cpp"} },
            .x86_64 => .{ .c = &.{"src/ggml-cpu/arch/x86/quants.c"}, .cxx = &.{"src/ggml-cpu/arch/x86/repack.cpp"} },
            else => null,
        };
    }
};

/// ggml-metal (ggml/src/ggml-metal/CMakeLists.txt).
const ggml_metal_cxx = [_][]const u8{
    "src/ggml-metal/ggml-metal.cpp",        "src/ggml-metal/ggml-metal-device.cpp",
    "src/ggml-metal/ggml-metal-common.cpp", "src/ggml-metal/ggml-metal-fusion.cpp",
    "src/ggml-metal/ggml-metal-ops.cpp",    "src/ggml-metal/ggml-metal-tuning.cpp",
};
const ggml_metal_objc = [_][]const u8{ "src/ggml-metal/ggml-metal-device.m", "src/ggml-metal/ggml-metal-context.m" };

/// `METALLIB_KERNEL_SOURCES` (ggml-metal/CMakeLists.txt:39-76). Each becomes
/// a `ggml_metallib_<name>_{start,end}` symbol pair.
const metal_kernels = [_][]const u8{
    "fa_aux",          "fa_f16",      "fa_f32",      "fa_q4_0",
    "fa_q4_1",         "fa_q5_0",     "fa_q5_1",     "fa_q8_0",
    "fa_tensor",       "fa_vec_f16",  "fa_vec_f32",  "fa_vec_q4_0",
    "fa_vec_q4_1",     "fa_vec_q5_0", "fa_vec_q5_1", "fa_vec_q8_0",
    "mul_mv",          "mul_mv_mma",  "mul_mm",      "quantize",
    "softmax",         "norm",        "unary",       "binbcast",
    "reduce",          "tri",         "ssm",         "wkv",
    "gated_delta_net", "solve_tri",   "rope",        "conv",
    "upscale",         "argsort",     "pool",        "misc",
};

/// The directories `SD_LIB_SOURCES` globs (CMakeLists.txt:239-270), each
/// non-recursively. `src/model/*` is every subdirectory of `src/model`.
const sd_glob_dirs = [_][]const u8{
    "src",            "src/conditioning", "src/core",             "src/core/cpu",
    "src/core/probe", "src/extensions",   "src/pipeline",         "src/runtime",
    "src/model_io",   "src/tokenizers",   "src/tokenizers/vocab",
};

/// The two sources CMake gives definitions of their own.
const sd_version_source = "src/version.cpp";
const sd_extensions_source = "src/core/ggml_extensions.cpp";

/// The `onig` object library (thirdparty/CMakeLists.txt:37-50).
const onig_sources = [_][]const u8{
    "thirdparty/oniguruma/ascii.c",             "thirdparty/oniguruma/regcomp.c",
    "thirdparty/oniguruma/regenc.c",            "thirdparty/oniguruma/regerror.c",
    "thirdparty/oniguruma/regexec.c",           "thirdparty/oniguruma/regparse.c",
    "thirdparty/oniguruma/st.c",                "thirdparty/oniguruma/unicode.c",
    "thirdparty/oniguruma/unicode_fold1_key.c", "thirdparty/oniguruma/unicode_fold2_key.c",
    "thirdparty/oniguruma/unicode_fold3_key.c", "thirdparty/oniguruma/unicode_unfold_key.c",
    "thirdparty/oniguruma/utf8.c",
};

/// The sources `examples/common` contributes to both executables.
const example_common_sources = [_][]const u8{
    "examples/common/common.cpp",         "examples/common/generation_metadata.cpp",
    "examples/common/log.cpp",            "examples/common/media_io.cpp",
    "examples/common/media_metadata.cpp",
};

/// sd-cli (examples/cli/CMakeLists.txt).
const cli_sources = [_][]const u8{ "examples/cli/image_metadata.cpp", "examples/cli/main.cpp" };

/// sd-server (examples/server/CMakeLists.txt).
const server_sources = [_][]const u8{
    "examples/server/async_jobs.cpp",    "examples/server/main.cpp",
    "examples/server/model_catalog.cpp", "examples/server/routes_index.cpp",
    "examples/server/routes_models.cpp", "examples/server/routes_openai.cpp",
    "examples/server/routes_sdapi.cpp",  "examples/server/routes_sdcpp.cpp",
    "examples/server/runtime.cpp",
};

// -----------------------------------------------------------------------------

/// A source package from `build.zig.zon`, read-only.
///
/// A package normally holds the sources at its root. Under Zig 0.17 one that
/// `zig build` first unpacks from a tarball a plain `zig fetch` left in the
/// global cache keeps the tarball's top-level directory instead (and then
/// fails its hash check), so paths are resolved below `prefix`: that one
/// directory when it is all the package holds, else the root.
const Tree = struct {
    const Self = @This();
    /// The build graph paths are declared on.
    b: *std.Build,
    /// The package.
    dep: *std.Build.Dependency,
    /// The sources' directory inside the package, `""` for its root.
    prefix: []const u8,

    /// Resolve the package named `name` and the directory holding its sources.
    ///
    /// - `b`: The build graph.
    /// - `name`: The dependency's name in `build.zig.zon`.
    /// - Returns: The tree; propagates directory-read failures.
    fn init(b: *std.Build, name: []const u8) !Self {
        const dep = b.dependency(name, .{});
        const io = b.graph.io;
        var root = try dep.builder.root.openDir(io, ".", .{ .iterate = true });
        defer root.close(io);
        var only_dir: ?[]const u8 = null;
        var entries: usize = 0;
        var it = root.iterate();
        while (try it.next(io)) |entry| {
            entries += 1;
            if (entry.kind == .directory) only_dir = b.dupe(entry.name);
        }
        const prefix = if (entries == 1 and only_dir != null) only_dir.? else "";
        return .{ .b = b, .dep = dep, .prefix = prefix };
    }

    /// A path into the sources.
    ///
    /// - `rel`: The path relative to the sources' root, `""` for the root.
    /// - Returns: The lazy path.
    fn path(self: *const Self, rel: []const u8) std.Build.LazyPath {
        return self.dep.path(self.relative(rel));
    }

    /// A path into the sources, relative to the package root.
    ///
    /// - `rel`: The path relative to the sources' root.
    /// - Returns: The path below `prefix`.
    fn relative(self: *const Self, rel: []const u8) []const u8 {
        if (self.prefix.len == 0) return if (rel.len == 0) "." else rel;
        if (rel.len == 0) return self.prefix;
        return self.b.fmt("{s}/{s}", .{ self.prefix, rel });
    }

    /// Read a source file at configure time.
    ///
    /// - `rel`: The file, relative to the sources' root.
    /// - Returns: Its contents, owned by the build graph; propagates read failures.
    fn read(self: *const Self, rel: []const u8) ![]u8 {
        const io = self.b.graph.io;
        self.b.dependOnFileContents(self.path(rel));
        var root = try self.dep.builder.root.openDir(io, ".", .{});
        defer root.close(io);
        return root.readFileAlloc(io, self.relative(rel), self.b.allocator, .limited(16 << 20));
    }

    /// Append every file in `dir` with extension `ext`, sorted, as CMake's
    /// `file(GLOB)` does.
    ///
    /// - `files`: The list source-relative paths are appended to.
    /// - `dir`: The directory to read, relative to the sources' root.
    /// - `ext`: The extension to match, including the dot.
    /// - Returns: Nothing; propagates directory-read and allocation failures.
    fn glob(self: *const Self, files: *std.ArrayList([]const u8), dir: []const u8, ext: []const u8) !void {
        try self.list(files, dir, ext, .file);
    }

    /// Append every subdirectory of `dir`, sorted.
    ///
    /// - `dirs`: The list source-relative paths are appended to.
    /// - `dir`: The directory to read, relative to the sources' root.
    /// - Returns: Nothing; propagates directory-read and allocation failures.
    fn subdirs(self: *const Self, dirs: *std.ArrayList([]const u8), dir: []const u8) !void {
        try self.list(dirs, dir, "", .directory);
    }

    /// Append the entries of `dir` of one kind whose names end in `ext`.
    ///
    /// - `out`: The list source-relative paths are appended to.
    /// - `dir`: The directory to read, relative to the sources' root.
    /// - `ext`: The suffix to match; `""` matches all.
    /// - `kind`: The kind of entry to keep.
    /// - Returns: Nothing; propagates directory-read and allocation failures.
    fn list(self: *const Self, out: *std.ArrayList([]const u8), dir: []const u8, ext: []const u8, kind: std.Io.File.Kind) !void {
        const b = self.b;
        const io = b.graph.io;
        // A pinned package cannot change without its hash, but its unpacked
        // copy under zig-pkg/ is an ordinary directory; an edit to it must
        // reconfigure.
        b.dependOnDirectoryContents(self.path(dir));
        var handle = try self.dep.builder.root.openDir(io, self.relative(dir), .{ .iterate = true });
        defer handle.close(io);

        const start = out.items.len;
        var it = handle.iterate();
        while (try it.next(io)) |entry| {
            if (entry.kind != kind) continue;
            if (!std.mem.endsWith(u8, entry.name, ext)) continue;
            try out.append(b.allocator, b.fmt("{s}/{s}", .{ dir, entry.name }));
        }
        std.mem.sort([]const u8, out.items[start..], {}, lessThan);
    }

    /// Order two paths bytewise.
    ///
    /// - `a`: The first path.
    /// - `c`: The second path.
    /// - Returns: True when `a` sorts before `c`.
    fn lessThan(_: void, a: []const u8, c: []const u8) bool {
        return std.mem.order(u8, a, c) == .lt;
    }
};

/// The libraries `addLibraries` builds.
const Libraries = struct {
    const Self = @This();
    ggml_base: *std.Build.Step.Compile,
    ggml_cpu: *std.Build.Step.Compile,
    ggml_metal: ?*std.Build.Step.Compile,
    ggml: *std.Build.Step.Compile,
    stable_diffusion: *std.Build.Step.Compile,

    /// Every library, for installing.
    ///
    /// - `buf`: Storage for the list.
    /// - Returns: The libraries built for this configuration.
    fn all(self: *const Self, buf: *[5]*std.Build.Step.Compile) []const *std.Build.Step.Compile {
        var n: usize = 0;
        for ([_]?*std.Build.Step.Compile{ self.ggml_base, self.ggml_cpu, self.ggml_metal, self.ggml, self.stable_diffusion }) |lib| {
            if (lib) |l| {
                buf[n] = l;
                n += 1;
            }
        }
        return buf[0..n];
    }
};

/// Everything the target-specific decisions were resolved into, computed once
/// by `init`, and the methods that declare every target from them.
const Config = struct {
    const Self = @This();
    /// The build graph every target is declared on.
    b: *std.Build,
    /// What `-Dtarget` and `-Dcpu` resolved to.
    target: std.Build.ResolvedTarget,
    /// What `--release` / `-Doptimize` resolved to.
    optimize: std.lang.Optimize,
    /// The configuration `target`'s OS selects.
    platform: Platform,
    /// The stable-diffusion.cpp sources.
    sd: Tree,
    /// The ggml fork's sources.
    ggml: Tree,
    /// The Apple SDK, resolved by zigbuildx; null off Apple.
    xcode: ?zigbuildx.Xcode = null,
    /// Whether ggml gains its Metal backend (`-Dmetal`, Apple only).
    metal: bool = false,
    /// Apple clang's runtime, `libclang_rt.osx.a`, which every executable
    /// links in place of Zig's compiler-rt; null off macOS. See `addExecutable`.
    apple_rt: ?[]const u8 = null,
    /// ggml's version, from its CMakeLists.txt.
    ggml_version: []const u8,
    /// `-DNDEBUG` in the release modes, as CMake's Release passes it.
    ndebug: []const []const u8,

    /// Resolve the target, the platform and every option into a configuration.
    ///
    /// - `b`: The build graph, whose options are read and which every target
    ///   is later declared on.
    /// - Returns: The configuration; `error.UnsupportedTarget` for an OS or
    ///   architecture this build has no configuration for, and SDK resolution
    ///   and source-read failures.
    fn init(b: *std.Build) !Self {
        // `GGML_NATIVE=OFF`: the CPU baseline, not the host's features. Zig
        // 0.17 recognises the M5 as `apple_m5`, with i8mm and SME, and the
        // native default would compile kernels the CMake reference does not.
        // The macOS floor is the reference's `CMAKE_OSX_DEPLOYMENT_TARGET`.
        const macos_min: std.SemanticVersion = .{ .major = 13, .minor = 0, .patch = 0 };
        const default_target: std.Target.Query = if (b.graph.host.result.os.tag == .macos)
            .{ .cpu_model = .baseline, .os_version_min = .{ .semver = macos_min } }
        else
            .{ .cpu_model = .baseline };
        const target = b.standardTargetOptions(.{ .default_target = default_target });
        const optimize = b.standardOptimizeOption(.{});

        const platform = Platform.detect(target.result) orelse {
            log.err("no configuration for OS '{s}'; this build knows macos and linux", .{@tagName(target.result.os.tag)});
            return error.UnsupportedTarget;
        };
        if (ArchSources.forArch(target.result.cpu.arch) == null) {
            log.err("no configuration for arch '{s}'; ggml's arch sources here are aarch64 and x86_64", .{@tagName(target.result.cpu.arch)});
            return error.UnsupportedTarget;
        }

        const apple = platform == .macos;
        const metal = b.option(bool, "metal", "Build ggml's Metal backend, as SD_METAL (default: on for macOS)") orelse apple;
        if (metal and !apple) {
            log.err("-Dmetal: Metal is Apple's; this target is {s}", .{@tagName(platform)});
            return error.UnsupportedTarget;
        }

        const ggml = try Tree.init(b, "ggml");
        return .{
            .b = b,
            .target = target,
            .optimize = optimize,
            .platform = platform,
            .sd = try Tree.init(b, "stablediffusion_cpp"),
            .ggml = ggml,
            .xcode = if (apple) try zigbuildx.Xcode.initFor(b, target) else null,
            .metal = metal,
            .apple_rt = if (apple) appleRuntime(b) else null,
            .ggml_version = try ggmlVersion(b, &ggml),
            .ndebug = if (optimize == .debug) &.{} else &.{"-DNDEBUG"},
        };
    }

    /// Build every library: ggml's four and libstable-diffusion.
    ///
    /// - Returns: The libraries; propagates directory-read failures.
    fn addLibraries(self: *const Self) !Libraries {
        const ggml_base = self.addGgmlBase();
        const ggml_cpu = self.addGgmlCpu(ggml_base);
        const ggml_metal = if (self.metal) try self.addGgmlMetal(ggml_base) else null;
        const ggml = self.addGgmlReg(ggml_base, ggml_cpu, ggml_metal);
        const stable_diffusion = try self.addStableDiffusion(ggml);
        return .{
            .ggml_base = ggml_base,
            .ggml_cpu = ggml_cpu,
            .ggml_metal = ggml_metal,
            .ggml = ggml,
            .stable_diffusion = stable_diffusion,
        };
    }

    /// Build ggml-base: tensors, graphs, quantization, gguf.
    ///
    /// - Returns: The archive.
    fn addGgmlBase(self: *const Self) *std.Build.Step.Compile {
        const b = self.b;
        const mod = self.baseModule();
        mod.addIncludePath(self.ggml.path("src"));
        // ggml/src/CMakeLists.txt, configure_file(ggml-version.h.in). CMake
        // reads the commit from git, which a tarball does not have.
        mod.addConfigHeader(b.addConfigHeader(.{
            .style = .{ .cmake = self.ggml.path("src/ggml-version.h.in") },
            .include_path = "ggml-version.h",
        }, .{ .GGML_VERSION = self.ggml_version, .GGML_BUILD_COMMIT = Pin.ggml_commit }));
        mod.addIncludePath(self.ggml.path("include"));

        const defs = self.ggmlDefines(&.{});
        mod.addCSourceFiles(.{ .root = self.ggml.path(""), .files = &ggml_base_c, .flags = self.flags(&c_std, defs) });
        mod.addCSourceFiles(.{ .root = self.ggml.path(""), .files = &ggml_base_cxx, .flags = self.flags(&cxx_std, defs) });
        return self.addLibrary("ggml-base", mod);
    }

    /// Build ggml-cpu, the CPU backend, with Accelerate on Apple.
    ///
    /// - `base`: ggml-base.
    /// - Returns: The archive.
    fn addGgmlCpu(self: *const Self, base: *std.Build.Step.Compile) *std.Build.Step.Compile {
        const mod = self.baseModule();
        mod.addIncludePath(self.ggml.path(""));
        mod.addIncludePath(self.ggml.path("src"));
        mod.addIncludePath(self.ggml.path("src/ggml-cpu"));
        mod.addIncludePath(self.ggml.path("include"));

        const apple = self.platform == .macos;
        const defs = self.ggmlDefines(if (apple) &(cpu_defines ++ accelerate_defines) else &cpu_defines);
        const arch = ArchSources.forArch(self.target.result.cpu.arch).?;
        for ([_][]const []const u8{ &ggml_cpu_c, arch.c }) |files| {
            mod.addCSourceFiles(.{ .root = self.ggml.path(""), .files = files, .flags = self.flags(&c_std, defs) });
        }
        for ([_][]const []const u8{ &ggml_cpu_cxx, arch.cxx }) |files| {
            mod.addCSourceFiles(.{ .root = self.ggml.path(""), .files = files, .flags = self.flags(&cxx_std, defs) });
        }
        if (apple) self.linkFramework(mod, "Accelerate");
        mod.linkLibrary(base);
        return self.addLibrary("ggml-cpu", mod);
    }

    /// Build ggml-metal, the Metal backend, its shaders embedded as source
    /// (`GGML_METAL_EMBED_LIBRARY`).
    ///
    /// - `base`: ggml-base.
    /// - Returns: The archive.
    fn addGgmlMetal(self: *const Self, base: *std.Build.Step.Compile) !*std.Build.Step.Compile {
        const b = self.b;
        const mod = self.baseModule();
        mod.addIncludePath(self.ggml.path("src"));
        mod.addIncludePath(self.ggml.path("include"));

        const defs = self.ggmlDefines(&.{"-DGGML_METAL_EMBED_LIBRARY"});
        mod.addCSourceFiles(.{ .root = self.ggml.path(""), .files = &ggml_metal_cxx, .flags = self.flags(&cxx_std, defs) });
        mod.addCSourceFiles(.{ .root = self.ggml.path(""), .files = &ggml_metal_objc, .flags = self.flags(&c_std, defs) });

        // One host tool for every kernel, run once per kernel.
        const tool = b.addExecutable(.{
            .name = "metal_embed",
            .root_module = b.createModule(.{
                .root_source_file = b.path("zig/metal_embed.zig"),
                .target = b.graph.host,
                .optimize = .debug,
            }),
        });
        for (metal_kernels) |kind| mod.addAssemblyFile(self.embedMetalKernel(tool, kind));

        for ([_][]const u8{ "Foundation", "Metal", "MetalKit" }) |fw| self.linkFramework(mod, fw);
        mod.linkLibrary(base);
        return self.addLibrary("ggml-metal", mod);
    }

    /// Build ggml, the library that registers the backends built.
    ///
    /// - `base`: ggml-base.
    /// - `cpu`: ggml-cpu.
    /// - `metal`: ggml-metal, or null without it.
    /// - Returns: The archive.
    fn addGgmlReg(self: *const Self, base: *std.Build.Step.Compile, cpu: *std.Build.Step.Compile, metal: ?*std.Build.Step.Compile) *std.Build.Step.Compile {
        const mod = self.baseModule();
        mod.addIncludePath(self.ggml.path("include"));
        const defs = self.ggmlDefines(self.backendDefines());
        mod.addCSourceFiles(.{ .root = self.ggml.path(""), .files = &ggml_reg_cxx, .flags = self.flags(&cxx_std, defs) });
        mod.linkLibrary(base);
        mod.linkLibrary(cpu);
        if (metal) |m| mod.linkLibrary(m);
        return self.addLibrary("ggml", mod);
    }

    /// Build libstable-diffusion, with the zip, onig and sd-utf8proc objects
    /// CMake folds into it.
    ///
    /// - `ggml`: The ggml library it links.
    /// - Returns: The archive; propagates directory-read failures.
    fn addStableDiffusion(self: *const Self, ggml: *std.Build.Step.Compile) !*std.Build.Step.Compile {
        const b = self.b;
        const mod = self.baseModule();
        const metal_dir = if (self.metal) try self.metalSourceHeader() else null;
        if (metal_dir) |dir| mod.addIncludePath(dir);
        self.addSdIncludes(mod);
        mod.addIncludePath(self.sd.path("thirdparty/oniguruma"));
        mod.addIncludePath(self.sd.path("thirdparty/utf8proc"));

        var files: std.ArrayList([]const u8) = .empty;
        for (sd_glob_dirs) |dir| try self.sd.glob(&files, dir, ".cpp");
        var models: std.ArrayList([]const u8) = .empty;
        try self.sd.subdirs(&models, "src/model");
        for (models.items) |dir| try self.sd.glob(&files, dir, ".cpp");

        var plain: std.ArrayList([]const u8) = .empty;
        for (files.items) |f| {
            if (std.mem.eql(u8, f, sd_version_source) or std.mem.eql(u8, f, sd_extensions_source)) continue;
            try plain.append(b.allocator, f);
        }
        const defs = try join(b, &(global_defines ++ thirdparty_defines), self.backendDefines());
        mod.addCSourceFiles(.{ .root = self.sd.path(""), .files = plain.items, .flags = self.flags(&cxx_std, defs) });

        // CMakeLists.txt:298-302: the version, from the pin rather than git.
        const version_defs = try join(b, defs, &.{
            b.fmt("-DSDCPP_BUILD_COMMIT={s}", .{Pin.commit}),
            b.fmt("-DSDCPP_BUILD_VERSION={s}", .{Pin.tag}),
        });
        mod.addCSourceFiles(.{ .root = self.sd.path(""), .files = &.{sd_version_source}, .flags = self.flags(&cxx_std, version_defs) });

        // CMakeLists.txt:409-414: the backend extension table, only when a
        // backend registers one.
        const registrations = self.backendRegistrations();
        if (registrations.len > 0) {
            const header = b.addConfigHeader(.{
                .style = .{ .cmake = self.sd.path("cmake/backend_extensions.h.in") },
                .include_path = "sd_backend_extensions.h",
            }, .{ .SD_BACKEND_REGISTRATIONS = try std.mem.join(b.allocator, ",\n    ", registrations) });
            mod.addConfigHeader(header);
            const ext_defs = try join(b, defs, &.{"-DSD_BACKEND_EXTENSIONS"});
            mod.addCSourceFiles(.{ .root = self.sd.path(""), .files = &.{sd_extensions_source}, .flags = self.flags(&cxx_std, ext_defs) });
        } else {
            mod.addCSourceFiles(.{ .root = self.sd.path(""), .files = &.{sd_extensions_source}, .flags = self.flags(&cxx_std, defs) });
        }

        // src/core/metal/CMakeLists.txt: sd's own int8 Metal kernels.
        if (self.metal) {
            mod.addCSourceFiles(.{
                .root = self.sd.path(""),
                .files = &.{"src/core/metal/int8.mm"},
                .flags = self.flags(&cxx_std, try join(b, defs, &.{"-fno-objc-arc"})),
            });
            for ([_][]const u8{ "Foundation", "Metal" }) |fw| self.linkFramework(mod, fw);
        }

        mod.addObject(self.addZip());
        mod.addObject(try self.addOnig());
        mod.addObject(self.addUtf8proc());
        mod.linkLibrary(ggml);
        return self.addLibrary("stable-diffusion", mod);
    }

    /// Build the `zip` object library (thirdparty/CMakeLists.txt:1-3).
    ///
    /// - Returns: The objects.
    fn addZip(self: *const Self) *std.Build.Step.Compile {
        const mod = self.baseModule();
        mod.addIncludePath(self.sd.path("thirdparty"));
        mod.addCSourceFiles(.{ .root = self.sd.path(""), .files = &.{"thirdparty/zip.c"}, .flags = self.flags(&c_std, &global_defines) });
        return self.addObject("zip", mod);
    }

    /// Build the `onig` object library, configuring its `config.h` as
    /// `sd_add_oniguruma` does (thirdparty/CMakeLists.txt:5-60).
    ///
    /// - Returns: The objects; propagates allocation failures.
    fn addOnig(self: *const Self) !*std.Build.Step.Compile {
        const b = self.b;
        const t = self.target.result;
        const mod = self.baseModule();
        mod.addIncludePath(self.sd.path("thirdparty/oniguruma"));
        // The header checks all succeed on both platforms; the sizes are the
        // target's. CMake sets USE_CRNL_AS_LINE_TERMINATOR to 0, so it stays
        // undefined.
        mod.addConfigHeader(b.addConfigHeader(.{
            .style = .{ .cmake = self.sd.path("thirdparty/oniguruma/config.h.cmake.in") },
            .include_path = "config.h",
        }, .{
            .CRAY_STACKSEG_END = null,
            .C_ALLOCA = null,
            .HAVE_ALLOCA = 1,
            .HAVE_ALLOCA_H = 1,
            .HAVE_STDINT_H = 1,
            .HAVE_SYS_TIMES_H = 1,
            .HAVE_SYS_TIME_H = 1,
            .HAVE_SYS_TYPES_H = 1,
            .HAVE_UNISTD_H = 1,
            .HAVE_INTTYPES_H = 1,
            .PACKAGE = .onig,
            .PACKAGE_VERSION = .@"6.9.10",
            .SIZEOF_INT = t.cTypeByteSize(.int),
            .SIZEOF_LONG = t.cTypeByteSize(.long),
            .SIZEOF_LONG_LONG = t.cTypeByteSize(.longlong),
            .SIZEOF_VOIDP = t.ptrBitWidth() / 8,
            .USE_CRNL_AS_LINE_TERMINATOR = null,
            .VERSION = .@"6.9.10",
        }));
        const defs = try join(b, &global_defines, &.{"-DONIG_STATIC"});
        mod.addCSourceFiles(.{ .root = self.sd.path(""), .files = &onig_sources, .flags = self.flags(&c_std, defs) });
        return self.addObject("onig", mod);
    }

    /// Build the `sd-utf8proc` object library (thirdparty/CMakeLists.txt:62-65).
    ///
    /// - Returns: The objects.
    fn addUtf8proc(self: *const Self) *std.Build.Step.Compile {
        const mod = self.baseModule();
        mod.addIncludePath(self.sd.path("thirdparty/utf8proc"));
        mod.addCSourceFiles(.{
            .root = self.sd.path(""),
            .files = &.{"thirdparty/utf8proc/utf8proc.c"},
            .flags = self.flags(&c_std, &(global_defines ++ .{"-DUTF8PROC_STATIC"})),
        });
        return self.addObject("sd-utf8proc", mod);
    }

    /// Build sd-cli.
    ///
    /// - `libs`: The libraries it links.
    /// - Returns: The executable; propagates allocation failures.
    fn addCli(self: *const Self, libs: *const Libraries) !*std.Build.Step.Compile {
        const mod = self.baseModule();
        mod.addIncludePath(self.sd.path("examples"));
        mod.addIncludePath(self.sd.path("src"));
        mod.addIncludePath(self.sd.path("include"));
        mod.addIncludePath(self.sd.path("thirdparty"));
        mod.addIncludePath(self.ggml.path("include"));
        const defs = try join(self.b, &global_defines, self.backendDefines());
        mod.addCSourceFiles(.{ .root = self.sd.path(""), .files = &example_common_sources, .flags = self.flags(&cxx_std, defs) });
        mod.addCSourceFiles(.{ .root = self.sd.path(""), .files = &cli_sources, .flags = self.flags(&cxx_std, defs) });
        mod.linkLibrary(libs.stable_diffusion);
        return self.addExecutable("sd-cli", mod);
    }

    /// Build sd-server, API only: its web UI is a submodule the tarball does
    /// not carry, and CMake builds it without one in that case too.
    ///
    /// - `libs`: The libraries it links.
    /// - Returns: The executable; propagates read and allocation failures.
    fn addServer(self: *const Self, libs: *const Libraries) !*std.Build.Step.Compile {
        const b = self.b;
        const mod = self.baseModule();
        mod.addIncludePath(self.sd.path("examples"));
        mod.addIncludePath(try self.serverRecipesHeader());
        mod.addIncludePath(self.sd.path("include"));
        mod.addIncludePath(self.sd.path("thirdparty"));
        mod.addIncludePath(self.ggml.path("include"));
        const defs = try join(b, &global_defines, self.backendDefines());
        mod.addCSourceFiles(.{ .root = self.sd.path(""), .files = &example_common_sources, .flags = self.flags(&cxx_std, defs) });
        mod.addCSourceFiles(.{ .root = self.sd.path(""), .files = &server_sources, .flags = self.flags(&cxx_std, defs) });
        mod.linkLibrary(libs.stable_diffusion);
        return self.addExecutable("sd-server", mod);
    }

    /// Build pixdiff, the image comparer `make verify` runs, for the host.
    ///
    /// - `test_mode`: Build its unit tests instead of the tool.
    /// - Returns: The executable or test.
    fn addPixdiff(self: *const Self, test_mode: bool) *std.Build.Step.Compile {
        const b = self.b;
        const mod = b.createModule(.{
            .root_source_file = b.path("zig/pixdiff.zig"),
            .target = b.graph.host,
            .optimize = .fast,
            .link_libc = true,
        });
        mod.addIncludePath(self.sd.path("thirdparty"));
        mod.addCSourceFiles(.{ .files = &.{"zig/stb_image.c"}, .flags = &c_std });
        if (test_mode) return b.addTest(.{ .root_module = mod });
        return b.addExecutable(.{ .name = "pixdiff", .root_module = mod });
    }

    /// Generate `int8_source.h`, sd's two Metal kernels as string literals, as
    /// src/core/metal/CMakeLists.txt's `configure_file` does.
    ///
    /// - Returns: The directory holding it; propagates read failures.
    fn metalSourceHeader(self: *const Self) !std.Build.LazyPath {
        const b = self.b;
        const header = b.addConfigHeader(.{
            .style = .{ .cmake = self.sd.path("src/core/metal/int8_source.h.in") },
            .include_path = "int8_source.h",
        }, .{
            .SD_METAL_I8_SOURCE = try self.sd.read("src/core/metal/int8.metal"),
            .SD_METAL_I8_MPP_SOURCE = try self.sd.read("src/core/metal/int8_mpp.metal"),
        });
        return header.getOutputDir();
    }

    /// Generate `recipes_builtin.h`, as examples/server/CMakeLists.txt does.
    ///
    /// - Returns: The directory holding it; propagates read failures.
    fn serverRecipesHeader(self: *const Self) !std.Build.LazyPath {
        const b = self.b;
        // Every recipe as its own raw string literal, in glob order.
        var files: std.ArrayList([]const u8) = .empty;
        try self.sd.glob(&files, "examples/server/recipes", ".json");
        var recipes: std.ArrayList(u8) = .empty;
        for (files.items) |file| {
            try recipes.appendSlice(b.allocator, "R\"recipes(");
            try recipes.appendSlice(b.allocator, try self.sd.read(file));
            try recipes.appendSlice(b.allocator, ")recipes\",\n");
        }
        const header = b.addConfigHeader(.{
            .style = .{ .cmake = self.sd.path("examples/server/recipes_builtin.h.in") },
            .include_path = "recipes_builtin.h",
        }, .{ .SD_BUILTIN_RECIPES = recipes.items });
        return header.getOutputDir();
    }

    /// Flatten one Metal kernel and return the assembly stub that embeds it.
    ///
    /// Replaces the `cat`/`sed` pipeline CMake runs under
    /// `GGML_METAL_EMBED_LIBRARY`. The stub `.incbin`s the flattened shader
    /// source; the Metal driver compiles it at load time, so no `xcrun metal`
    /// step is involved.
    ///
    /// - `tool`: `zig/metal_embed.zig`, built for the host.
    /// - `kind`: The kernel, one of `metal_kernels`.
    /// - Returns: The generated assembly stub.
    fn embedMetalKernel(self: *const Self, tool: *std.Build.Step.Compile, kind: []const u8) std.Build.LazyPath {
        const b = self.b;
        const run = b.addRunArtifact(tool);
        run.addArg(kind);
        _ = run.addOutputFileArg2(b.fmt("ggml-metal-embed-{s}.metal", .{kind}), .{});
        const out_asm = run.addOutputFileArg2(b.fmt("ggml-metal-embed-{s}.s", .{kind}), .{});
        for ([_][]const u8{
            "src/ggml-common.h",
            "src/ggml-metal/ggml-metal-impl.h",
            "src/ggml-metal/kernels/common.h",
            "src/ggml-metal/kernels/dequantize.h",
            "src/ggml-metal/kernels/quantize.h",
            "src/ggml-metal/kernels/fa_common.metal",
            "src/ggml-metal/kernels/fa_vec_common.metal",
        }) |rel| run.addFileArg(self.ggml.path(rel));
        run.addFileArg(self.ggml.path(b.fmt("src/ggml-metal/kernels/{s}.metal", .{kind})));
        return out_asm;
    }

    /// Add the include paths libstable-diffusion compiles with
    /// (CMakeLists.txt:423-425), ggml's public headers after them.
    ///
    /// - `mod`: The module that gains them.
    fn addSdIncludes(self: *const Self, mod: *std.Build.Module) void {
        mod.addIncludePath(self.sd.path("include"));
        mod.addIncludePath(self.sd.path("src"));
        mod.addIncludePath(self.sd.path("src/core"));
        mod.addIncludePath(self.sd.path("thirdparty"));
        mod.addIncludePath(self.ggml.path("include"));
    }

    /// The `GGML_USE_<backend>` flags ggml's targets export to everything
    /// linking them (ggml/src/CMakeLists.txt:438).
    ///
    /// - Returns: The `-D` flags.
    fn backendDefines(self: *const Self) []const []const u8 {
        return if (self.metal) &.{ "-DGGML_USE_CPU", "-DGGML_USE_METAL" } else &.{"-DGGML_USE_CPU"};
    }

    /// `SD_BACKEND_REGISTRATIONS` (CMakeLists.txt:387-408): sd's extension
    /// registrations for the backends built.
    ///
    /// - Returns: The functions, in CMake's order.
    fn backendRegistrations(self: *const Self) []const []const u8 {
        return if (self.metal) &.{"sd_ggml_register_metal_i8"} else &.{};
    }

    /// The flags every ggml target compiles with, plus `extra`.
    ///
    /// - `extra`: The target's own `-D` flags.
    /// - Returns: The `-D` flags.
    fn ggmlDefines(self: *const Self, extra: []const []const u8) []const []const u8 {
        const b = self.b;
        var out: std.ArrayList([]const u8) = .empty;
        out.appendSlice(b.allocator, &global_defines) catch @panic("OOM");
        out.appendSlice(b.allocator, &ggml_defines) catch @panic("OOM");
        out.appendSlice(b.allocator, self.platform.posixDefines()) catch @panic("OOM");
        out.appendSlice(b.allocator, extra) catch @panic("OOM");
        return out.items;
    }

    /// A language's flags followed by `defs` and the release-mode `NDEBUG`.
    ///
    /// - `lang`: The language's standard and warning flags.
    /// - `defs`: The target's `-D` flags.
    /// - Returns: The joined flags.
    fn flags(self: *const Self, lang: []const []const u8, defs: []const []const u8) []const []const u8 {
        const b = self.b;
        const mid = join(b, lang, defs) catch @panic("OOM");
        return join(b, mid, self.ndebug) catch @panic("OOM");
    }

    /// A module with the settings every C/C++ target in this build shares.
    ///
    /// - Returns: The module.
    fn baseModule(self: *const Self) *std.Build.Module {
        return self.b.createModule(.{
            .target = self.target,
            .optimize = self.optimize,
            .link_libc = true,
            .link_libcpp = true,
            // These sources are not UBSan-clean, and Zig turns the C
            // sanitizers on in Debug. CMake never enables them.
            .sanitize_c = .off,
        });
    }

    /// Link an Apple SDK framework into `mod`.
    ///
    /// - `mod`: The module.
    /// - `name`: The framework.
    fn linkFramework(self: *const Self, mod: *std.Build.Module, name: []const u8) void {
        if (self.xcode) |*xcode| xcode.linkFramework(mod, name);
    }

    /// Declare a static library, configured for the Apple SDK on Apple.
    ///
    /// - `name`: The library's name.
    /// - `mod`: Its root module.
    /// - Returns: The library.
    fn addLibrary(self: *const Self, name: []const u8, mod: *std.Build.Module) *std.Build.Step.Compile {
        const lib = self.b.addLibrary(.{ .name = name, .root_module = mod, .linkage = .static });
        self.configure(lib);
        return lib;
    }

    /// Declare an object library, configured for the Apple SDK on Apple.
    ///
    /// - `name`: The library's name.
    /// - `mod`: Its root module.
    /// - Returns: The objects.
    fn addObject(self: *const Self, name: []const u8, mod: *std.Build.Module) *std.Build.Step.Compile {
        const obj = self.b.addObject(.{ .name = name, .root_module = mod });
        self.configure(obj);
        return obj;
    }

    /// Declare an executable, configured for the Apple SDK on Apple.
    ///
    /// - `name`: The executable's name.
    /// - `mod`: Its root module.
    /// - Returns: The executable.
    fn addExecutable(self: *const Self, name: []const u8, mod: *std.Build.Module) *std.Build.Step.Compile {
        const exe = self.b.addExecutable(.{ .name = name, .root_module = mod });
        // Zig's compiler-rt carries its own `exp`, `expf`, `log`, `logf`,
        // `sin`, `cos` and more, linked locally, so they would take the place
        // of the system libm's that a CMake build calls. They are correct but
        // round differently in the last bit, and that alone moves pixels. On
        // macOS the executable links what Apple clang links instead: libSystem
        // exports the compiler-rt builtins and the math, and
        // `libclang_rt.osx.a` the rest (`__isPlatformVersionAtLeast`, behind
        // Objective-C's `@available`).
        if (self.apple_rt) |rt| {
            exe.bundle_compiler_rt = false;
            mod.addObjectFile(self.b.graph.cwdRelativePath(rt));
        }
        self.configure(exe);
        return exe;
    }

    /// Point a compile step at the Apple SDK, when there is one.
    ///
    /// - `step`: The library, objects or executable.
    fn configure(self: *const Self, step: *std.Build.Step.Compile) void {
        if (self.xcode) |*xcode| xcode.configure(step) catch @panic("Xcode handle does not match the target");
    }

    /// Locate Apple clang's runtime library, as `clang -print-resource-dir`
    /// reports it.
    ///
    /// - `b`: The build graph.
    /// - Returns: The path of `libclang_rt.osx.a`.
    fn appleRuntime(b: *std.Build) []const u8 {
        const dir = std.mem.trim(u8, b.run(&.{ "xcrun", "clang", "-print-resource-dir" }), " \n");
        const rt = b.pathJoin(&.{ dir, "lib", "darwin", "libclang_rt.osx.a" });
        // The configure cache cannot see xcrun's answer; the path carries the
        // clang version, so an Xcode update removes it and reconfigures.
        b.dependOnFileMetadata(b.graph.cwdRelativePath(rt));
        return rt;
    }

    /// ggml's version, as ggml/CMakeLists.txt:6-8 sets it.
    ///
    /// - `b`: The build graph.
    /// - `ggml`: The ggml sources.
    /// - Returns: `major.minor.patch`; `error.GgmlVersionNotFound` when the
    ///   file no longer sets it that way.
    fn ggmlVersion(b: *std.Build, ggml: *const Tree) ![]const u8 {
        const text = try ggml.read("CMakeLists.txt");
        var parts: [3][]const u8 = undefined;
        for ([_][]const u8{ "MAJOR", "MINOR", "PATCH" }, 0..) |name, i| {
            const key = b.fmt("set(GGML_VERSION_{s} ", .{name});
            const at = std.mem.find(u8, text, key) orelse return error.GgmlVersionNotFound;
            const rest = text[at + key.len ..];
            const end = std.mem.findScalar(u8, rest, ')') orelse return error.GgmlVersionNotFound;
            parts[i] = std.mem.trim(u8, rest[0..end], " ");
        }
        return b.fmt("{s}.{s}.{s}", .{ parts[0], parts[1], parts[2] });
    }

    /// Concatenate two flag lists into one the build graph can hold onto.
    ///
    /// - `b`: The build graph, whose allocator owns the result.
    /// - `a`: The leading flags.
    /// - `c`: The trailing flags.
    /// - Returns: The joined list.
    fn join(b: *std.Build, a: []const []const u8, c: []const []const u8) ![]const []const u8 {
        const out = try b.allocator.alloc([]const u8, a.len + c.len);
        @memcpy(out[0..a.len], a);
        @memcpy(out[a.len..], c);
        return out;
    }
};

/// Declare the build graph.
///
/// - `b`: The build graph the steps are registered on.
/// - Returns: Nothing on success; propagates target, SDK resolution, and
///   directory-read failures.
pub fn build(b: *std.Build) !void {
    zigbuildx.Deps.cloneMissing(b, zon);
    const cfg = try Config.init(b);

    const libs = try cfg.addLibraries();
    const lib_step = b.step("lib", "Build ggml and libstable-diffusion, and install the header");
    var buf: [5]*std.Build.Step.Compile = undefined;
    for (libs.all(&buf)) |lib| {
        const install = b.addInstallArtifact(lib, .{});
        lib_step.dependOn(&install.step);
        b.getInstallStep().dependOn(&install.step);
    }
    const header = b.addInstallHeaderFile(cfg.sd.path("include/stable-diffusion.h"), "stable-diffusion.h");
    lib_step.dependOn(&header.step);
    b.getInstallStep().dependOn(&header.step);

    const cli = try cfg.addCli(&libs);
    b.installArtifact(cli);
    const cli_step = b.step("cli", "Build sd-cli");
    cli_step.dependOn(&b.addInstallArtifact(cli, .{}).step);

    // Not part of the default step: sd-cli is this build's deliverable.
    const server_step = b.step("server", "Build sd-server (API only)");
    server_step.dependOn(&b.addInstallArtifact(try cfg.addServer(&libs), .{}).step);

    const run = b.addRunArtifact(cli);
    run.step.dependOn(b.getInstallStep());
    run.addPassthruArgs();
    const run_step = b.step("run", "Build and run sd-cli");
    run_step.dependOn(&run.step);

    const pixdiff_step = b.step("pixdiff", "Build pixdiff, the image comparer make verify runs");
    pixdiff_step.dependOn(&b.addInstallArtifact(cfg.addPixdiff(false), .{}).step);

    const tests = b.addRunArtifact(cfg.addPixdiff(true));
    tests.has_side_effects = true;
    const test_step = b.step("test", "Run pixdiff's unit tests");
    test_step.dependOn(&tests.step);
}
