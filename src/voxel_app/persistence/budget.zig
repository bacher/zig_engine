//! Capacity accounting for buffers owned by one service domain. Allocation sizes
//! include ArrayList/hash-map spare capacity because accounting is below containers.
//! Every owned allocation must be released through this budget, never its backing
//! allocator. The budget object must stay at a stable address until all owners end.
const std = @import("std");
pub const Stats = struct { used: usize, peak: usize, limit: usize, allocations: u64, rejections: u64 };
pub const Budget = struct {
    backing: std.mem.Allocator,
    limit: usize,
    used: std.atomic.Value(usize) = .init(0),
    peak: std.atomic.Value(usize) = .init(0),
    allocations: std.atomic.Value(u64) = .init(0),
    rejections: std.atomic.Value(u64) = .init(0),
    pub fn init(backing: std.mem.Allocator, limit: usize) Budget {
        return .{ .backing = backing, .limit = limit };
    }
    pub fn allocator(self: *Budget) std.mem.Allocator {
        return .{ .ptr = self, .vtable = &vtable };
    }
    pub fn stats(self: *const Budget) Stats {
        return .{ .used = self.used.load(.acquire), .peak = self.peak.load(.acquire), .limit = self.limit, .allocations = self.allocations.load(.monotonic), .rejections = self.rejections.load(.monotonic) };
    }
    fn charge(self: *Budget, n: usize) bool {
        var old = self.used.load(.monotonic);
        while (true) {
            if (n > self.limit - old) {
                _ = self.rejections.fetchAdd(1, .monotonic);
                return false;
            }
            if (self.used.cmpxchgWeak(old, old + n, .acq_rel, .monotonic)) |actual| {
                old = actual;
                continue;
            }
            var peak = self.peak.load(.monotonic);
            while (peak < old + n) {
                if (self.peak.cmpxchgWeak(peak, old + n, .monotonic, .monotonic)) |actual| {
                    peak = actual;
                } else break;
            }
            return true;
        }
    }
    fn release(self: *Budget, n: usize) void {
        const prior = self.used.fetchSub(n, .acq_rel);
        std.debug.assert(prior >= n);
    }
    /// Reserve operation capacity before mutation. Allocate with token.allocator(),
    /// then retain/free the resulting buffers through Budget.allocator(). Finish
    /// the token once preparation ends; unused reservation returns automatically.
    pub fn reserve(self: *Budget, n: usize) error{OutOfMemory}!Reservation {
        if (!self.charge(n)) return error.OutOfMemory;
        return .{ .budget = self, .remaining = n };
    }
    const vtable: std.mem.Allocator.VTable = .{ .alloc = alloc, .resize = resize, .remap = remap, .free = free };
    fn cast(context: *anyopaque) *Budget {
        return @ptrCast(@alignCast(context));
    }
    fn alloc(context: *anyopaque, len: usize, alignment: std.mem.Alignment, ra: usize) ?[*]u8 {
        const self = cast(context);
        if (!self.charge(len)) return null;
        const memory = self.backing.rawAlloc(len, alignment, ra) orelse {
            self.release(len);
            return null;
        };
        _ = self.allocations.fetchAdd(1, .monotonic);
        return memory;
    }
    fn resize(context: *anyopaque, memory: []u8, alignment: std.mem.Alignment, new_len: usize, ra: usize) bool {
        const self = cast(context);
        const growth = new_len -| memory.len;
        if (growth > 0 and !self.charge(growth)) return false;
        if (!self.backing.rawResize(memory, alignment, new_len, ra)) {
            self.release(growth);
            return false;
        }
        if (new_len < memory.len) self.release(memory.len - new_len);
        return true;
    }
    fn remap(context: *anyopaque, memory: []u8, alignment: std.mem.Alignment, new_len: usize, ra: usize) ?[*]u8 {
        const self = cast(context);
        const growth = new_len -| memory.len;
        if (growth > 0 and !self.charge(growth)) return null;
        const result = self.backing.rawRemap(memory, alignment, new_len, ra) orelse {
            self.release(growth);
            return null;
        };
        if (new_len < memory.len) self.release(memory.len - new_len);
        return result;
    }
    fn free(context: *anyopaque, memory: []u8, alignment: std.mem.Alignment, ra: usize) void {
        const self = cast(context);
        self.backing.rawFree(memory, alignment, ra);
        self.release(memory.len);
    }
};
pub const Reservation = struct {
    budget: *Budget,
    remaining: usize,
    pub fn allocator(self: *Reservation) std.mem.Allocator {
        return .{ .ptr = self, .vtable = &vtable };
    }
    pub fn deinit(self: *Reservation) void {
        self.budget.release(self.remaining);
        self.remaining = 0;
    }
    const vtable: std.mem.Allocator.VTable = .{ .alloc = alloc, .resize = resize, .remap = remap, .free = free };
    fn cast(context: *anyopaque) *Reservation {
        return @ptrCast(@alignCast(context));
    }
    fn alloc(context: *anyopaque, len: usize, alignment: std.mem.Alignment, ra: usize) ?[*]u8 {
        const self = cast(context);
        if (len > self.remaining) return null;
        const memory = self.budget.backing.rawAlloc(len, alignment, ra) orelse return null;
        self.remaining -= len;
        _ = self.budget.allocations.fetchAdd(1, .monotonic);
        return memory;
    }
    fn resize(context: *anyopaque, memory: []u8, alignment: std.mem.Alignment, new_len: usize, ra: usize) bool {
        const self = cast(context);
        const growth = new_len -| memory.len;
        if (growth > self.remaining) return false;
        if (!self.budget.backing.rawResize(memory, alignment, new_len, ra)) return false;
        self.remaining -= growth;
        if (new_len < memory.len) self.budget.release(memory.len - new_len);
        return true;
    }
    fn remap(context: *anyopaque, memory: []u8, alignment: std.mem.Alignment, new_len: usize, ra: usize) ?[*]u8 {
        const self = cast(context);
        const growth = new_len -| memory.len;
        if (growth > self.remaining) return null;
        const result = self.budget.backing.rawRemap(memory, alignment, new_len, ra) orelse return null;
        self.remaining -= growth;
        if (new_len < memory.len) self.budget.release(memory.len - new_len);
        return result;
    }
    fn free(context: *anyopaque, memory: []u8, alignment: std.mem.Alignment, ra: usize) void {
        const self = cast(context);
        self.budget.backing.rawFree(memory, alignment, ra);
        self.budget.release(memory.len);
    }
};
test "capacity accounts spare allocation, rejects growth and recovers after free" {
    var budget = Budget.init(std.testing.allocator, 100);
    const a = budget.allocator();
    const first = try a.alloc(u8, 60);
    try std.testing.expectError(error.OutOfMemory, a.alloc(u8, 41));
    try std.testing.expectEqual(@as(usize, 60), budget.stats().used);
    a.free(first);
    try std.testing.expectEqual(@as(usize, 0), budget.stats().used);
    var list: std.ArrayList(u8) = .empty;
    try list.ensureTotalCapacityPrecise(a, 90);
    try std.testing.expectEqual(list.capacity, budget.stats().used);
    list.deinit(a);
    try std.testing.expectEqual(@as(usize, 0), budget.stats().used);
    try std.testing.expect(budget.stats().peak <= 100);
}
test "reservation transfers consumed bytes and returns only unused capacity" {
    var budget = Budget.init(std.testing.allocator, 100);
    var token = try budget.reserve(80);
    const buffer = try token.allocator().alloc(u8, 60);
    try std.testing.expectError(error.OutOfMemory, budget.allocator().alloc(u8, 21));
    token.deinit();
    try std.testing.expectEqual(@as(usize, 60), budget.stats().used);
    budget.allocator().free(buffer);
    try std.testing.expectEqual(@as(usize, 0), budget.stats().used);
}
test "backing allocation failure restores charged capacity" {
    var failing = std.testing.FailingAllocator.init(std.testing.allocator, .{ .fail_index = 0 });
    var budget = Budget.init(failing.allocator(), 100);
    try std.testing.expectError(error.OutOfMemory, budget.allocator().alloc(u8, 10));
    try std.testing.expectEqual(@as(usize, 0), budget.stats().used);
    var token = try budget.reserve(50);
    defer token.deinit();
    try std.testing.expectError(error.OutOfMemory, token.allocator().alloc(u8, 10));
    try std.testing.expectEqual(@as(usize, 50), budget.stats().used);
}
