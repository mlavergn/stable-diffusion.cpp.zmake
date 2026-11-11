//! Build-time tool that stamps a PNG's physical resolution.
//!
//! `make perf` runs it on each image `sd-cli` writes. `sd-cli` writes an 8-bit
//! RGB PNG with no `pHYs` chunk, so viewers assume their own resolution; this
//! records one, in pixels per metre as PNG stores it, and checks the image is
//! the size and colour type expected. Only the chunk list changes: the pixel
//! data and `sd-cli`'s metadata are copied byte for byte.
//!
//! Usage:
//!   pngphys <image.png> <width> <height> <ppi>
//!
//! Rewrites the file in place. Exits 0 on success, 1 when the image is not an
//! 8-bit RGB PNG of `width` x `height`, and 2 on bad usage or an unreadable
//! or unwritable file.

const std = @import("std");
const log = std.log.scoped(.stablediffusioncpp_pngphys);

/// Logs at info and above; the `@src()` entry traces are debug.
pub const std_options: std.Options = .{ .log_level = .info };

/// The eight bytes every PNG starts with.
const png_signature = [_]u8{ 0x89, 'P', 'N', 'G', '\r', '\n', 0x1a, '\n' };

/// What the image must be, and the resolution to record.
pub const Expect = struct {
    const Self = @This();
    /// The width in pixels.
    width: u32,
    /// The height in pixels.
    height: u32,
    /// The resolution, in pixels per inch.
    ppi: u32,

    /// The resolution in pixels per metre, the unit PNG's `pHYs` stores,
    /// rounded to the nearest (72 ppi is 2835).
    ///
    /// - Returns: Pixels per metre.
    pub fn pixelsPerMetre(self: *const Self) u32 {
        return @intFromFloat(@round(@as(f64, @floatFromInt(self.ppi)) / 0.0254));
    }
};

/// Checks a PNG's shape and rewrites its chunk list with a `pHYs` chunk.
pub const PngPhys = struct {
    const Self = @This();
    /// Allocates the rewritten image.
    allocator: std.mem.Allocator,

    /// Create a stamper.
    ///
    /// - `allocator`: Allocates the images `stamp` returns.
    /// - Returns: The stamper.
    pub fn init(allocator: std.mem.Allocator) Self {
        log.debug("{s}:{d} :: {s}", .{ @src().file, @src().line, @src().fn_name });
        return .{ .allocator = allocator };
    }

    /// Release the stamper; it owns nothing beyond its calls.
    pub fn deinit(self: *Self) void {
        log.debug("{s}:{d} :: {s}", .{ @src().file, @src().line, @src().fn_name });
        _ = self;
    }

    /// Check `png` against `expect` and return it with a `pHYs` chunk for
    /// `expect.ppi` right after `IHDR`, replacing any it had.
    ///
    /// - `png`: The PNG file's bytes.
    /// - `expect`: The required shape and the resolution to record.
    /// - Returns: The new file's bytes, owned by the caller; `error.NotPng`
    ///   or `error.Truncated` for a malformed file, `error.WrongSize` or
    ///   `error.NotRgb8` for one of another shape.
    pub fn stamp(self: *const Self, png: []const u8, expect: Expect) ![]u8 {
        log.debug("{s}:{d} :: {s}", .{ @src().file, @src().line, @src().fn_name });
        if (png.len < png_signature.len or !std.mem.eql(u8, png[0..png_signature.len], &png_signature)) return error.NotPng;

        var out: std.ArrayList(u8) = .empty;
        errdefer out.deinit(self.allocator);
        try out.appendSlice(self.allocator, &png_signature);

        var at: usize = png_signature.len;
        var first = true;
        while (at < png.len) {
            if (png.len - at < 12) return error.Truncated;
            const len = std.mem.readInt(u32, png[at..][0..4], .big);
            if (png.len - at - 12 < len) return error.Truncated;
            const kind = png[at + 4 ..][0..4];
            const chunk = png[at .. at + 12 + len];
            at += 12 + len;

            if (first) {
                if (!std.mem.eql(u8, kind, "IHDR") or len < 13) return error.NotPng;
                const data = chunk[8..][0..13];
                const width = std.mem.readInt(u32, data[0..4], .big);
                const height = std.mem.readInt(u32, data[4..8], .big);
                if (width != expect.width or height != expect.height) return error.WrongSize;
                // Bit depth 8, colour type 2: truecolour without alpha.
                if (data[8] != 8 or data[9] != 2) return error.NotRgb8;
                try out.appendSlice(self.allocator, chunk);
                try self.appendPhys(&out, expect.pixelsPerMetre());
                first = false;
                continue;
            }
            if (std.mem.eql(u8, kind, "pHYs")) continue;
            try out.appendSlice(self.allocator, chunk);
        }
        if (first) return error.NotPng;
        return out.toOwnedSlice(self.allocator);
    }

    /// Append a `pHYs` chunk: the same density on both axes, unit metre.
    ///
    /// - `out`: The file being written.
    /// - `ppm`: Pixels per metre.
    /// - Returns: Nothing; propagates allocation failures.
    fn appendPhys(self: *const Self, out: *std.ArrayList(u8), ppm: u32) !void {
        var chunk: [21]u8 = undefined;
        std.mem.writeInt(u32, chunk[0..4], 9, .big);
        @memcpy(chunk[4..8], "pHYs");
        std.mem.writeInt(u32, chunk[8..12], ppm, .big);
        std.mem.writeInt(u32, chunk[12..16], ppm, .big);
        chunk[16] = 1;
        std.mem.writeInt(u32, chunk[17..21], std.hash.Crc32.hash(chunk[4..17]), .big);
        try out.appendSlice(self.allocator, &chunk);
    }
};

