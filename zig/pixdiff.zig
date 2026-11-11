//! Build-time tool that compares the pixels of two images.
//!
//! `make verify` runs it on each pair of images the CMake reference `sd-cli`
//! and this build's `sd-cli` generate. It compares decoded pixels, never file
//! bytes: `sd-cli` writes the generation parameters and its own version into
//! the PNG's metadata, and those differ between the two builds by design.
//!
//! Images are decoded by stb_image from the pinned sources' `thirdparty/`,
//! the decoder `sd-cli` itself reads images with.
//!
//! Usage:
//!   pixdiff <reference.png> <test.png>
//!
//! Exits 0 when the images are identical, 1 when they differ, and 2 when
//! either cannot be read.

const std = @import("std");
const log = std.log.scoped(.stablediffusioncpp_pixdiff);

/// Logs at info and above; the `@src()` entry traces are debug.
pub const std_options: std.Options = .{ .log_level = .info };

/// stb_image's C API, compiled from `zig/stb_image.c`.
const Stbi = struct {
    extern fn stbi_load(filename: [*:0]const u8, x: *c_int, y: *c_int, channels: *c_int, desired_channels: c_int) callconv(.c) ?[*]u8;
    extern fn stbi_image_free(data: ?*anyopaque) callconv(.c) void;
    extern fn stbi_failure_reason() callconv(.c) ?[*:0]const u8;
};

/// One decoded image, its pixels stored row by row, `channels` bytes each.
pub const Image = struct {
    const Self = @This();
    width: usize,
    height: usize,
    channels: usize,
    pixels: []const u8,

    /// The byte offset of the pixel at (`x`, `y`).
    ///
    /// - `x`: The column.
    /// - `y`: The row.
    /// - Returns: The offset of its first channel in `pixels`.
    pub fn offset(self: *const Self, x: usize, y: usize) usize {
        return (y * self.width + x) * self.channels;
    }
};

/// What comparing two images found.
pub const Report = struct {
    const Self = @This();
    /// Whether width, height and channel count all match. When they do not,
    /// no pixel is compared.
    same_shape: bool = true,
    /// How many pixels differ in at least one channel.
    differing: usize = 0,
    /// The first differing pixel in row order, as (x, y).
    first: ?[2]usize = null,
    /// The largest difference in any one channel.
    max_delta: u8 = 0,

    /// Whether the images are identical.
    ///
    /// - Returns: True when the shapes match and no pixel differs.
    pub fn identical(self: *const Self) bool {
        return self.same_shape and self.differing == 0;
    }
};

/// Decodes images and compares their pixels.
pub const PixDiff = struct {
    const Self = @This();
    allocator: std.mem.Allocator,

    /// Create a comparer.
    ///
    /// - `allocator`: Allocates the C strings paths are passed to stb_image as.
    /// - Returns: The comparer.
    pub fn init(allocator: std.mem.Allocator) Self {
        log.debug("{s}:{d} :: {s}", .{ @src().file, @src().line, @src().fn_name });
        return .{ .allocator = allocator };
    }

    /// Release the comparer; it owns nothing beyond its calls.
    pub fn deinit(self: *Self) void {
        log.debug("{s}:{d} :: {s}", .{ @src().file, @src().line, @src().fn_name });
        _ = self;
    }

    /// Decode the image at `path` with its own channel count.
    ///
    /// - `path`: The image file.
    /// - Returns: The image, released with `unload`; `error.DecodeFailed`
    ///   when stb_image cannot read it.
    pub fn load(self: *const Self, path: []const u8) !Image {
        log.debug("{s}:{d} :: {s}", .{ @src().file, @src().line, @src().fn_name });
        const path_z = try self.allocator.dupeSentinel(u8, path, 0);
        defer self.allocator.free(path_z);
        var width: c_int = 0;
        var height: c_int = 0;
        var channels: c_int = 0;
        const data = Stbi.stbi_load(path_z.ptr, &width, &height, &channels, 0) orelse {
            const reason = if (Stbi.stbi_failure_reason()) |r| std.mem.span(r) else "unknown";
            log.err("cannot decode {s} [{s}]", .{ path, reason });
            return error.DecodeFailed;
        };
        const w: usize = @intCast(width);
        const h: usize = @intCast(height);
        const c: usize = @intCast(channels);
        return .{ .width = w, .height = h, .channels = c, .pixels = data[0 .. w * h * c] };
    }

    /// Release an image `load` decoded.
    ///
    /// - `image`: The image; its pixels are invalid afterwards.
    pub fn unload(self: *const Self, image: *Image) void {
        log.debug("{s}:{d} :: {s}", .{ @src().file, @src().line, @src().fn_name });
        _ = self;
        Stbi.stbi_image_free(@ptrCast(@constCast(image.pixels.ptr)));
        image.pixels = &.{};
    }

    /// Compare two images pixel by pixel.
    ///
    /// - `reference`: The image expected.
    /// - `candidate`: The image under test.
    /// - Returns: What differs between them.
    pub fn compare(self: *const Self, reference: *const Image, candidate: *const Image) Report {
        log.debug("{s}:{d} :: {s}", .{ @src().file, @src().line, @src().fn_name });
        _ = self;
        var report: Report = .{};
        if (reference.width != candidate.width or reference.height != candidate.height or reference.channels != candidate.channels) {
            report.same_shape = false;
            return report;
        }
        for (0..reference.height) |y| {
            for (0..reference.width) |x| {
                const at = reference.offset(x, y);
                const a = reference.pixels[at..][0..reference.channels];
                const b = candidate.pixels[at..][0..reference.channels];
                if (std.mem.eql(u8, a, b)) continue;
                report.differing += 1;
                if (report.first == null) report.first = .{ x, y };
                for (a, b) |ca, cb| {
                    const delta = if (ca > cb) ca - cb else cb - ca;
                    report.max_delta = @max(report.max_delta, delta);
                }
            }
        }
        return report;
    }
};

