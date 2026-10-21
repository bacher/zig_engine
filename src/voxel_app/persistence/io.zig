//! Deliberately narrow durability adapter. No portable fsync fallback on macOS.
const std = @import("std");
const builtin = @import("builtin");
pub const Model = @import("io_model.zig").Model;
/// Tests select a backend before opening a Store. Existing handles retain theirs.
pub threadlocal var test_model: ?*Model = null;
const c = @cImport({
    @cInclude("sys/file.h");
    @cInclude("sys/stat.h");
    @cInclude("fcntl.h");
    @cInclude("unistd.h");
    @cInclude("stdio.h");
    @cInclude("dirent.h");
    @cInclude("errno.h");
});
pub const Error = error{ Io, Busy, UnsupportedDurability, UnexpectedEof, AlreadyExists, MissingWorld, InvalidPath, Cancelled };
pub const Operation = enum { read, write, truncate, full_sync, directory_sync, rename, remove, make_directory };
/// Deterministic, bounded per-store fault script; useful without crashing or
/// corrupting unrelated files. Set after=N to fail the Nth matching operation.
pub const Faults = struct {
    hook: ?*const fn (?*anyopaque, Operation) void = null,
    context: ?*anyopaque = null,
    operation: Operation = .write,
    after: usize = 0,
    observed: usize = 0,
    enabled: bool = true,
    partial_write: usize = 0,
    trace: [512]Operation = undefined,
    trace_len: usize = 0,
    fn visit(self: *Faults, operation: Operation) bool {
        if (self.hook) |hook| hook(self.context, operation);
        if (self.trace_len < self.trace.len) {
            self.trace[self.trace_len] = operation;
            self.trace_len += 1;
        }
        if (!self.enabled or operation != self.operation) return false;
        defer self.observed += 1;
        if (self.observed == self.after) {
            self.enabled = false;
            return true;
        }
        return false;
    }
};
fn fault(plan: ?*Faults, operation: Operation) Error!void {
    if (plan) |p| if (p.visit(operation)) return error.Io;
}
pub const File = struct {
    fd: c_int,
    model: ?*Model = null,
    is_lock: bool = false,
    faults: ?*Faults = null,
    pub fn duplicate(self: File) Error!File {
        if (self.model) |model| {
            if (self.is_lock) model.duplicateLock() else model.duplicate(self.fd);
            return self;
        }
        const fd = c.dup(self.fd);
        if (fd < 0) return error.Io;
        return .{ .fd = fd, .faults = self.faults };
    }
    pub fn close(self: File) void {
        if (self.model) |model| {
            if (self.is_lock) model.closeLock() else model.close(self.fd);
            return;
        }
        _ = c.close(self.fd);
    }
    pub fn size(self: File) Error!u64 {
        if (self.model) |model| return model.size(self.fd);
        var s: c.struct_stat = undefined;
        if (c.fstat(self.fd, &s) != 0 or s.st_size < 0) return error.Io;
        if (s.st_nlink > 1) return error.InvalidPath;
        return @intCast(s.st_size);
    }
    pub fn read(self: File, bytes: []u8, offset: u64) Error!void {
        try fault(self.faults, .read);
        if (self.model) |model| return model.read(self.fd, bytes, offset) catch error.UnexpectedEof;
        var pos: usize = 0;
        while (pos < bytes.len) {
            const off = std.math.cast(i64, std.math.add(u64, offset, pos) catch return error.Io) orelse return error.Io;
            const n = c.pread(self.fd, bytes[pos..].ptr, bytes.len - pos, off);
            if (n < 0) {
                if (errno() == c.EINTR) continue;
                return error.Io;
            }
            if (n == 0) return error.UnexpectedEof;
            pos += @intCast(n);
        }
    }
    pub fn write(self: File, bytes: []const u8, offset: u64) Error!void {
        if (self.faults) |plan| if (plan.visit(.write)) {
            const length = @min(bytes.len, plan.partial_write);
            if (length > 0) {
                const clean: File = .{ .fd = self.fd, .model = self.model };
                try clean.write(bytes[0..length], offset);
            }
            return error.Io;
        };
        if (self.model) |model| return model.write(self.fd, bytes, offset) catch error.Io;
        var pos: usize = 0;
        while (pos < bytes.len) {
            const off = std.math.cast(i64, std.math.add(u64, offset, pos) catch return error.Io) orelse return error.Io;
            const n = c.pwrite(self.fd, bytes[pos..].ptr, bytes.len - pos, off);
            if (n < 0) {
                if (errno() == c.EINTR) continue;
                return error.Io;
            }
            if (n == 0) return error.Io;
            pos += @intCast(n);
        }
    }
    pub fn truncate(self: File, length: u64) Error!void {
        try fault(self.faults, .truncate);
        if (self.model) |model| return model.truncate(self.fd, length) catch error.Io;
        if (c.ftruncate(self.fd, std.math.cast(i64, length) orelse return error.Io) != 0) return error.Io;
    }
    pub fn sync(self: File) Error!void {
        if (self.faults) |plan| if (plan.visit(.full_sync)) {
            if (self.model) |model| {
                if (model.failed_sync_survives) model.fullSync(self.fd) catch return error.Io;
            }
            return error.Io;
        };
        if (self.model) |model| return model.fullSync(self.fd) catch error.Io;
        if (builtin.os.tag != .macos) return error.UnsupportedDurability;
        if (c.fcntl(self.fd, c.F_FULLFSYNC) != 0) return error.Io;
    }
};
fn errno() c_int {
    return std.c._errno().*;
}
pub const Directory = struct {
    fd: c_int,
    lock: File,
    model: ?*Model = null,
    faults: ?*Faults = null,
    pub fn open(path: [:0]const u8) Error!Directory {
        if (test_model) |model| {
            try model.acquire();
            return .{ .fd = 0, .lock = .{ .fd = -1, .model = model, .is_lock = true }, .model = model };
        }
        const fd = c.open(path, c.O_RDONLY | c.O_DIRECTORY | c.O_CLOEXEC | c.O_NOFOLLOW);
        if (fd < 0) {
            if (errno() == c.ENOENT) return error.MissingWorld;
            return error.Io;
        }
        return own(fd);
    }
    fn own(fd: c_int) Error!Directory {
        errdefer _ = c.close(fd);
        const lock_fd = c.openat(fd, "world.lock", c.O_RDWR | c.O_CREAT | c.O_CLOEXEC | c.O_NOFOLLOW, @as(c_uint, 0o600));
        if (lock_fd < 0) return error.Io;
        errdefer _ = c.close(lock_fd);
        if (c.flock(lock_fd, c.LOCK_EX | c.LOCK_NB) != 0) return error.Busy;
        return .{ .fd = fd, .lock = .{ .fd = lock_fd } };
    }
    pub fn duplicate(self: Directory) Error!Directory {
        if (self.model) |model| {
            model.duplicateLock();
            return self;
        }
        const fd = c.dup(self.fd);
        if (fd < 0) return error.Io;
        errdefer _ = c.close(fd);
        return .{ .fd = fd, .lock = try self.lock.duplicate(), .faults = self.faults };
    }
    pub fn close(self: Directory) void {
        self.lock.close();
        if (self.model == null) _ = c.close(self.fd);
    }
    pub fn file(self: Directory, name: [:0]const u8, create: bool) Error!File {
        if (self.model) |model| return .{ .fd = model.open(name, create) catch |err| return if (err == error.AlreadyExists) error.AlreadyExists else error.MissingWorld, .model = model, .faults = self.faults };
        const flags = c.O_RDWR | c.O_CLOEXEC | c.O_NOFOLLOW | (if (create) @as(c_int, c.O_CREAT | c.O_EXCL) else @as(c_int, 0));
        const fd = c.openat(self.fd, name, flags, @as(c_uint, 0o600));
        if (fd < 0) {
            if (errno() == c.EEXIST) return error.AlreadyExists;
            if (errno() == c.ENOENT) return error.MissingWorld;
            return error.Io;
        }
        return .{ .fd = fd, .faults = self.faults };
    }
    pub fn exists(self: Directory, name: [:0]const u8) bool {
        if (self.model) |model| return model.exists(name);
        const fd = c.openat(self.fd, name, c.O_RDONLY | c.O_CLOEXEC | c.O_NOFOLLOW);
        if (fd < 0) return false;
        _ = c.close(fd);
        return true;
    }
    pub fn sync(self: Directory, on_device: File) Error!void {
        try fault(self.faults, .directory_sync);
        if (self.model) |model| {
            model.directorySync() catch return error.Io;
            return on_device.sync();
        }
        if (c.fsync(self.fd) != 0) return error.Io;
        try on_device.sync();
    }
    pub fn establish(self: Directory, file_handle: File) Error!void {
        try fault(self.faults, .directory_sync);
        if (self.model) |model| {
            model.directorySync() catch return error.Io;
            return file_handle.sync();
        }
        if (c.fsync(file_handle.fd) != 0 or c.fsync(self.fd) != 0) return error.Io;
        try file_handle.sync();
    }
    pub fn rename(self: Directory, from: [:0]const u8, to: [:0]const u8, exclusive: bool) Error!void {
        try fault(self.faults, .rename);
        if (self.model) |model| return model.rename(from, to, exclusive) catch error.Io;
        if (exclusive) {
            if (builtin.os.tag != .macos) return error.UnsupportedDurability;
            if (c.renameatx_np(self.fd, from, self.fd, to, c.RENAME_EXCL) != 0) return error.Io;
        } else if (c.renameat(self.fd, from, self.fd, to) != 0) return error.Io;
    }
    pub fn remove(self: Directory, name: [:0]const u8) Error!void {
        try fault(self.faults, .remove);
        if (self.model) |model| {
            model.remove(name);
            return;
        }
        if (c.unlinkat(self.fd, name, 0) != 0 and errno() != c.ENOENT) return error.Io;
    }
    pub fn names(self: Directory, allocator: std.mem.Allocator, max: usize) ![][]const u8 {
        if (self.model) |model| return model.names(allocator, max);
        const copied = c.dup(self.fd);
        if (copied < 0) return error.Io;
        const stream = c.fdopendir(copied) orelse {
            _ = c.close(copied);
            return error.Io;
        };
        defer _ = c.closedir(stream);
        c.rewinddir(stream);
        var list: std.ArrayList([]const u8) = .empty;
        errdefer {
            for (list.items) |name| allocator.free(name);
            list.deinit(allocator);
        }
        while (c.readdir(stream)) |entry| {
            const name = std.mem.sliceTo(@as([*:0]const u8, @ptrCast(&entry.*.d_name)), 0);
            if (!std.mem.endsWith(u8, name, ".wal")) continue;
            if (list.items.len >= max) return error.Capacity;
            const owned = try allocator.dupe(u8, name);
            errdefer allocator.free(owned);
            try list.append(allocator, owned);
        }
        return list.toOwnedSlice(allocator);
    }
};
/// Holds the namespace chain until the installed world file can flush its device.
/// Existing parent symlinks resolve normally; retained FDs keep later operations
/// on those resolved directories. The world leaf itself must not be a symlink.
/// On failure, retain created directories and evidence rather than deleting them.
pub const CreationPath = struct {
    allocator: std.mem.Allocator,
    directories: std.ArrayList(c_int) = .empty,
    barrier_start: usize = 0,
    faults: ?*Faults,
    pub fn init(a: std.mem.Allocator, path: [:0]const u8, faults: ?*Faults) !CreationPath {
        var self: CreationPath = .{ .allocator = a, .faults = faults };
        errdefer self.deinit();
        if (test_model != null) return self; // Model covers the world namespace only.
        if (path.len == 0) return error.InvalidPath;
        try self.directories.ensureUnusedCapacity(a, 1);
        const root = c.open(if (std.fs.path.isAbsolute(path)) "/" else ".", c.O_RDONLY | c.O_DIRECTORY | c.O_CLOEXEC | c.O_NOFOLLOW);
        if (root < 0) return error.Io;
        self.directories.appendAssumeCapacity(root);
        var first_created: ?usize = null;
        var components = std.mem.tokenizeScalar(u8, path, '/');
        while (components.next()) |component| {
            const name = try a.dupeZ(u8, component);
            defer a.free(name);
            try self.directories.ensureUnusedCapacity(a, 1);
            const parent = self.directories.items[self.directories.items.len - 1];
            const flags = c.O_RDONLY | c.O_DIRECTORY | c.O_CLOEXEC | (if (components.peek() == null) @as(c_int, c.O_NOFOLLOW) else @as(c_int, 0));
            var child = c.openat(parent, name, flags);
            if (child < 0) {
                if (errno() != c.ENOENT) return error.Io;
                try fault(faults, .make_directory);
                if (c.mkdirat(parent, name, @as(c_uint, 0o700)) != 0 and errno() != c.EEXIST) return error.Io;
                child = c.openat(parent, name, flags);
                if (child < 0) return error.Io;
                // Include the existing parent too: it contains the first new name.
                if (first_created == null) first_created = self.directories.items.len;
            }
            self.directories.appendAssumeCapacity(child);
        }
        self.barrier_start = if (first_created) |index| index - 1 else self.directories.items.len -| 2;
        return self;
    }
    pub fn openDirectory(self: *const CreationPath) Error!Directory {
        if (self.directories.items.len == 0) return Directory.open("");
        const fd = c.dup(self.directories.items[self.directories.items.len - 1]);
        if (fd < 0) return error.Io;
        return Directory.own(fd);
    }
    pub fn deinit(self: *CreationPath) void {
        for (self.directories.items) |fd| _ = c.close(fd);
        self.directories.deinit(self.allocator);
    }
    pub fn sync(self: *const CreationPath, installed: File) Error!void {
        if (installed.model != null) return installed.sync();
        var device: c.struct_stat = undefined;
        if (c.fstat(installed.fd, &device) != 0) return error.Io;
        var index = self.directories.items.len;
        while (index > 0) {
            index -= 1;
            const fd = self.directories.items[index];
            var directory: c.struct_stat = undefined;
            if (c.fstat(fd, &directory) != 0) return error.Io;
            // A full flush of the world file cannot confirm another device.
            if (directory.st_dev != device.st_dev) {
                if (index >= self.barrier_start) return error.UnsupportedDurability;
                break; // Existing ancestors above this filesystem's mount point.
            }
            try fault(self.faults, .directory_sync);
            if (c.fsync(fd) != 0) return error.Io;
        }
        // Include existing same-device ancestors too: an earlier failed create
        // may have left their new names without a confirmed flush. Bottom-up
        // directory fsyncs precede the same-device hardware flush.
        try installed.sync();
    }
};

