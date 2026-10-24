const std = @import("std");
const hash = @import("generation_hash.zig");

/// Approximate mainland relief scalar. Ownership/refinement still decides land.
/// The conservative near-shore collar is at most16 blocks wider than true water.
pub const CoastApprox = struct {
    width: u32,
    macro_width: u32,
    macro_height: u32,
    coarse: []const u16,
    /// Four exposed-edge bits followed by a five-bit maximum fringe width.
    features: []u16,
    pub const cap = 4096;
    pub const Sample = struct { local: u32, broad: u32, coast: u32 };

    pub fn init(allocator: std.mem.Allocator, seed: u64, width: u32, height: u32, owners: []const u8, coarse: []const u16) !CoastApprox {
        const mw = width / 128;
        const mh = height / 128;
        const features = try allocator.alloc(u16, owners.len);
        for (owners, 0..) |owner, i| {
            features[i] = 0;
            if (owner == 0) continue;
            const mx: u32 = @intCast(i % mw);
            const my: u32 = @intCast(i / mw);
            const x = mx * 128;
            const y = my * 128;
            const left_x = if (mx == 0) mw - 1 else mx - 1;
            const right_x = if (mx + 1 == mw) 0 else mx + 1;
            const exposed = [4]bool{
                owners[@as(usize, my) * mw + left_x] != owner,
                owners[@as(usize, my) * mw + right_x] != owner,
                my == 0 or owners[@as(usize, my - 1) * mw + mx] != owner,
                my + 1 == mh or owners[@as(usize, my + 1) * mw + mx] != owner,
            };
            var mask: u16 = 0;
            var maximum: u32 = 0;
            if (exposed[0]) {
                mask |= 1;
                maximum = @max(maximum, @max(trim(seed, width, x, y), trim(seed, width, x, y + 127)));
            }
            if (exposed[1]) {
                mask |= 2;
                maximum = @max(maximum, @max(trim(seed, width, x + 127, y), trim(seed, width, x + 127, y + 127)));
            }
            if (exposed[2]) {
                mask |= 4;
                maximum = @max(maximum, trim(seed, width, x + 64, y));
            }
            if (exposed[3]) {
                mask |= 8;
                maximum = @max(maximum, trim(seed, width, x + 64, y + 127));
            }
            features[i] = mask | @as(u16, @intCast(maximum << 4));
        }
        return .{ .width = width, .macro_width = mw, .macro_height = mh, .coarse = coarse, .features = features };
    }

    pub fn deinit(self: *CoastApprox, allocator: std.mem.Allocator) void {
        allocator.free(self.features);
    }

    fn trim(seed: u64, width: u32, x: u32, y: u32) u32 {
        const n = hash.field2(hash.mix(seed ^ 0x434f415354), x % width, y, width, 256);
        return @intCast(8 + @divTrunc((n + 65535) * 16, 131070));
    }

    fn rectangle(x: i64, y: i64, x0: i64, y0: i64, x1: i64, y1: i64) u32 {
        return @intCast(@max(@max(@max(x0 - x, x - x1), @max(y0 - y, y - y1)), 0));
    }

    pub fn distance(self: *const CoastApprox, x: u32, y: u32) u32 {
        return self.sample(x, y).coast;
    }

    pub fn sample(self: *const CoastApprox, x: u32, y: u32) Sample {
        const mx = x / 128;
        const my = y / 128;
        const columns = [3]u32{ if (mx == 0) self.macro_width - 1 else mx - 1, mx, if (mx + 1 == self.macro_width) 0 else mx + 1 };
        var d: [9]u32 = undefined;
        var nearest: u32 = 129;
        for (0..3) |oy| {
            const row = @as(i64, my) + @as(i64, @intCast(oy)) - 1;
            if (row < 0 or row >= self.macro_height) {
                d[oy * 3] = 0;
                d[oy * 3 + 1] = 0;
                d[oy * 3 + 2] = 0;
                continue;
            }
            for (columns, 0..) |column, ox| {
                const index = @as(usize, @intCast(row)) * self.macro_width + column;
                d[oy * 3 + ox] = self.coarse[index];
                const feature = self.features[index];
                if (feature == 0) continue;
                const m: i64 = @intCast(feature >> 4);
                const x0 = (@as(i64, mx) + @as(i64, @intCast(ox)) - 1) * 128;
                const y0 = row * 128;
                if (feature & 1 != 0) nearest = @min(nearest, rectangle(x, y, x0, y0, x0 + m - 1, y0 + 127));
                if (feature & 2 != 0) nearest = @min(nearest, rectangle(x, y, x0 + 128 - m, y0, x0 + 127, y0 + 127));
                if (feature & 4 != 0) nearest = @min(nearest, rectangle(x, y, x0, y0, x0 + 127, y0 + m - 1));
                if (feature & 8 != 0) nearest = @min(nearest, rectangle(x, y, x0, y0 + 128 - m, x0 + 127, y0 + 127));
            }
        }
        const v00 = @min(4098, @min(@min(d[0], d[1]), @min(d[3], d[4])) * 128);
        const v10 = @min(4098, @min(@min(d[1], d[2]), @min(d[4], d[5])) * 128);
        const v01 = @min(4098, @min(@min(d[3], d[4]), @min(d[6], d[7])) * 128);
        const v11 = @min(4098, @min(@min(d[4], d[5]), @min(d[7], d[8])) * 128);
        const lx = x % 128;
        const ly = y % 128;
        // One final floor of the shared bilinear polynomial preserves its
        // per-axis slope bound. Intermediate interpolation floors would not.
        const broad = (v00 * (128 - lx) * (128 - ly) + v10 * lx * (128 - ly) + v01 * (128 - lx) * ly + v11 * lx * ly) / (128 * 128);
        const local = nearest -| 1;
        return .{ .local = local, .broad = broad, .coast = @min(cap, local + (broad -| 130)) };
    }
};
