//! Deterministic local-filesystem crash model used beneath the real Store API.
//! Working bytes, durable bytes, and durable directory names are independent.
const std = @import("std");
const Allocator = std.mem.Allocator;
const Node = struct { bytes: std.ArrayList(u8) = .empty, durable: std.ArrayList(u8) = .empty, refs: usize = 0 };
const Entry = struct { name: []u8, id: usize };
pub const Model = struct {
    allocator: Allocator,
    nodes: std.ArrayList(Node) = .empty,
    working: std.ArrayList(Entry) = .empty,
    staged: std.ArrayList(Entry) = .empty,
    durable: std.ArrayList(Entry) = .empty,
    directory_staged: bool = false,
    lock_refs: usize = 0,
    failed_sync_survives: bool = false,
    pub fn init(a: Allocator) Model {
        return .{ .allocator = a };
    }
    pub fn deinit(self: *Model) void {
        for (self.nodes.items) |*node| {
            node.bytes.deinit(self.allocator);
            node.durable.deinit(self.allocator);
        }
        self.nodes.deinit(self.allocator);
        self.clearEntries(&self.working);
        self.clearEntries(&self.staged);
        self.clearEntries(&self.durable);
    }
    fn clearEntries(self: *Model, entries: *std.ArrayList(Entry)) void {
        for (entries.items) |entry| self.allocator.free(entry.name);
        entries.deinit(self.allocator);
        entries.* = .empty;
    }
    fn copyEntries(self: *Model, target: *std.ArrayList(Entry), source: []const Entry) !void {
        var copied: std.ArrayList(Entry) = .empty;
        errdefer self.clearEntries(&copied);
        for (source) |entry| {
            const name = try self.allocator.dupe(u8, entry.name);
            errdefer self.allocator.free(name);
            try copied.append(self.allocator, .{ .name = name, .id = entry.id });
        }
        self.clearEntries(target);
        target.* = copied;
    }
    fn find(self: *Model, name: []const u8) ?usize {
        for (self.working.items, 0..) |entry, i| if (std.mem.eql(u8, entry.name, name)) return i;
        return null;
    }
    pub fn acquire(self: *Model) !void {
        if (self.lock_refs > 0) return error.Busy;
        self.lock_refs = 1;
    }
    pub fn duplicateLock(self: *Model) void {
        self.lock_refs += 1;
    }
    pub fn closeLock(self: *Model) void {
        self.lock_refs -|= 1;
    }
    pub fn exists(self: *Model, name: []const u8) bool {
        return self.find(name) != null;
    }
    pub fn open(self: *Model, name: []const u8, create: bool) !c_int {
        if (self.find(name)) |i| {
            if (create) return error.AlreadyExists;
            const id = self.working.items[i].id;
            self.nodes.items[id].refs += 1;
            return @intCast(id);
        }
        if (!create) return error.Io;
        const owned = try self.allocator.dupe(u8, name);
        errdefer self.allocator.free(owned);
        try self.working.ensureUnusedCapacity(self.allocator, 1);
        const id = self.nodes.items.len;
        try self.nodes.append(self.allocator, .{ .refs = 1 });
        self.working.appendAssumeCapacity(.{ .name = owned, .id = id });
        return @intCast(id);
    }
    pub fn duplicate(self: *Model, id: c_int) void {
        self.nodes.items[@intCast(id)].refs += 1;
    }
    pub fn close(self: *Model, id: c_int) void {
        self.nodes.items[@intCast(id)].refs -|= 1;
    }
    pub fn size(self: *Model, id: c_int) u64 {
        return self.nodes.items[@intCast(id)].bytes.items.len;
    }
    pub fn read(self: *Model, id: c_int, bytes: []u8, offset: u64) !void {
        const source = self.nodes.items[@intCast(id)].bytes.items;
        if (offset > source.len or bytes.len > source.len - offset) return error.UnexpectedEof;
        @memcpy(bytes, source[@intCast(offset)..][0..bytes.len]);
    }
    pub fn write(self: *Model, id: c_int, bytes: []const u8, offset: u64) !void {
        const end = std.math.add(u64, offset, bytes.len) catch return error.Io;
        const extent = std.math.cast(usize, end) orelse return error.Io;
        const node = &self.nodes.items[@intCast(id)];
        if (extent > node.bytes.items.len) {
            const old = node.bytes.items.len;
            try node.bytes.resize(self.allocator, extent);
            @memset(node.bytes.items[old..], 0);
        }
        @memcpy(node.bytes.items[@intCast(offset)..][0..bytes.len], bytes);
    }
    pub fn truncate(self: *Model, id: c_int, length: u64) !void {
        const node = &self.nodes.items[@intCast(id)];
        const extent = std.math.cast(usize, length) orelse return error.Io;
        const old = node.bytes.items.len;
        try node.bytes.resize(self.allocator, extent);
        if (extent > old) @memset(node.bytes.items[old..], 0);
    }
    pub fn fullSync(self: *Model, id: c_int) !void {
        const node = &self.nodes.items[@intCast(id)];
        try node.durable.resize(self.allocator, node.bytes.items.len);
        @memcpy(node.durable.items, node.bytes.items);
        if (self.directory_staged) {
            try self.copyEntries(&self.durable, self.staged.items);
            self.directory_staged = false;
        }
    }
    pub fn directorySync(self: *Model) !void {
        try self.copyEntries(&self.staged, self.working.items);
        self.directory_staged = true;
    }
    pub fn rename(self: *Model, from: []const u8, to: []const u8, exclusive: bool) !void {
        const source = self.find(from) orelse return error.Io;
        if (exclusive and self.find(to) != null) return error.AlreadyExists;
        const name = try self.allocator.dupe(u8, to);
        errdefer self.allocator.free(name);
        const id = self.working.items[source].id;
        self.allocator.free(self.working.items[source].name);
        _ = self.working.swapRemove(source);
        if (self.find(to)) |i| {
            self.allocator.free(self.working.items[i].name);
            _ = self.working.swapRemove(i);
        }
        self.working.appendAssumeCapacity(.{ .name = name, .id = id });
    }
    pub fn remove(self: *Model, name: []const u8) void {
        if (self.find(name)) |i| {
            self.allocator.free(self.working.items[i].name);
            _ = self.working.swapRemove(i);
        }
    }
    pub fn names(self: *Model, a: Allocator, max: usize) ![][]const u8 {
        var list: std.ArrayList([]const u8) = .empty;
        errdefer {
            for (list.items) |name| a.free(name);
            list.deinit(a);
        }
        for (self.working.items) |entry| {
            if (!std.mem.endsWith(u8, entry.name, ".wal")) continue;
            if (list.items.len >= max) return error.Capacity;
            const name = try a.dupe(u8, entry.name);
            errdefer a.free(name);
            try list.append(a, name);
        }
        return list.toOwnedSlice(a);
    }
    pub const Survival = enum { lose_unsynced, survive_unsynced };
    pub fn crash(self: *Model, survival: Survival) !void {
        if (survival == .survive_unsynced) {
            for (self.nodes.items) |*node| {
                try node.durable.resize(self.allocator, node.bytes.items.len);
                @memcpy(node.durable.items, node.bytes.items);
            }
            try self.copyEntries(&self.durable, self.working.items);
        }
        for (self.nodes.items) |*node| {
            try node.bytes.resize(self.allocator, node.durable.items.len);
            @memcpy(node.bytes.items, node.durable.items);
            node.refs = 0;
        }
        try self.copyEntries(&self.working, self.durable.items);
        self.clearEntries(&self.staged);
        self.directory_staged = false;
        self.lock_refs = 0;
    }
};