pub fn makeDirectory(path: [:0]const u8) Error!void {
    if (test_model != null) return;
    if (c.mkdir(path, 0o700) != 0 and errno() != c.EEXIST) return error.Io;
}
pub fn removeDirectory(path: [:0]const u8) void {
    if (test_model != null) return;
    _ = c.rmdir(path);
}

pub const Priority = struct {
    previous: std.c.qos_class_t = .DEFAULT,
    relative: c_int = 0,
    pub fn restore(self: Priority) Error!void {
        if (builtin.os.tag == .macos and std.c.pthread_set_qos_class_self_np(self.previous, self.relative) != 0) return error.Io;
    }
};
pub fn enterBackgroundPriority() Error!Priority {
    var priority: Priority = .{};
    if (builtin.os.tag == .macos) {
        if (std.c.pthread_get_qos_class_np(std.c.pthread_self(), &priority.previous, &priority.relative) != 0) return error.Io;
        if (priority.previous == .UNSPECIFIED) {
            priority.previous = .DEFAULT;
            priority.relative = 0;
        }
        if (std.c.pthread_set_qos_class_self_np(.BACKGROUND, 0) != 0) return error.Io;
    }
    return priority;
}

test "creation path cannot confirm directory durability through a different device" {
    if (builtin.os.tag != .macos) return error.SkipZigTest;
    var path = try CreationPath.init(std.testing.allocator, "/private/tmp", null);
    defer path.deinit();
    const fd = c.open("/dev/null", c.O_RDONLY | c.O_CLOEXEC);
    if (fd < 0) return error.Io;
    const other_device: File = .{ .fd = fd };
    defer other_device.close();
    try std.testing.expectError(error.UnsupportedDurability, path.sync(other_device));
}