/// Compare the two images the command line names and report the result.
///
/// - `init`: Process capabilities supplied by the runtime (allocator, I/O, args).
/// - Returns: Nothing; exits 1 when the images differ and 2 on bad usage or
///   an unreadable image.
pub fn main(init: std.process.Init) !void {
    log.debug("{s}:{d} :: {s}", .{ @src().file, @src().line, @src().fn_name });
    const args = try init.minimal.args.toSlice(init.arena.allocator());
    if (args.len != 3) {
        log.err("usage: pixdiff <reference.png> <test.png>", .{});
        std.process.exit(2);
    }

    var differ = PixDiff.init(init.gpa);
    defer differ.deinit();
    var reference = differ.load(args[1]) catch std.process.exit(2);
    defer differ.unload(&reference);
    var candidate = differ.load(args[2]) catch std.process.exit(2);
    defer differ.unload(&candidate);

    const report = differ.compare(&reference, &candidate);
    if (report.identical()) {
        log.info("identical: {d}x{d}, {d} channels", .{ reference.width, reference.height, reference.channels });
        return;
    }
    if (!report.same_shape) {
        log.err("shape differs: {d}x{d}x{d} vs {d}x{d}x{d}", .{
            reference.width, reference.height, reference.channels,
            candidate.width, candidate.height, candidate.channels,
        });
    } else {
        const first = report.first.?;
        log.err("{d} of {d} pixels differ; first at ({d}, {d}); max channel delta {d}", .{
            report.differing, reference.width * reference.height, first[0], first[1], report.max_delta,
        });
    }
    std.process.exit(1);
}

// -----------------------------------------------------------------------------
// Unit Tests

test "identical images" {
    var differ = PixDiff.init(std.testing.allocator);
    defer differ.deinit();
    const pixels = [_]u8{ 1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12 };
    const a: Image = .{ .width = 2, .height = 2, .channels = 3, .pixels = &pixels };
    const b: Image = .{ .width = 2, .height = 2, .channels = 3, .pixels = &pixels };
    const report = differ.compare(&a, &b);
    try std.testing.expect(report.identical());
    try std.testing.expectEqual(@as(usize, 0), report.differing);
    try std.testing.expectEqual(@as(?[2]usize, null), report.first);
}

test "one differing pixel" {
    var differ = PixDiff.init(std.testing.allocator);
    defer differ.deinit();
    const ref_pixels = [_]u8{ 1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12 };
    const test_pixels = [_]u8{ 1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 15, 12 };
    const a: Image = .{ .width = 2, .height = 2, .channels = 3, .pixels = &ref_pixels };
    const b: Image = .{ .width = 2, .height = 2, .channels = 3, .pixels = &test_pixels };
    const report = differ.compare(&a, &b);
    try std.testing.expect(!report.identical());
    try std.testing.expectEqual(@as(usize, 1), report.differing);
    try std.testing.expectEqual([2]usize{ 1, 1 }, report.first.?);
    try std.testing.expectEqual(@as(u8, 4), report.max_delta);
}

test "shape mismatch" {
    var differ = PixDiff.init(std.testing.allocator);
    defer differ.deinit();
    const pixels = [_]u8{ 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0 };
    const a: Image = .{ .width = 2, .height = 2, .channels = 3, .pixels = &pixels };
    const b: Image = .{ .width = 4, .height = 1, .channels = 3, .pixels = &pixels };
    const report = differ.compare(&a, &b);
    try std.testing.expect(!report.same_shape);
    try std.testing.expect(!report.identical());
}