/// Stamp the image the command line names and report the result.
///
/// - `init`: Process capabilities supplied by the runtime (allocator, I/O, args).
/// - Returns: Nothing; exits 1 when the image has the wrong shape and 2 on bad
///   usage or an unreadable or unwritable file.
pub fn main(init: std.process.Init) !void {
    log.debug("{s}:{d} :: {s}", .{ @src().file, @src().line, @src().fn_name });
    const arena = init.arena.allocator();
    const args = try init.minimal.args.toSlice(arena);
    if (args.len != 5) {
        log.err("usage: pngphys <image.png> <width> <height> <ppi>", .{});
        std.process.exit(2);
    }
    const expect: Expect = .{
        .width = std.fmt.parseInt(u32, args[2], 10) catch std.process.exit(2),
        .height = std.fmt.parseInt(u32, args[3], 10) catch std.process.exit(2),
        .ppi = std.fmt.parseInt(u32, args[4], 10) catch std.process.exit(2),
    };

    const path = args[1];
    const io = init.io;
    const png = std.Io.Dir.cwd().readFileAlloc(io, path, arena, .limited(256 << 20)) catch |err| {
        log.err("cannot read {s} [{any}]", .{ path, err });
        std.process.exit(2);
    };

    var stamper = PngPhys.init(init.gpa);
    defer stamper.deinit();
    const out = stamper.stamp(png, expect) catch |err| switch (err) {
        error.WrongSize, error.NotRgb8 => {
            log.err("{s} is not a {d}x{d} 8-bit RGB PNG [{any}]", .{ path, expect.width, expect.height, err });
            std.process.exit(1);
        },
        else => {
            log.err("cannot stamp {s} [{any}]", .{ path, err });
            std.process.exit(2);
        },
    };
    defer init.gpa.free(out);
    std.Io.Dir.cwd().writeFile(io, .{ .sub_path = path, .data = out }) catch |err| {
        log.err("cannot write {s} [{any}]", .{ path, err });
        std.process.exit(2);
    };
    log.info("{s}: {d}x{d} RGB, {d} ppi", .{ path, expect.width, expect.height, expect.ppi });
}

// -----------------------------------------------------------------------------
// Unit Tests

/// A minimal PNG header for tests: the signature and an `IHDR` chunk, then a
/// `pHYs` chunk at 1 pixel per metre and an empty `IEND` (CRCs zeroed; the
/// tool copies chunks without checking them).
///
/// - `width`: The `IHDR` width.
/// - `height`: The `IHDR` height.
/// - `colour_type`: The `IHDR` colour type.
/// - Returns: The bytes.
fn testPng(width: u32, height: u32, colour_type: u8) [8 + 25 + 21 + 12]u8 {
    var png: [8 + 25 + 21 + 12]u8 = @splat(0);
    @memcpy(png[0..8], &png_signature);
    std.mem.writeInt(u32, png[8..12], 13, .big);
    @memcpy(png[12..16], "IHDR");
    std.mem.writeInt(u32, png[16..20], width, .big);
    std.mem.writeInt(u32, png[20..24], height, .big);
    png[24] = 8;
    png[25] = colour_type;
    std.mem.writeInt(u32, png[33..37], 9, .big);
    @memcpy(png[37..41], "pHYs");
    std.mem.writeInt(u32, png[41..45], 1, .big);
    std.mem.writeInt(u32, png[45..49], 1, .big);
    png[49] = 1;
    @memcpy(png[58..62], "IEND");
    return png;
}

test "72 ppi is 2835 pixels per metre" {
    const expect: Expect = .{ .width = 1, .height = 1, .ppi = 72 };
    try std.testing.expectEqual(@as(u32, 2835), expect.pixelsPerMetre());
}

test "stamps pHYs after IHDR and drops the old one" {
    var stamper = PngPhys.init(std.testing.allocator);
    defer stamper.deinit();
    const png = testPng(1024, 1024, 2);
    const out = try stamper.stamp(&png, .{ .width = 1024, .height = 1024, .ppi = 72 });
    defer std.testing.allocator.free(out);

    try std.testing.expectEqual(png.len, out.len);
    try std.testing.expectEqualSlices(u8, png[0..33], out[0..33]);
    try std.testing.expectEqualStrings("pHYs", out[37..41]);
    try std.testing.expectEqual(@as(u32, 2835), std.mem.readInt(u32, out[41..45], .big));
    try std.testing.expectEqual(@as(u32, 2835), std.mem.readInt(u32, out[45..49], .big));
    try std.testing.expectEqual(@as(u8, 1), out[49]);
    try std.testing.expectEqual(std.hash.Crc32.hash(out[37..50]), std.mem.readInt(u32, out[50..54], .big));
    try std.testing.expectEqualStrings("IEND", out[58..62]);
}

test "rejects the wrong size or colour type" {
    var stamper = PngPhys.init(std.testing.allocator);
    defer stamper.deinit();
    const expect: Expect = .{ .width = 1024, .height = 1024, .ppi = 72 };
    const small = testPng(512, 512, 2);
    try std.testing.expectError(error.WrongSize, stamper.stamp(&small, expect));
    const rgba = testPng(1024, 1024, 6);
    try std.testing.expectError(error.NotRgb8, stamper.stamp(&rgba, expect));
    try std.testing.expectError(error.NotPng, stamper.stamp("not a png", expect));
}
