//! Bounds one preparation's additional requested allocation capacity. Containers
//! use the backing allocator after return; this proxy owns no allocation itself.
const std = @import("std");

pub const Window = struct {
    backing: std.mem.Allocator,
    limit: usize,
    used: usize = 0,
    peak: usize = 0,
    rejected: bool = false,

    pub fn allocator(self: *Window) std.mem.Allocator {
        return .{ .ptr = self, .vtable = &vtable };
    }

    fn charge(self: *Window, n: usize) bool {
        if (n > self.limit -| self.used) {
            self.rejected = true;
            return false;
        }
        self.used += n;
        self.peak = @max(self.peak, self.used);
        return true;
    }

    const vtable: std.mem.Allocator.VTable = .{ .alloc = alloc, .resize = resize, .remap = remap, .free = free };
    fn cast(raw: *anyopaque) *Window {
        return @ptrCast(@alignCast(raw));
    }
    fn alloc(raw: *anyopaque, n: usize, alignment: std.mem.Alignment, ra: usize) ?[*]u8 {
        const self = cast(raw);
        if (!self.charge(n)) return null;
        return self.backing.rawAlloc(n, alignment, ra) orelse {
            self.used -= n;
            return null;
        };
    }
    fn resize(raw: *anyopaque, memory: []u8, alignment: std.mem.Alignment, n: usize, ra: usize) bool {
        const self = cast(raw);
        const growth = n -| memory.len;
        if (!self.charge(growth)) return false;
        if (!self.backing.rawResize(memory, alignment, n, ra)) {
            self.used -= growth;
            return false;
        }
        self.used -= memory.len -| n;
        return true;
    }
    fn remap(raw: *anyopaque, memory: []u8, alignment: std.mem.Alignment, n: usize, ra: usize) ?[*]u8 {
        const self = cast(raw);
        const growth = n -| memory.len;
        if (!self.charge(growth)) return null;
        const result = self.backing.rawRemap(memory, alignment, n, ra) orelse {
            self.used -= growth;
            return null;
        };
        self.used -= memory.len -| n;
        return result;
    }
    fn free(raw: *anyopaque, memory: []u8, alignment: std.mem.Alignment, ra: usize) void {
        const self = cast(raw);
        self.backing.rawFree(memory, alignment, ra);
        std.debug.assert(self.used >= memory.len);
        self.used -= memory.len;
    }
};

test "preparation allocation window accepts equality and bounds reallocating peak" {
    var window: Window = .{ .backing = std.testing.allocator, .limit = 32 };
    const a = window.allocator();
    const exact = try a.alloc(u8, 32);
    try std.testing.expectError(error.OutOfMemory, a.alloc(u8, 1));
    a.free(exact);
    try std.testing.expectEqual(@as(usize, 0), window.used);
    try std.testing.expectEqual(@as(usize, 32), window.peak);
    // Successful preparation transfers ordinary backing allocations to callers.
    const transferred = try a.alloc(u8, 17);
    std.testing.allocator.free(transferred);
}
