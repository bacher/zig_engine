const std = @import("std");
const hash = @import("generation_hash.zig");

pub const CoastIndex = struct {
    seed: u64,
    width: u32,
    height: u32,
    macro_width: u32,
    macro_height: u32,
    owners: []const u8,
    nodes: []u8,
    coarse: []const u16,
    pub const cap = 4096;

    const Box = struct {
        x: u32,
        y: u32,
        w: u32,
        h: u32,
        fn split(self: Box) [2]Box {
            if (self.w >= self.h) {
                const w = (self.w + 1) / 2;
                return .{ .{ .x = self.x, .y = self.y, .w = w, .h = self.h }, .{ .x = self.x + w, .y = self.y, .w = self.w - w, .h = self.h } };
            }
            const h = (self.h + 1) / 2;
            return .{ .{ .x = self.x, .y = self.y, .w = self.w, .h = h }, .{ .x = self.x, .y = self.y + h, .w = self.w, .h = self.h - h } };
        }
        fn count(self: Box) usize {
            return @as(usize, self.w) * self.h;
        }
    };

    pub fn init(allocator: std.mem.Allocator, seed: u64, width: u32, height: u32, owners: []const u8, coarse: []const u16) !CoastIndex {
        const nodes = try allocator.alloc(u8, owners.len * 2 - 1);
        var self = CoastIndex{ .seed = seed, .width = width, .height = height, .macro_width = width / 128, .macro_height = height / 128, .owners = owners, .nodes = nodes, .coarse = coarse };
        self.build(0, self.root());
        return self;
    }
    pub fn deinit(self: *CoastIndex, allocator: std.mem.Allocator) void {
        allocator.free(self.nodes);
    }
    fn root(self: *const CoastIndex) Box {
        return .{ .x = 0, .y = 0, .w = self.macro_width, .h = self.macro_height };
    }
    fn owner(self: *const CoastIndex, x: i64, y: i64) u8 {
        if (y < 0 or y >= self.macro_height) return 0;
        return self.owners[@as(usize, @intCast(y)) * self.macro_width + @as(usize, @intCast(@mod(x, self.macro_width)))];
    }
    fn build(self: *CoastIndex, index: usize, box: Box) void {
        if (box.w == 1 and box.h == 1) {
            const own = self.owner(box.x, box.y);
            self.nodes[index] = @intFromBool(own != 0 and (self.owner(@as(i64, box.x) - 1, box.y) != own or self.owner(@as(i64, box.x) + 1, box.y) != own or self.owner(box.x, @as(i64, box.y) - 1) != own or self.owner(box.x, @as(i64, box.y) + 1) != own));
            return;
        }
        const children = box.split();
        const right = index + children[0].count() * 2;
        self.build(index + 1, children[0]);
        self.build(right, children[1]);
        self.nodes[index] = self.nodes[index + 1] | self.nodes[right];
    }

    fn axisDistance(p: i64, lo: i64, hi: i64) u32 {
        return @intCast(@max(@max(lo - p, p - hi), 0));
    }
    fn rectDistance(x: i64, y: u32, lo_x: i64, lo_y: u32, hi_x: i64, hi_y: u32) u32 {
        return @max(axisDistance(x, lo_x, hi_x), axisDistance(y, lo_y, hi_y));
    }
    fn bound(self: *const CoastIndex, box: Box, x: u32, y: u32) u32 {
        const lo_x: i64 = @as(i64, box.x) * 128;
        const hi_x: i64 = @as(i64, box.x + box.w) * 128 - 1;
        const dy = axisDistance(y, box.y * 128, (box.y + box.h) * 128 - 1);
        return @max(dy, @min(axisDistance(x, lo_x, hi_x), @min(axisDistance(@as(i64, x) - self.width, lo_x, hi_x), axisDistance(@as(i64, x) + self.width, lo_x, hi_x))));
    }

    pub fn distance(self: *const CoastIndex, x: u32, y: u32) u32 {
        const d = self.coarse[(y / 128) * self.macro_width + x / 128];
        if (d >= 66) return cap;
        var best: u32 = cap + 1;
        self.query(0, self.root(), x, y, &best);
        return best -| 1;
    }
    fn query(self: *const CoastIndex, index: usize, box: Box, x: u32, y: u32, best: *u32) void {
        if (self.nodes[index] == 0 or self.bound(box, x, y) >= best.*) return;
        if (box.w == 1 and box.h == 1) {
            for ([_]i64{ @as(i64, x) - self.width, x, @as(i64, x) + self.width }) |px| {
                self.leaf(box, px, y, best);
            }
            return;
        }
        const children = box.split();
        const right = index + children[0].count() * 2;
        const left_bound = self.bound(children[0], x, y);
        const right_bound = self.bound(children[1], x, y);
        if (left_bound <= right_bound) {
            self.query(index + 1, children[0], x, y, best);
            self.query(right, children[1], x, y, best);
        } else {
            self.query(right, children[1], x, y, best);
            self.query(index + 1, children[0], x, y, best);
        }
    }
    fn trim(self: *const CoastIndex, x: u32, y: u32) u32 {
        const n = hash.field2(hash.mix(self.seed ^ 0x434f415354), x % self.width, y, self.width, 256);
        return @intCast(8 + @divTrunc((n + 65535) * 16, 131070));
    }
    fn leaf(self: *const CoastIndex, box: Box, x: i64, y: u32, best: *u32) void {
        const lo_x = box.x * 128;
        const lo_y = box.y * 128;
        const lower = rectDistance(x, y, lo_x, lo_y, lo_x + 127, lo_y + 127);
        if (lower >= best.*) return;
        const own = self.owner(box.x, box.y);
        const exposed = [4]bool{ self.owner(@as(i64, box.x) - 1, box.y) != own, self.owner(@as(i64, box.x) + 1, box.y) != own, self.owner(box.x, @as(i64, box.y) - 1) != own, self.owner(box.x, @as(i64, box.y) + 1) != own };
        const bottom = if (exposed[2]) self.trim(lo_x + 64, lo_y) else 0;
        const top = if (exposed[3]) self.trim(lo_x + 64, lo_y + 127) else 0;
        var low = lower;
        var high = @min(best.* - 1, lower + 127);
        if (!self.intersects(lo_x, lo_y, x, y, high, exposed, bottom, top)) return;
        while (low < high) {
            const mid = low + (high - low) / 2;
            if (self.intersects(lo_x, lo_y, x, y, mid, exposed, bottom, top)) high = mid else low = mid + 1;
        }
        best.* = low;
    }
    fn intersects(self: *const CoastIndex, lo_x: u32, lo_y: u32, x: i64, y: u32, radius: u32, exposed: [4]bool, bottom: u32, top: u32) bool {
        const y0: i64 = @max(lo_y, @as(i64, y) - radius);
        const y1: i64 = @min(lo_y + 127, @as(i64, y) + radius);
        const x0 = @max(lo_x, x - radius);
        const x1 = @min(lo_x + 127, x + radius);
        if (y0 > y1 or x0 > x1) return false;
        if ((bottom > 0 and y0 < lo_y + bottom) or (top > 0 and y1 > lo_y + 127 - top)) return true;
        if (exposed[0]) {
            const left = @max(self.trim(lo_x, @intCast(y0)), self.trim(lo_x, @intCast(y1)));
            if (x0 < lo_x + left) return true;
        }
        if (exposed[1]) {
            const right = @max(self.trim(lo_x + 127, @intCast(y0)), self.trim(lo_x + 127, @intCast(y1)));
            if (x1 > lo_x + 127 - right) return true;
        }
        return false;
    }
};
