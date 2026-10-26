//! Single-owner durable store. Called only by a persistence worker; source chunk
//! references never enter this module. Output is bounded to one encoded record.
const std = @import("std");
pub const io = @import("io.zig");
const format = @import("format.zig");
pub const Uuid = [16]u8;
pub const Digest = [32]u8;
pub const SnapshotIdentity = struct { sequence: u64, digest: Digest };
pub const Limits = struct { max_chunks: usize = 1_000_000, max_segments: usize = 128, max_players_bytes: usize = 16 * 1024 * 1024 };
pub const Initial = struct { world_uuid: Uuid, descriptor: []const u8, global: []const u8, players: []const u8, player_count: u64, chunks: []const []const u8 = &.{} };
const HeaderSize = 120;
const MaxRecord = 1_212_501;
const Location = struct { file: io.File, offset: u64, length: u32, revision: u64 };
const Segment = struct { name: [:0]u8, file: io.File, header: [120]u8, predecessor: SnapshotIdentity, end: u64, final: SnapshotIdentity, tail: bool = false, used: bool = false, established: bool = true };
pub const Phase = enum { ready, appending, committing, repair_required };
const Transaction = struct {
    sequence: u64,
    global: []u8,
    players: []u8,
    player_count: u64,
    expected: u64,
    count: u64 = 0,
    start: u64,
    cursor: u64,
    hash: std.crypto.hash.Blake3,
    chunks: std.AutoHashMap(u32, Location),
};
pub const Store = struct {
    allocator: std.mem.Allocator,
    directory: io.Directory,
    limits: Limits,
    world_uuid: Uuid,
    dimensions: [3]u32,
    descriptor: []u8,
    global: []u8,
    players: []u8,
    player_count: u64,
    sequence: u64,
    digest: Digest,
    base: io.File,
    base_sequence: u64,
    /// Preserve the snapshot-zero anchor's format version when compacting v1 saves.
    base_format_version: u32 = format.current_write_version,
    index: std.AutoHashMap(u32, Location),
    segments: std.ArrayList(Segment) = .empty,
    active: ?usize = null,
    compaction_in_flight: bool = false,
    cancellation: ?*std.atomic.Value(bool) = null,
    phase: Phase = .ready,
    transaction: ?Transaction = null,
    pub fn create(a: std.mem.Allocator, path: [:0]const u8, initial: Initial, limits: Limits) !Store {
        return createWithFaults(a, path, initial, limits, null);
    }
    fn createWithFaults(a: std.mem.Allocator, path: [:0]const u8, initial: Initial, limits: Limits, faults: ?*io.Faults) !Store {
        var creation_path = try io.CreationPath.init(a, path, faults);
        defer creation_path.deinit();
        var dir = try creation_path.openDirectory();
        dir.faults = faults;
        errdefer dir.close();
        // Never invent a fresh anchor beside orphaned persistence evidence.
        // An empty precreated directory (including its stable lock) is allowed.
        for ([_][:0]const u8{ "world.base", "initial.tmp", "initial-chunks.tmp", "compact.tmp", "segment.pending" }) |name| {
            if (dir.exists(name)) return error.AlreadyExists;
        }
        const existing_segments = try dir.names(a, limits.max_segments);
        defer {
            for (existing_segments) |name| a.free(name);
            a.free(existing_segments);
        }
        if (existing_segments.len != 0) return error.AlreadyExists;
        const desc = try format.decodeDescriptor(initial.descriptor);
        _ = try format.decodeGlobal(initial.global);
        try format.validatePlayers(initial.players, initial.player_count);
        if (initial.players.len > limits.max_players_bytes) return error.Capacity;
        var hash = hasher("ZGW-INIT-1\x00");
        hash.update(&initial.world_uuid);
        hashInt(&hash, u32, format.current_write_version);
        hashInt(&hash, u64, 0);
        hashInt(&hash, u32, @intCast(initial.descriptor.len));
        hash.update(initial.descriptor);
        hashInt(&hash, u32, @intCast(initial.global.len));
        hash.update(initial.global);
        hashInt(&hash, u64, initial.player_count);
        hashInt(&hash, u64, initial.players.len);
        hash.update(initial.players);
        hashInt(&hash, u64, initial.chunks.len);
        if (initial.chunks.len > limits.max_chunks) return error.Capacity;
        var last_id: ?u32 = null;
        for (initial.chunks) |bytes| {
            try format.validateChunkRecord(initial.world_uuid, bytes, desc.dimensions);
            const id = get(u32, bytes, 4);
            if (last_id != null and id <= last_id.?) return error.Corruption;
            last_id = id;
            hash.update(bytes);
        }
        var digest: Digest = undefined;
        hash.final(&digest);
        const descriptor = try a.dupe(u8, initial.descriptor);
        errdefer a.free(descriptor);
        const global = try a.dupe(u8, initial.global);
        errdefer a.free(global);
        const players = try a.dupe(u8, initial.players);
        errdefer a.free(players);
        var self: Store = .{ .allocator = a, .directory = dir, .limits = limits, .world_uuid = initial.world_uuid, .dimensions = desc.dimensions, .descriptor = descriptor, .global = global, .players = players, .player_count = initial.player_count, .sequence = 0, .digest = digest, .base = undefined, .base_sequence = 0, .index = std.AutoHashMap(u32, Location).init(a) };
        errdefer {
            self.index.deinit();
            for (self.segments.items) |segment| {
                segment.file.close();
                a.free(segment.name);
            }
            self.segments.deinit(a);
        }
        const candidate = try dir.file("initial.tmp", true);
        errdefer candidate.close();
        const source = try dir.file("initial-chunks.tmp", true);
        defer source.close();
        var source_offset: u64 = 0;
        for (initial.chunks) |bytes| {
            try source.write(bytes, source_offset);
            try self.index.put(get(u32, bytes, 4), .{ .file = source, .offset = source_offset, .length = @intCast(bytes.len), .revision = get(u64, bytes, 8) });
            source_offset = try add(source_offset, bytes.len);
        }
        try self.writeBase(candidate);
        try candidate.sync();
        try dir.rename("initial.tmp", "world.base", true);
        try dir.sync(candidate);
        try creation_path.sync(candidate);
        self.base = candidate;
        var initial_index: u64 = 120 + descriptor.len + global.len;
        for (initial.chunks) |bytes| {
            var entry: [12]u8 = undefined;
            try candidate.read(&entry, initial_index);
            initial_index = try add(initial_index, 12);
            const location = self.index.getPtr(get(u32, bytes, 4)).?;
            location.file = candidate;
            location.offset = get(u64, &entry, 4);
        }
        try dir.remove("initial-chunks.tmp");
        try dir.sync(candidate);
        try self.newSegment();
        return self;
    }
    pub fn open(a: std.mem.Allocator, path: [:0]const u8, limits: Limits) !Store {
        var owned = false;
        const dir = try io.Directory.open(path);
        errdefer if (!owned) dir.close();
        const base = try dir.file("world.base", false);
        errdefer if (!owned) base.close();
        var header: [120]u8 = undefined;
        try base.read(&header, 0);
        const version = get(u32, &header, 8);
        if (!std.mem.eql(u8, header[0..8], "ZGWORLD\x00") or version < format.minimum_readable_version or version > format.current_write_version or get(u32, &header, 12) != 120) return error.UnsupportedFormat;
        const size = try base.size();
        if (get(u64, &header, 16) != size) return error.Corruption;
        try verifyFile(base, size, "ZGW-BASE-1\x00", null);
        const descriptor_len = get(u32, &header, 80);
        const global_len = get(u32, &header, 84);
        const chunk_count = get(u64, &header, 88);
        const player_count = get(u64, &header, 96);
        const player_len = get(u64, &header, 104);
        const chunk_len = get(u64, &header, 112);
        if (descriptor_len > format.maximum_descriptor_size or global_len != 10 or chunk_count > limits.max_chunks or player_len > limits.max_players_bytes) return error.Capacity;
        const index_start = try add(120, try add(descriptor_len, global_len));
        const player_start = try add(index_start, try mul(chunk_count, 12));
        const chunk_start = try add(player_start, player_len);
        if (try add(try add(chunk_start, chunk_len), 32) != size) return error.Corruption;
        const descriptor = try readAlloc(a, base, 120, descriptor_len);
        errdefer if (!owned) a.free(descriptor);
        const desc = try format.decodeDescriptor(descriptor);
        const global = try readAlloc(a, base, 120 + descriptor_len, global_len);
        errdefer if (!owned) a.free(global);
        _ = try format.decodeGlobal(global);
        const players = try readAlloc(a, base, player_start, player_len);
        errdefer if (!owned) a.free(players);
        try format.validatePlayers(players, player_count);
        var self: Store = .{ .allocator = a, .directory = dir, .limits = limits, .world_uuid = header[24..40].*, .dimensions = desc.dimensions, .descriptor = descriptor, .global = global, .players = players, .player_count = player_count, .sequence = get(u64, &header, 40), .digest = header[48..80].*, .base = base, .base_sequence = get(u64, &header, 40), .index = std.AutoHashMap(u32, Location).init(a) };
        owned = true;
        self.base_format_version = version;
        errdefer self.deinit();
        var anchor = hasher("ZGW-INIT-1\x00");
        anchor.update(&self.world_uuid);
        hashInt(&anchor, u32, version);
        hashInt(&anchor, u64, 0);
        hashInt(&anchor, u32, descriptor_len);
        anchor.update(descriptor);
        hashInt(&anchor, u32, global_len);
        anchor.update(global);
        hashInt(&anchor, u64, player_count);
        hashInt(&anchor, u64, player_len);
        anchor.update(players);
        hashInt(&anchor, u64, chunk_count);
        var cursor = chunk_start;
        var previous: ?u32 = null;
        var i: u64 = 0;
        while (i < chunk_count) : (i += 1) {
            var entry: [12]u8 = undefined;
            try base.read(&entry, index_start + i * 12);
            const id = get(u32, &entry, 0);
            if (previous != null and id <= previous.?) return error.Corruption;
            if (get(u64, &entry, 4) != cursor) return error.Corruption;
            const encoded = try self.record(base, cursor, size - 32);
            defer a.free(encoded);
            if (get(u32, encoded, 4) != id) return error.Corruption;
            if (self.sequence == 0) anchor.update(encoded);
            try self.index.put(id, .{ .file = base, .offset = cursor, .length = @intCast(encoded.len), .revision = get(u64, encoded, 8) });
            cursor = try add(cursor, encoded.len);
            previous = id;
        }
        if (cursor != size - 32) return error.Corruption;
        if (self.sequence == 0) {
            var expected: Digest = undefined;
            anchor.final(&expected);
            if (!std.mem.eql(u8, &expected, &self.digest)) return error.Corruption;
        }
        try self.recover();
        if (self.sequence != self.base_sequence or self.segments.items.len > 0) try self.compact();
        try self.newSegment();
        return self;
    }
    pub fn deinit(self: *Store) void {
        self.clearTransaction();
        for (self.segments.items) |s| {
            s.file.close();
            self.allocator.free(s.name);
        }
        self.segments.deinit(self.allocator);
        self.index.deinit();
        self.base.close();
        self.directory.close();
        self.allocator.free(self.descriptor);
        self.allocator.free(self.global);
        self.allocator.free(self.players);
        self.* = undefined;
    }
    pub fn snapshotCatalog(self: *const Store) !BaseCatalog {
        const file = try self.base.duplicate();
        errdefer file.close();
        var index = std.AutoHashMap(u32, Location).init(self.allocator);
        errdefer index.deinit();
        try index.ensureTotalCapacity(@intCast(self.index.count()));
        var it = self.index.iterator();
        while (it.next()) |entry| {
            if (entry.value_ptr.file.fd == self.base.fd) {
                var location = entry.value_ptr.*;
                location.file = file;
                index.putAssumeCapacity(entry.key_ptr.*, location);
            }
        }
        return .{ .allocator = self.allocator, .file = file, .index = index, .world_uuid = self.world_uuid, .dimensions = self.dimensions, .sequence = self.base_sequence };
    }
    pub fn setFaults(self: *Store, faults: ?*io.Faults) void {
        self.directory.faults = faults;
        self.base.faults = faults;
        for (self.segments.items) |*segment| segment.file.faults = faults;
        var it = self.index.valueIterator();
        while (it.next()) |location| location.file.faults = faults;
    }
    fn checkpoint(self: *Store) !void {
        if (self.cancellation) |flag| {
            if (flag.load(.acquire)) return error.Cancelled;
            try std.Thread.yield();
        }
    }
    pub fn readChunk(self: *Store, a: std.mem.Allocator, id: u32) !?[]u8 {
        const location = self.index.get(id) orelse return null;
        // Gameplay reads use only the installed generation. WAL-only versions stay resident.
        if (location.file.fd != self.base.fd) return error.NotInBase;
        const bytes = try readAlloc(a, location.file, location.offset, location.length);
        errdefer a.free(bytes);
        try format.validateChunkRecord(self.world_uuid, bytes, self.dimensions);
        if (get(u32, bytes, 4) != id or get(u64, bytes, 8) != location.revision) return error.Corruption;
        return bytes;
    }
    pub fn beginSnapshot(self: *Store, sequence: u64, global: []const u8, players: []const u8, player_count: u64, changed_count: u64) !void {
        if (self.phase != .ready or self.transaction != null) return error.WriterBusy;
        if (sequence <= self.sequence) return error.InvalidSequence;
        if (players.len > self.limits.max_players_bytes or changed_count > self.limits.max_chunks) return error.Capacity;
        _ = try format.decodeGlobal(global);
        try format.validatePlayers(players, player_count);
        if (self.active == null) try self.newSegment();
        const s = &self.segments.items[self.active.?];
        if (!s.established) {
            try self.directory.establish(s.file);
            s.established = true;
        }
        const g = try self.allocator.dupe(u8, global);
        errdefer if (self.transaction == null) self.allocator.free(g);
        const p = try self.allocator.dupe(u8, players);
        errdefer if (self.transaction == null) self.allocator.free(p);
        var tx: Transaction = .{ .sequence = sequence, .global = g, .players = p, .player_count = player_count, .expected = changed_count, .start = s.end, .cursor = s.end, .hash = hasher("ZGW-WALTX-1\x00"), .chunks = std.AutoHashMap(u32, Location).init(self.allocator) };
        tx.hash.update(&s.header);
        var header: [84]u8 = @splat(0);
        @memcpy(header[0..8], "ZGTXBEG1");
        put(u64, &header, 8, sequence);
        put(u64, &header, 16, self.sequence);
        @memcpy(header[24..56], &self.digest);
        put(u32, &header, 56, @intCast(global.len));
        put(u64, &header, 60, player_count);
        put(u64, &header, 68, players.len);
        put(u64, &header, 76, changed_count);
        self.transaction = tx;
        self.phase = .appending;
        errdefer self.phase = .repair_required;
        try self.append(&header);
        try self.append(global);
        try self.append(players);
    }
    pub fn appendChunk(self: *Store, bytes: []const u8) !void {
        if (self.phase != .appending) return error.WriterBusy;
        try format.validateChunkRecord(self.world_uuid, bytes, self.dimensions);
        const tx = &self.transaction.?;
        if (tx.count >= tx.expected) return error.Corruption;
        const id = get(u32, bytes, 4);
        if (tx.chunks.contains(id)) return error.Corruption;
        const s = self.segments.items[self.active.?];
        try tx.chunks.put(id, .{ .file = s.file, .offset = tx.cursor, .length = @intCast(bytes.len), .revision = get(u64, bytes, 8) });
        errdefer self.phase = .repair_required;
        try self.append(bytes);
        self.transaction.?.count += 1;
    }
    pub fn commitSnapshot(self: *Store) !SnapshotIdentity {
        return self.commit(null);
    }
    pub fn commitSnapshotControlled(self: *Store, context: *anyopaque, authorize: *const fn (*anyopaque) bool) !SnapshotIdentity {
        return self.commit(.{ .context = context, .authorize = authorize });
    }
    const CommitGate = struct { context: *anyopaque, authorize: *const fn (*anyopaque) bool };
    fn commit(self: *Store, gate: ?CommitGate) !SnapshotIdentity {
        if (self.phase != .appending) return error.WriterBusy;
        const tx = &self.transaction.?;
        if (tx.count != tx.expected) return error.IncompleteSnapshot;
        var added: usize = 0;
        var ids = tx.chunks.keyIterator();
        while (ids.next()) |id| {
            if (!self.index.contains(id.*)) added += 1;
        }
        if (self.index.count() + added > self.limits.max_chunks) return error.Capacity;
        // Reserve all fallible bookkeeping before the irreversible commit attempt.
        try self.index.ensureUnusedCapacity(@intCast(tx.chunks.count()));
        var footer: [56]u8 = @splat(0);
        @memcpy(footer[0..8], "ZGTXEND1");
        put(u64, &footer, 8, try add(tx.cursor - tx.start, 56));
        put(u64, &footer, 16, tx.sequence);
        const end_offset = try add(tx.cursor, 56);
        // The caller serializes accepted cancellation against this exact point.
        // No allocation or fallible framing arithmetic remains before footer I/O.
        if (gate) |boundary| if (!boundary.authorize(boundary.context)) return error.Cancelled;
        tx.hash.update(footer[0..24]);
        tx.hash.final(footer[24..56]);
        self.phase = .committing;
        errdefer self.phase = .repair_required;
        const s = &self.segments.items[self.active.?];
        try s.file.write(&footer, tx.cursor);
        try s.file.sync();
        s.end = end_offset;
        self.sequence = tx.sequence;
        self.digest = footer[24..56].*;
        s.final = .{ .sequence = self.sequence, .digest = self.digest };
        var it = tx.chunks.iterator();
        while (it.next()) |entry| self.index.putAssumeCapacity(entry.key_ptr.*, entry.value_ptr.*);
        self.allocator.free(self.global);
        self.allocator.free(self.players);
        self.global = tx.global;
        self.players = tx.players;
        self.player_count = tx.player_count;
        tx.chunks.deinit();
        self.transaction = null;
        self.phase = .ready;
        return .{ .sequence = self.sequence, .digest = self.digest };
    }
    pub fn cancelSnapshot(self: *Store) !void {
        if (self.phase == .committing) return error.CommitInProgress;
        if (self.transaction != null) self.phase = .repair_required;
        try self.repair();
    }
    pub fn repair(self: *Store) !void {
        if (self.phase != .repair_required) return;
        const s = self.segments.items[self.active.?];
        try s.file.truncate(s.end);
        try s.file.sync();
        self.clearTransaction();
        self.phase = .ready;
    }
    fn clearTransaction(self: *Store) void {
        if (self.transaction) |*tx| {
            self.allocator.free(tx.global);
            self.allocator.free(tx.players);
            tx.chunks.deinit();
            self.transaction = null;
        }
    }
    fn append(self: *Store, bytes: []const u8) !void {
        const tx = &self.transaction.?;
        try self.segments.items[self.active.?].file.write(bytes, tx.cursor);
        tx.hash.update(bytes);
        tx.cursor = try add(tx.cursor, bytes.len);
    }
    fn newSegment(self: *Store) !void {
        if (self.segments.items.len >= self.limits.max_segments) return error.Capacity;
        var uuid: Uuid = undefined;
        std.c.arc4random_buf(&uuid, uuid.len);
        var adopted = false;
        const name = try std.fmt.allocPrintSentinel(self.allocator, "segment-{x}.wal", .{uuid}, 0);
        errdefer if (!adopted) self.allocator.free(name);
        try self.segments.ensureUnusedCapacity(self.allocator, 1);
        if (self.directory.exists("segment.pending")) try self.directory.remove("segment.pending");
        const file = try self.directory.file("segment.pending", true);
        errdefer if (!adopted) file.close();
        var header: [120]u8 = @splat(0);
        @memcpy(header[0..8], "ZGWAL\x00\x00\x00");
        put(u32, &header, 8, format.current_write_version);
        put(u32, &header, 12, 120);
        @memcpy(header[16..32], &self.world_uuid);
        @memcpy(header[32..48], &uuid);
        put(u64, &header, 48, self.sequence);
        @memcpy(header[56..88], &self.digest);
        var hash = hasher("ZGW-WALHDR-1\x00");
        hash.update(header[0..88]);
        hash.final(header[88..120]);
        try file.write(&header, 0);
        try file.sync();
        try self.directory.rename("segment.pending", name, true);
        self.segments.appendAssumeCapacity(.{ .name = name, .file = file, .header = header, .predecessor = .{ .sequence = self.sequence, .digest = self.digest }, .end = 120, .final = .{ .sequence = self.sequence, .digest = self.digest }, .established = false });
        self.active = self.segments.items.len - 1;
        adopted = true;
        try self.directory.establish(file);
        self.segments.items[self.active.?].established = true;
    }
    pub fn rotate(self: *Store) !void {
        if (self.phase != .ready or self.transaction != null) return error.WriterBusy;
        if (self.active) |i| {
            if (self.segments.items[i].end == 120) {
                if (!self.segments.items[i].established) {
                    try self.directory.establish(self.segments.items[i].file);
                    self.segments.items[i].established = true;
                }
                return;
            }
        }
        try self.newSegment();
    }
    /// Freeze an immutable generation without holding a world source. Only the
    /// bounded index and small global records are copied; chunk bytes stay on disk.
    pub fn prepareCompaction(self: *Store) !Compaction {
        if (self.phase != .ready or self.compaction_in_flight) return error.WriterBusy;
        try self.rotate();
        const a = self.allocator;
        const dir = try self.directory.duplicate();
        errdefer dir.close();
        const base = try self.base.duplicate();
        errdefer base.close();
        const descriptor = try a.dupe(u8, self.descriptor);
        errdefer a.free(descriptor);
        const global = try a.dupe(u8, self.global);
        errdefer a.free(global);
        const players = try a.dupe(u8, self.players);
        errdefer a.free(players);
        var frozen: Store = .{ .allocator = a, .directory = dir, .limits = self.limits, .world_uuid = self.world_uuid, .dimensions = self.dimensions, .descriptor = descriptor, .global = global, .players = players, .player_count = self.player_count, .sequence = self.sequence, .digest = self.digest, .base = base, .base_sequence = self.base_sequence, .index = std.AutoHashMap(u32, Location).init(a) };
        frozen.base_format_version = self.base_format_version;
        errdefer {
            frozen.index.deinit();
            for (frozen.segments.items) |segment| {
                segment.file.close();
                a.free(segment.name);
            }
            frozen.segments.deinit(a);
        }
        for (self.segments.items, 0..) |segment, i| {
            if (i == self.active.?) continue;
            const name = try a.dupeZ(u8, segment.name);
            errdefer a.free(name);
            const file = try segment.file.duplicate();
            errdefer file.close();
            var copy = segment;
            copy.name = name;
            copy.file = file;
            try frozen.segments.append(a, copy);
        }
        try frozen.index.ensureTotalCapacity(@intCast(self.index.count()));
        var it = self.index.iterator();
        while (it.next()) |entry| {
            var location = entry.value_ptr.*;
            if (location.file.fd == self.base.fd) {
                location.file = base;
            } else {
                var found = false;
                for (self.segments.items) |source| {
                    if (source.file.fd != location.file.fd) continue;
                    for (frozen.segments.items) |copy| {
                        if (std.mem.eql(u8, &copy.header, &source.header)) {
                            location.file = copy.file;
                            found = true;
                            break;
                        }
                    }
                    break;
                }
                if (!found) return error.Corruption;
            }
            frozen.index.putAssumeCapacity(entry.key_ptr.*, location);
        }
        const sealed = try a.alloc(Uuid, frozen.segments.items.len);
        for (frozen.segments.items, 0..) |segment, i| sealed[i] = segment.header[32..48].*;
        self.compaction_in_flight = true;
        return .{ .store = frozen, .sealed = sealed };
    }
    /// Runs only on the writer owner after background completion. Updated chunks
    /// retain their newer WAL locations; equal revisions move to the new base.
    pub fn installCompaction(self: *Store, compaction: *Compaction) !void {
        if (!self.compaction_in_flight or !compaction.completed) return error.WriterBusy;
        const frozen = &compaction.store;
        if (frozen.sequence > self.sequence) return error.Corruption;
        const new_base = try frozen.base.duplicate();
        var it = frozen.index.iterator();
        while (it.next()) |entry| {
            if (self.index.getPtr(entry.key_ptr.*)) |current| {
                if (current.revision == entry.value_ptr.revision) {
                    current.* = entry.value_ptr.*;
                    current.file = new_base;
                }
            }
        }
        const old_base = self.base;
        self.base = new_base;
        self.base_sequence = frozen.sequence;
        old_base.close();
        var i: usize = 0;
        while (i < self.segments.items.len) {
            const segment = self.segments.items[i];
            // Compaction target includes every sealed segment at preparation.
            var included = false;
            for (compaction.sealed) |uuid| {
                if (std.mem.eql(u8, &uuid, segment.header[32..48])) {
                    included = true;
                    break;
                }
            }
            if (included) {
                segment.file.close();
                self.allocator.free(segment.name);
                _ = self.segments.swapRemove(i);
            } else i += 1;
        }
        self.active = null;
        for (self.segments.items, 0..) |segment, j| if (segment.predecessor.sequence >= frozen.sequence and segment.final.sequence == self.sequence) {
            self.active = j;
        };
        self.compaction_in_flight = false;
    }
    pub fn abandonCompaction(self: *Store) void {
        self.compaction_in_flight = false;
    }
    pub fn baseRevision(self: *const Store, id: u32) ?u64 {
        const location = self.index.get(id) orelse return null;
        return if (location.file.fd == self.base.fd) location.revision else null;
    }
    fn record(self: *Store, file: io.File, offset: u64, end: u64) ![]u8 {
        if (offset > end or end - offset < 4) return error.UnexpectedEof;
        var prefix: [4]u8 = undefined;
        try file.read(&prefix, offset);
        const length = get(u32, &prefix, 0);
        if (length < 58 or length > MaxRecord) return error.Corruption;
        if (length > end - offset) return error.UnexpectedEof;
        const bytes = try readAlloc(self.allocator, file, offset, length);
        errdefer self.allocator.free(bytes);
        try format.validateChunkRecord(self.world_uuid, bytes, self.dimensions);
        return bytes;
    }
    fn recover(self: *Store) !void {
        const base_digest = self.digest;
        const names = try self.directory.names(self.allocator, self.limits.max_segments);
        defer {
            for (names) |name| self.allocator.free(name);
            self.allocator.free(names);
        }
        for (names) |name| {
            const z = try self.allocator.dupeZ(u8, name);
            errdefer self.allocator.free(z);
            const file = try self.directory.file(z, false);
            errdefer file.close();
            var header: [120]u8 = undefined;
            try file.read(&header, 0);
            const version = get(u32, &header, 8);
            if (!std.mem.eql(u8, header[0..8], "ZGWAL\x00\x00\x00") or version < format.minimum_readable_version or version > format.current_write_version or get(u32, &header, 12) != 120 or !std.mem.eql(u8, header[16..32], &self.world_uuid)) return error.Corruption;
            var h = hasher("ZGW-WALHDR-1\x00");
            h.update(header[0..88]);
            var digest: Digest = undefined;
            h.final(&digest);
            if (!std.mem.eql(u8, &digest, header[88..120])) return error.Corruption;
            const pred: SnapshotIdentity = .{ .sequence = get(u64, &header, 48), .digest = header[56..88].* };
            for (self.segments.items) |s| if (std.mem.eql(u8, s.header[32..48], header[32..48])) return error.Corruption;
            var segment: Segment = .{ .name = z, .file = file, .header = header, .predecessor = pred, .end = 120, .final = pred };
            try self.scan(&segment, false);
            try self.segments.append(self.allocator, segment);
        }
        // The chain is determined by validated identities, never directory order.
        while (true) {
            var found: ?usize = null;
            for (self.segments.items, 0..) |s, i| {
                if (s.used or s.predecessor.sequence != self.sequence or !std.mem.eql(u8, &s.predecessor.digest, &self.digest)) continue;
                if (found != null) return error.AmbiguousHistory;
                found = i;
            }
            const i = found orelse break;
            const s = &self.segments.items[i];
            try self.scan(s, true);
            s.used = true;
            // An empty segment cannot make progress; there may only be one such continuation.
            if (s.final.sequence == s.predecessor.sequence) break;
        }
        for (self.segments.items) |s| {
            if (s.used) continue;
            if (s.final.sequence > self.base_sequence or s.predecessor.sequence > self.base_sequence) return error.MissingCommittedDependency;
            if (s.final.sequence == self.base_sequence and !std.mem.eql(u8, &s.final.digest, &base_digest)) return error.Corruption;
            if (s.tail) return error.AmbiguousHistory;
        }
        // Every segment with an incomplete tail must be terminal: no successor may
        // rely on bytes discarded as an uncommitted append.
        for (self.segments.items) |s| if (s.tail) {
            for (self.segments.items) |other| if (other.predecessor.sequence > s.final.sequence and other.predecessor.sequence > self.base_sequence) return error.MissingCommittedDependency;
        };
        self.active = null;
    }
    fn scan(self: *Store, segment: *Segment, apply: bool) !void {
        const file = segment.file;
        const size = try file.size();
        const confirmed_end = segment.end;
        const confirmed_final = segment.final;
        const confirmed_tail = segment.tail;
        errdefer {
            segment.end = confirmed_end;
            segment.final = confirmed_final;
            segment.tail = confirmed_tail;
        }
        var cursor: u64 = 120;
        var previous = segment.predecessor;
        segment.end = 120;
        segment.final = segment.predecessor;
        segment.tail = false;
        while (cursor < size) {
            try self.checkpoint();
            if (size - cursor < 84) {
                try partialMarker(file, cursor, size, "ZGTXBEG1");
                var partial: [84]u8 = @splat(0);
                const available: usize = @intCast(size - cursor);
                try file.read(partial[0..available], cursor);
                if (available >= 16 and get(u64, &partial, 8) <= previous.sequence) return error.Corruption;
                if (available >= 24 and get(u64, &partial, 16) != previous.sequence) return error.Corruption;
                if (available >= 56 and !std.mem.eql(u8, partial[24..56], &previous.digest)) return error.Corruption;
                if (available >= 60 and get(u32, &partial, 56) != 10) return error.Corruption;
                segment.tail = true;
                break;
            }
            const start = cursor;
            var header: [84]u8 = undefined;
            try file.read(&header, cursor);
            if (!std.mem.eql(u8, header[0..8], "ZGTXBEG1")) return error.Corruption;
            const sequence = get(u64, &header, 8);
            if (sequence <= previous.sequence or get(u64, &header, 16) != previous.sequence or !std.mem.eql(u8, header[24..56], &previous.digest)) return error.Corruption;
            const glen = get(u32, &header, 56);
            const pcount = get(u64, &header, 60);
            const plen = get(u64, &header, 68);
            const count = get(u64, &header, 76);
            if (glen != 10 or plen > self.limits.max_players_bytes or count > self.limits.max_chunks) return error.Corruption;
            cursor = try add(cursor, 84);
            if (try add(glen, plen) > size - cursor) {
                segment.tail = true;
                break;
            }
            const global = try readAlloc(self.allocator, file, cursor, glen);
            defer self.allocator.free(global);
            cursor = try add(cursor, glen);
            _ = try format.decodeGlobal(global);
            const players = try readAlloc(self.allocator, file, cursor, plen);
            defer self.allocator.free(players);
            cursor = try add(cursor, plen);
            try format.validatePlayers(players, pcount);
            var hash = hasher("ZGW-WALTX-1\x00");
            hash.update(&segment.header);
            hash.update(&header);
            hash.update(global);
            hash.update(players);
            var changed = std.AutoHashMap(u32, Location).init(self.allocator);
            defer changed.deinit();
            var n: u64 = 0;
            while (n < count) : (n += 1) {
                try self.checkpoint();
                const bytes = self.record(file, cursor, size) catch |err| switch (err) {
                    error.UnexpectedEof => {
                        segment.tail = true;
                        break;
                    },
                    else => return err,
                };
                defer self.allocator.free(bytes);
                const id = get(u32, bytes, 4);
                if (changed.contains(id)) return error.Corruption;
                try changed.put(id, .{ .file = file, .offset = cursor, .length = @intCast(bytes.len), .revision = get(u64, bytes, 8) });
                hash.update(bytes);
                cursor = try add(cursor, bytes.len);
            }
            if (segment.tail) break;
            if (size - cursor < 56) {
                try partialMarker(file, cursor, size, "ZGTXEND1");
                if (size - cursor >= 16) {
                    var partial: [24]u8 = @splat(0);
                    const available: usize = @intCast(@min(24, size - cursor));
                    try file.read(partial[0..available], cursor);
                    if (get(u64, &partial, 8) != cursor - start + 56 or (available >= 24 and get(u64, &partial, 16) != sequence)) return error.Corruption;
                }
                segment.tail = true;
                break;
            }
            var footer: [56]u8 = undefined;
            try file.read(&footer, cursor);
            if (!std.mem.eql(u8, footer[0..8], "ZGTXEND1") or get(u64, &footer, 8) != cursor - start + 56 or get(u64, &footer, 16) != sequence) return error.Corruption;
            hash.update(footer[0..24]);
            var digest: Digest = undefined;
            hash.final(&digest);
            if (!std.mem.eql(u8, &digest, footer[24..56])) return error.Corruption;
            cursor = try add(cursor, 56);
            previous = .{ .sequence = sequence, .digest = digest };
            if (apply) {
                var added: usize = 0;
                var ids = changed.keyIterator();
                while (ids.next()) |id| {
                    if (!self.index.contains(id.*)) added += 1;
                }
                if (self.index.count() + added > self.limits.max_chunks) return error.Capacity;
                try self.index.ensureUnusedCapacity(@intCast(changed.count()));
                const new_global = try self.allocator.dupe(u8, global);
                errdefer self.allocator.free(new_global);
                const new_players = try self.allocator.dupe(u8, players);
                var it = changed.iterator();
                while (it.next()) |entry| self.index.putAssumeCapacity(entry.key_ptr.*, entry.value_ptr.*);
                self.allocator.free(self.global);
                self.allocator.free(self.players);
                self.global = new_global;
                self.players = new_players;
                self.player_count = pcount;
                self.sequence = sequence;
                self.digest = digest;
            }
            segment.end = cursor;
            segment.final = previous;
        }
        if (confirmed_end > 120 and (segment.end != confirmed_end or segment.final.sequence != confirmed_final.sequence or !std.mem.eql(u8, &segment.final.digest, &confirmed_final.digest))) return error.Corruption;
    }
    /// Serial owner operation. Application worker runs this with background QoS;
    /// gameplay loads are queued, so a file handle and its index are one generation.
    pub fn compact(self: *Store) !void {
        if (self.phase != .ready or self.transaction != null or self.compaction_in_flight) return error.WriterBusy;
        const priority = try io.enterBackgroundPriority();
        defer priority.restore() catch |err| std.log.err("Failed to restore compaction thread QoS: {s}", .{@errorName(err)});
        // Verify all input history, including overwritten records, before copying.
        try verifyFile(self.base, try self.base.size(), "ZGW-BASE-1\x00", self.cancellation);
        for (self.segments.items) |*segment| try self.scan(segment, false);
        // A fixed temp identity is safe under the stable exclusive world lock.
        if (self.directory.exists("compact.tmp")) try self.directory.remove("compact.tmp");
        var adopted = false;
        const candidate = try self.directory.file("compact.tmp", true);
        errdefer if (!adopted) candidate.close();
        try self.writeBase(candidate);
        // Recheck source containers after copying; selected bytes themselves are
        // checksum-verified by writeBase. Never bless copied corrupted input.
        try verifyFile(self.base, try self.base.size(), "ZGW-BASE-1\x00", self.cancellation);
        for (self.segments.items) |*segment| try self.scan(segment, false);
        try verifyFile(candidate, try candidate.size(), "ZGW-BASE-1\x00", self.cancellation);
        // Prepare the complete matching generation before publication; after the
        // directory barrier no allocation/read may leave a partially switched index.
        var replacement = std.AutoHashMap(u32, Location).init(self.allocator);
        defer replacement.deinit();
        try replacement.ensureTotalCapacity(@intCast(self.index.count()));
        var pos: u64 = 120 + self.descriptor.len + self.global.len;
        var i: usize = 0;
        while (i < self.index.count()) : (i += 1) {
            var entry: [12]u8 = undefined;
            try candidate.read(&entry, pos);
            pos = try add(pos, 12);
            const id = get(u32, &entry, 0);
            var location = self.index.get(id) orelse return error.Corruption;
            location.file = candidate;
            location.offset = get(u64, &entry, 4);
            replacement.putAssumeCapacity(id, location);
        }
        try candidate.sync();
        try self.directory.rename("compact.tmp", "world.base", false);
        // Retain all inputs and withhold generation publication on barrier failure.
        try self.directory.sync(candidate);
        const old = self.base;
        self.base = candidate;
        self.base_sequence = self.sequence;
        adopted = true;
        std.mem.swap(@TypeOf(self.index), &self.index, &replacement);
        old.close();
        self.active = null;
        // Candidate is installed before retiring any source. A cleanup failure
        // leaves redundant history, which startup validates rather than replaying.
        for (self.segments.items) |segment| try self.directory.remove(segment.name);
        try self.directory.sync(candidate);
        for (self.segments.items) |segment| {
            segment.file.close();
            self.allocator.free(segment.name);
        }
        self.segments.clearRetainingCapacity();
    }
    fn writeBase(self: *Store, output: io.File) !void {
        const count = self.index.count();
        const ids = try self.allocator.alloc(u32, count);
        defer self.allocator.free(ids);
        var keys = self.index.keyIterator();
        var n: usize = 0;
        while (keys.next()) |id| : (n += 1) ids[n] = id.*;
        std.mem.sort(u32, ids, {}, std.sort.asc(u32));
        const index_start: u64 = 120 + self.descriptor.len + self.global.len;
        const player_start = try add(index_start, try mul(count, 12));
        const chunk_start = try add(player_start, self.players.len);
        try output.write(self.descriptor, 120);
        try output.write(self.global, 120 + self.descriptor.len);
        try output.write(self.players, player_start);
        var cursor = chunk_start;
        for (ids, 0..) |id, i| {
            try self.checkpoint();
            const location = self.index.get(id).?;
            const bytes = try self.record(location.file, location.offset, try location.file.size());
            defer self.allocator.free(bytes);
            if (get(u32, bytes, 4) != id or get(u64, bytes, 8) != location.revision or bytes.len != location.length) return error.Corruption;
            var entry: [12]u8 = undefined;
            put(u32, &entry, 0, id);
            put(u64, &entry, 4, cursor);
            try output.write(&entry, index_start + i * 12);
            try output.write(bytes, cursor);
            cursor = try add(cursor, bytes.len);
        }
        var header: [120]u8 = @splat(0);
        @memcpy(header[0..8], "ZGWORLD\x00");
        put(u32, &header, 8, if (self.sequence == 0) self.base_format_version else format.current_write_version);
        put(u32, &header, 12, 120);
        put(u64, &header, 16, try add(cursor, 32));
        @memcpy(header[24..40], &self.world_uuid);
        put(u64, &header, 40, self.sequence);
        @memcpy(header[48..80], &self.digest);
        put(u32, &header, 80, @intCast(self.descriptor.len));
        put(u32, &header, 84, @intCast(self.global.len));
        put(u64, &header, 88, count);
        put(u64, &header, 96, self.player_count);
        put(u64, &header, 104, self.players.len);
        put(u64, &header, 112, cursor - chunk_start);
        try output.write(&header, 0);
        const digest = try hashFile(output, cursor, "ZGW-BASE-1\x00", self.cancellation);
        try output.write(&digest, cursor);
        try output.truncate(try add(cursor, 32));
    }
};
/// Immutable catalog generation. Swap catalogs under a short service mutex;
/// already-prepared read jobs retain a matching fd/offset/revision independently.
pub const BaseCatalog = struct {
    allocator: std.mem.Allocator,
    file: io.File,
    index: std.AutoHashMap(u32, Location),
    world_uuid: Uuid,
    dimensions: [3]u32,
    sequence: u64,
    pub fn deinit(self: *BaseCatalog) void {
        self.file.close();
        self.index.deinit();
        self.* = undefined;
    }
    pub fn revision(self: *const BaseCatalog, id: u32) ?u64 {
        return if (self.index.get(id)) |location| location.revision else null;
    }
    pub fn prepareRead(self: *const BaseCatalog, id: u32) !?BaseRead {
        const location = self.index.get(id) orelse return null;
        return .{ .file = try self.file.duplicate(), .offset = location.offset, .length = location.length, .revision = location.revision, .id = id, .world_uuid = self.world_uuid, .dimensions = self.dimensions };
    }
};
pub const BaseRead = struct {
    file: io.File,
    offset: u64,
    length: u32,
    revision: u64,
    id: u32,
    world_uuid: Uuid,
    dimensions: [3]u32,
    pub fn deinit(self: *BaseRead) void {
        self.file.close();
        self.* = undefined;
    }
    pub fn read(self: *const BaseRead, a: std.mem.Allocator) ![]u8 {
        const bytes = try readAlloc(a, self.file, self.offset, self.length);
        errdefer a.free(bytes);
        try format.validateChunkRecord(self.world_uuid, bytes, self.dimensions);
        if (get(u32, bytes, 4) != self.id or get(u64, bytes, 8) != self.revision) return error.Corruption;
        return bytes;
    }
};
/// Detached generation: allocator must support concurrent worker allocations.
/// Deinitialize only after run has stopped and install/abandon has completed.
pub const Compaction = struct {
    store: Store,
    completed: bool = false,
    sealed: []Uuid,
    cancellation: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),
    pub fn cancel(self: *Compaction) void {
        self.cancellation.store(true, .release);
    }
    pub fn run(self: *Compaction) !void {
        try self.runWithCancellation(&self.cancellation);
    }
    pub fn runWithCancellation(self: *Compaction, flag: *std.atomic.Value(bool)) !void {
        self.store.cancellation = flag;
        defer self.store.cancellation = null;
        try self.store.compact();
        self.completed = true;
    }
    pub fn deinit(self: *Compaction) void {
        self.store.allocator.free(self.sealed);
        self.store.deinit();
        self.* = undefined;
    }
};
fn partialMarker(file: io.File, offset: u64, end: u64, marker: *const [8]u8) !void {
    var prefix: [8]u8 = undefined;
    const length: usize = @intCast(@min(8, end - offset));
    try file.read(prefix[0..length], offset);
    if (!std.mem.eql(u8, prefix[0..length], marker[0..length])) return error.Corruption;
}
fn hasher(domain: []const u8) std.crypto.hash.Blake3 {
    var h = std.crypto.hash.Blake3.init(.{});
    h.update(domain);
    return h;
}
fn put(comptime T: type, bytes: []u8, offset: usize, value: T) void {
    std.mem.writeInt(T, bytes[offset..][0..@sizeOf(T)], value, .little);
}
fn get(comptime T: type, bytes: []const u8, offset: usize) T {
    return std.mem.readInt(T, bytes[offset..][0..@sizeOf(T)], .little);
}
fn hashInt(h: *std.crypto.hash.Blake3, comptime T: type, value: T) void {
    var bytes: [@sizeOf(T)]u8 = undefined;
    put(T, &bytes, 0, value);
    h.update(&bytes);
}
fn add(a: u64, b: u64) !u64 {
    return std.math.add(u64, a, b) catch error.Corruption;
}
fn mul(a: u64, b: u64) !u64 {
    return std.math.mul(u64, a, b) catch error.Corruption;
}
fn readAlloc(a: std.mem.Allocator, file: io.File, offset: u64, length: u64) ![]u8 {
    const bytes = try a.alloc(u8, std.math.cast(usize, length) orelse return error.Capacity);
    errdefer a.free(bytes);
    try file.read(bytes, offset);
    return bytes;
}
fn hashFile(file: io.File, end: u64, domain: []const u8, cancel: ?*std.atomic.Value(bool)) !Digest {
    var hash = hasher(domain);
    var buffer: [64 * 1024]u8 = undefined;
    var cursor: u64 = 0;
    while (cursor < end) {
        if (cancel) |flag| {
            if (flag.load(.acquire)) return error.Cancelled;
            try std.Thread.yield();
        }
        const length: usize = @intCast(@min(buffer.len, end - cursor));
        try file.read(buffer[0..length], cursor);
        hash.update(buffer[0..length]);
        cursor += length;
    }
    var digest: Digest = undefined;
    hash.final(&digest);
    return digest;
}
fn verifyFile(file: io.File, size: u64, domain: []const u8, cancel: ?*std.atomic.Value(bool)) !void {
    if (size < 32) return error.Corruption;
    const digest = try hashFile(file, size - 32, domain, cancel);
    var expected: Digest = undefined;
    try file.read(&expected, size - 32);
    if (!std.mem.eql(u8, &digest, &expected)) return error.Corruption;
}

test "checked file arithmetic never wraps" {
    try std.testing.expectError(error.Corruption, add(std.math.maxInt(u64), 1));
    try std.testing.expectError(error.Corruption, mul(std.math.maxInt(u64), 12));
}

test "native durable creation, WAL commit, repair, recovery, and indexed base reads" {
    const a = std.testing.allocator;
    var uuid: Uuid = undefined;
    std.c.arc4random_buf(&uuid, uuid.len);
    const path = try std.fmt.allocPrintSentinel(a, "/private/tmp/zig-world-{x}", .{uuid}, 0);
    defer a.free(path);
    defer std.Io.Dir.cwd().deleteTree(std.testing.io, path) catch {};
    const descriptor = try format.encodeDescriptor(a, .{ .dimensions = .{ 4, 4, 4 }, .generator_id = 2, .seed = 0, .settings = &format.flat_settings });
    defer a.free(descriptor);
    const global = format.encodeGlobal(0);
    var store = try Store.create(a, path, .{ .world_uuid = uuid, .descriptor = descriptor, .global = &global, .players = &.{}, .player_count = 0 }, .{});
    try std.testing.expectError(error.Busy, Store.open(a, path, .{}));
    var blocks: [32768]u8 = @splat(0);
    blocks[17] = 1;
    const encoded = try format.encodeChunk(a, uuid, .{ .id = 1, .revision = 1, .is_unreachable = false, .blocks = &blocks, .metadata = &.{} });
    defer a.free(encoded);
    const later = format.encodeGlobal(60);
    try store.beginSnapshot(1, &later, &.{}, 0, 1);
    try store.appendChunk(encoded);
    _ = try store.commitSnapshot();
    try store.beginSnapshot(2, &later, &.{}, 0, 0);
    try store.cancelSnapshot();
    try std.testing.expectEqual(Phase.ready, store.phase);
    try store.rotate();
    try store.beginSnapshot(3, &later, &.{}, 0, 0);
    _ = try store.commitSnapshot();
    store.deinit();
    store = try Store.open(a, path, .{});
    defer store.deinit();
    try std.testing.expectEqual(@as(u64, 3), store.sequence);
    const read = (try store.readChunk(a, 1)).?;
    defer a.free(read);
    try std.testing.expectEqualSlices(u8, encoded, read);
    var compact = try store.prepareCompaction();
    defer compact.deinit();
    try store.beginSnapshot(4, &later, &.{}, 0, 0);
    _ = try store.commitSnapshot();
    try compact.run();
    try store.installCompaction(&compact);
    try std.testing.expectEqual(@as(u64, 4), store.sequence);
    try std.testing.expectEqual(@as(u64, 3), store.base_sequence);
    try std.testing.expectEqual(@as(?u64, 1), store.baseRevision(1));
    try store.compact();
}

const Fixture = struct {
    path: [:0]u8,
    store: Store,
    fn init() !Fixture {
        const a = std.testing.allocator;
        var uuid: Uuid = undefined;
        std.c.arc4random_buf(&uuid, uuid.len);
        const path = try std.fmt.allocPrintSentinel(a, "/private/tmp/zig-persistence-fault-{x}", .{uuid}, 0);
        errdefer a.free(path);
        const descriptor = try format.encodeDescriptor(a, .{ .dimensions = .{ 4, 4, 4 }, .generator_id = 2, .seed = 0, .settings = &format.flat_settings });
        defer a.free(descriptor);
        const global = format.encodeGlobal(0);
        return .{ .path = path, .store = try Store.create(a, path, .{ .world_uuid = uuid, .descriptor = descriptor, .global = &global, .players = &.{}, .player_count = 0 }, .{}) };
    }
    fn deinit(self: *Fixture) void {
        self.store.setFaults(null);
        self.store.deinit();
        // Open only for bounded test cleanup. Production never removes world.lock.
        const dir = io.Directory.open(self.path) catch {
            std.testing.allocator.free(self.path);
            return;
        };
        const names = dir.names(std.testing.allocator, 128) catch unreachable;
        for (names) |name| {
            const z = std.testing.allocator.dupeZ(u8, name) catch unreachable;
            dir.remove(z) catch {};
            std.testing.allocator.free(z);
            std.testing.allocator.free(name);
        }
        std.testing.allocator.free(names);
        for ([_][:0]const u8{ "world.base", "world.lock", "compact.tmp", "initial.tmp", "initial-chunks.tmp", "segment.pending" }) |name| dir.remove(name) catch {};
        dir.close();
        io.removeDirectory(self.path);
        std.testing.allocator.free(self.path);
    }
    fn reopen(self: *Fixture) !void {
        self.store.setFaults(null);
        self.store.deinit();
        self.store = try Store.open(std.testing.allocator, self.path, .{});
    }
};

test "torn append and failed truncation/fullflush require successful repair before retry" {
    var f = try Fixture.init();
    defer f.deinit();
    const tick = format.encodeGlobal(12);
    var fault: io.Faults = .{ .operation = .write, .partial_write = 17 };
    f.store.setFaults(&fault);
    try std.testing.expectError(error.Io, f.store.beginSnapshot(1, &tick, &.{}, 0, 0));
    try std.testing.expectEqual(Phase.repair_required, f.store.phase);
    try std.testing.expectError(error.WriterBusy, f.store.rotate());
    fault = .{ .operation = .truncate };
    try std.testing.expectError(error.Io, f.store.repair());
    try std.testing.expectEqual(Phase.repair_required, f.store.phase);
    fault = .{ .operation = .full_sync };
    try std.testing.expectError(error.Io, f.store.repair());
    try std.testing.expectEqual(Phase.repair_required, f.store.phase);
    try f.store.repair();
    try f.store.beginSnapshot(2, &tick, &.{}, 0, 0);
    _ = try f.store.commitSnapshot();
    try f.reopen();
    try std.testing.expectEqual(@as(u64, 2), f.store.sequence);
}

test "failed commit synchronization is unacknowledged and repaired to memory boundary" {
    var f = try Fixture.init();
    defer f.deinit();
    const tick = format.encodeGlobal(12);
    try f.store.beginSnapshot(1, &tick, &.{}, 0, 0);
    var fault: io.Faults = .{ .operation = .full_sync };
    f.store.setFaults(&fault);
    try std.testing.expectError(error.Io, f.store.commitSnapshot());
    try std.testing.expectEqual(@as(u64, 0), f.store.sequence);
    try std.testing.expectEqual(Phase.repair_required, f.store.phase);
    try f.store.repair();
    try f.reopen();
    try std.testing.expectEqual(@as(u64, 0), f.store.sequence);
}

test "restart may recover complete unacknowledged commit after sync error" {
    var f = try Fixture.init();
    defer f.deinit();
    const tick = format.encodeGlobal(12);
    try f.store.beginSnapshot(1, &tick, &.{}, 0, 0);
    var fault: io.Faults = .{ .operation = .full_sync };
    f.store.setFaults(&fault);
    try std.testing.expectError(error.Io, f.store.commitSnapshot());
    try f.reopen();
    try std.testing.expectEqual(@as(u64, 1), f.store.sequence);
}

test "compaction primitive failures preserve committed state across restart" {
    for ([_]io.Operation{ .write, .full_sync, .rename, .directory_sync, .remove }) |operation| {
        var f = try Fixture.init();
        defer f.deinit();
        const tick = format.encodeGlobal(99);
        try f.store.beginSnapshot(7, &tick, &.{}, 0, 0);
        _ = try f.store.commitSnapshot();
        var fault: io.Faults = .{ .operation = operation };
        f.store.setFaults(&fault);
        try std.testing.expectError(error.Io, f.store.compact());
        try f.reopen();
        try std.testing.expectEqual(@as(u64, 7), f.store.sequence);
        try std.testing.expectEqual(@as(u64, 99), try format.decodeGlobal(f.store.global));
    }
}

test "incomplete final transaction is excluded but complete digest corruption is fatal" {
    var f = try Fixture.init();
    defer f.deinit();
    const tick = format.encodeGlobal(20);
    try f.store.beginSnapshot(1, &tick, &.{}, 0, 0);
    _ = try f.store.commitSnapshot();
    try f.store.beginSnapshot(2, &tick, &.{}, 0, 0);
    // Crash before the footer: restart validates and retains snapshot one.
    try f.reopen();
    try std.testing.expectEqual(@as(u64, 1), f.store.sequence);
    try f.store.beginSnapshot(3, &tick, &.{}, 0, 0);
    _ = try f.store.commitSnapshot();
    const segment = f.store.segments.items[f.store.active.?];
    const before = try segment.file.size();
    var bad: [1]u8 = undefined;
    try segment.file.read(&bad, before - 1);
    bad[0] ^= 0xff;
    try segment.file.write(&bad, before - 1);
    try segment.file.sync();
    // Keep the owner object alive so cleanup can preserve evidence after failed open.
    const path = f.path;
    f.store.deinit();
    try std.testing.expectError(error.Corruption, Store.open(std.testing.allocator, path, .{}));
    // Reconstruct the test-only cleanup owner without loading corrupt history.
    const dir = try io.Directory.open(path);
    const raw = try dir.file("world.base", false);
    f.store = .{ .allocator = std.testing.allocator, .directory = dir, .limits = .{}, .world_uuid = @splat(0), .dimensions = .{ 4, 4, 4 }, .descriptor = try std.testing.allocator.alloc(u8, 0), .global = try std.testing.allocator.alloc(u8, 0), .players = try std.testing.allocator.alloc(u8, 0), .player_count = 0, .sequence = 0, .digest = @splat(0), .base = raw, .base_sequence = 0, .index = std.AutoHashMap(u32, Location).init(std.testing.allocator) };
    const wal_names = try dir.names(std.testing.allocator, 128);
    defer std.testing.allocator.free(wal_names);
    for (wal_names) |name| {
        defer std.testing.allocator.free(name);
        const z = try std.testing.allocator.dupeZ(u8, name);
        defer std.testing.allocator.free(z);
        const wal = try dir.file(z, false);
        defer wal.close();
        try std.testing.expectEqual(before, try wal.size());
    }
}

test "detached cancellation preserves inputs and newer WAL commits" {
    var f = try Fixture.init();
    defer f.deinit();
    const tick = format.encodeGlobal(1);
    try f.store.beginSnapshot(1, &tick, &.{}, 0, 0);
    _ = try f.store.commitSnapshot();
    var compact = try f.store.prepareCompaction();
    compact.cancel();
    try std.testing.expectError(error.Cancelled, compact.run());
    f.store.abandonCompaction();
    compact.deinit();
    try f.store.beginSnapshot(2, &tick, &.{}, 0, 0);
    _ = try f.store.commitSnapshot();
    try f.reopen();
    try std.testing.expectEqual(@as(u64, 2), f.store.sequence);
}

test "rotation establishes complete headers before admission and retries uncertain barriers" {
    for ([_]io.Operation{ .write, .full_sync, .rename, .directory_sync }) |operation| {
        var f = try Fixture.init();
        defer f.deinit();
        const tick = format.encodeGlobal(1);
        try f.store.beginSnapshot(1, &tick, &.{}, 0, 0);
        _ = try f.store.commitSnapshot();
        var fault: io.Faults = .{ .operation = operation, .partial_write = 23 };
        f.store.setFaults(&fault);
        try std.testing.expectError(error.Io, f.store.rotate());
        f.store.setFaults(null);
        // Retrying is required before a transaction can be acknowledged.
        try f.store.beginSnapshot(2, &tick, &.{}, 0, 0);
        _ = try f.store.commitSnapshot();
        try f.reopen();
        try std.testing.expectEqual(@as(u64, 2), f.store.sequence);
    }
}

test "old indexed read handles survive replacement while latest catalog tracks exact revisions" {
    var f = try Fixture.init();
    defer f.deinit();
    const a = std.testing.allocator;
    const tick = format.encodeGlobal(1);
    var blocks: [32768]u8 = @splat(0);
    blocks[3] = 1;
    const first = try format.encodeChunk(a, f.store.world_uuid, .{ .id = 1, .revision = 1, .is_unreachable = false, .blocks = &blocks, .metadata = &.{} });
    defer a.free(first);
    try f.store.beginSnapshot(1, &tick, &.{}, 0, 1);
    try f.store.appendChunk(first);
    _ = try f.store.commitSnapshot();
    try f.store.compact();
    var catalog = try f.store.snapshotCatalog();
    var read = (try catalog.prepareRead(1)).?;
    defer read.deinit();
    catalog.deinit();
    blocks[3] = 2;
    const second = try format.encodeChunk(a, f.store.world_uuid, .{ .id = 1, .revision = 2, .is_unreachable = true, .blocks = &blocks, .metadata = &.{} });
    defer a.free(second);
    try f.store.beginSnapshot(2, &tick, &.{}, 0, 1);
    try f.store.appendChunk(second);
    _ = try f.store.commitSnapshot();
    try std.testing.expectEqual(@as(?u64, null), f.store.baseRevision(1));
    var compact = try f.store.prepareCompaction();
    defer compact.deinit();
    try compact.run();
    try f.store.installCompaction(&compact);
    const old = try read.read(a);
    defer a.free(old);
    try std.testing.expectEqualSlices(u8, first, old);
    var latest = try f.store.snapshotCatalog();
    defer latest.deinit();
    try std.testing.expectEqual(@as(?u64, 2), latest.revision(1));
    var current = (try latest.prepareRead(1)).?;
    defer current.deinit();
    const bytes = try current.read(a);
    defer a.free(bytes);
    try std.testing.expectEqualSlices(u8, second, bytes);
    // Corruption after startup is checked on every indexed read.
    const bad: [1]u8 = .{bytes[bytes.len - 1] ^ 0xff};
    try current.file.write(&bad, current.offset + current.length - 1);
    if (current.read(a)) |unexpected| {
        a.free(unexpected);
        return error.ExpectedChecksumMismatch;
    } else |err| try std.testing.expectEqual(error.ChecksumMismatch, err);
}

test "missing committed predecessor fails without deleting surviving evidence" {
    var f = try Fixture.init();
    defer f.deinit();
    const a = std.testing.allocator;
    const tick = format.encodeGlobal(1);
    try f.store.beginSnapshot(1, &tick, &.{}, 0, 0);
    _ = try f.store.commitSnapshot();
    const missing = try a.dupeZ(u8, f.store.segments.items[f.store.active.?].name);
    defer a.free(missing);
    try f.store.rotate();
    try f.store.beginSnapshot(2, &tick, &.{}, 0, 0);
    _ = try f.store.commitSnapshot();
    try f.store.directory.remove(missing);
    f.store.deinit();
    try std.testing.expectError(error.MissingCommittedDependency, Store.open(a, f.path, .{}));
    // The surviving WAL must remain untouched. Build only a cleanup owner.
    const dir = try io.Directory.open(f.path);
    const raw = try dir.file("world.base", false);
    f.store = .{ .allocator = a, .directory = dir, .limits = .{}, .world_uuid = @splat(0), .dimensions = .{ 4, 4, 4 }, .descriptor = try a.alloc(u8, 0), .global = try a.alloc(u8, 0), .players = try a.alloc(u8, 0), .player_count = 0, .sequence = 0, .digest = @splat(0), .base = raw, .base_sequence = 0, .index = std.AutoHashMap(u32, Location).init(a) };
    const names = try dir.names(a, 128);
    defer a.free(names);
    defer for (names) |name| a.free(name);
    try std.testing.expectEqual(@as(usize, 1), names.len);
}

test "modeled power loss distinguishes unacknowledged sync survival and validates logical snapshot contents" {
    const a = std.testing.allocator;
    for ([_]bool{ false, true }) |failed_sync_survives| for ([_]io.Model.Survival{ .lose_unsynced, .survive_unsynced }) |survival| {
        var model = io.Model.init(a);
        defer model.deinit();
        io.test_model = &model;
        defer io.test_model = null;
        var f = try Fixture.init();
        defer f.deinit();
        var blocks: [32768]u8 = @splat(0);
        blocks[9] = 2;
        const record = try format.encodeChunk(a, f.store.world_uuid, .{ .id = 2, .revision = 37, .is_unreachable = true, .blocks = &blocks, .metadata = &.{} });
        defer a.free(record);
        const player = try format.encodePlayer(.{ .id = 99, .feet = .{ 12.5, 1.5, 2.5 }, .yaw = 0.25, .pitch = -0.5 });
        const tick = format.encodeGlobal(321);
        try f.store.beginSnapshot(8, &tick, &player, 1, 1);
        try f.store.appendChunk(record);
        model.failed_sync_survives = failed_sync_survives;
        var fault: io.Faults = .{ .operation = .full_sync };
        f.store.setFaults(&fault);
        try std.testing.expectError(error.Io, f.store.commitSnapshot());
        try std.testing.expectEqual(@as(u64, 0), f.store.sequence);
        f.store.setFaults(null);
        try model.crash(survival);
        f.store.deinit();
        f.store = try Store.open(a, f.path, .{});
        const survives = failed_sync_survives or survival == .survive_unsynced;
        try std.testing.expectEqual(@as(u64, if (survives) 8 else 0), f.store.sequence);
        try std.testing.expectEqual(@as(u64, if (survives) 321 else 0), try format.decodeGlobal(f.store.global));
        try std.testing.expectEqual(@as(u64, if (survives) 1 else 0), f.store.player_count);
        const loaded = try f.store.readChunk(a, 2);
        if (survives) {
            defer a.free(loaded.?);
            var decoded = try format.decodeChunk(a, f.store.world_uuid, loaded.?, f.store.dimensions);
            defer decoded.deinit(a);
            try std.testing.expectEqualSlices(u8, &blocks, decoded.blocks);
            try std.testing.expectEqual(@as(u64, 37), decoded.revision);
            try std.testing.expect(decoded.is_unreachable);
            const restored = try format.decodePlayer(f.store.players);
            try std.testing.expectEqual(@as(u64, 99), restored.id);
            try std.testing.expectEqual(@as(f64, 12.5), restored.feet[0]);
            try std.testing.expectEqual(@as(f32, -0.5), restored.pitch);
        } else try std.testing.expect(loaded == null);
    };
}

test "modeled rename before directory barrier and reappearing retired segments retain committed state" {
    const a = std.testing.allocator;
    for ([_]usize{ 0, 1 }) |failed_directory_barrier| for ([_]io.Model.Survival{ .lose_unsynced, .survive_unsynced }) |survival| {
        var model = io.Model.init(a);
        defer model.deinit();
        io.test_model = &model;
        defer io.test_model = null;
        var f = try Fixture.init();
        defer f.deinit();
        const tick = format.encodeGlobal(123);
        try f.store.beginSnapshot(1, &tick, &.{}, 0, 0);
        _ = try f.store.commitSnapshot();
        var fault: io.Faults = .{ .operation = .directory_sync, .after = failed_directory_barrier };
        f.store.setFaults(&fault);
        try std.testing.expectError(error.Io, f.store.compact());
        f.store.setFaults(null);
        try model.crash(survival);
        f.store.deinit();
        // Inspect the modeled namespace before recovery mutates it: this checks
        // the syscall ordering itself, rather than asserting a separate protocol.
        const base_id = try model.open("world.base", false);
        var header: [120]u8 = undefined;
        try model.read(base_id, &header, 0);
        model.close(base_id);
        const expected_base: u64 = if (failed_directory_barrier == 0 and survival == .lose_unsynced) 0 else 1;
        try std.testing.expectEqual(expected_base, get(u64, &header, 40));
        const names = try model.names(a, 128);
        defer {
            for (names) |name| a.free(name);
            a.free(names);
        }
        if (survival == .lose_unsynced) try std.testing.expect(names.len > 0);
        if (failed_directory_barrier == 1 and survival == .survive_unsynced) try std.testing.expectEqual(@as(usize, 0), names.len);
        f.store = try Store.open(a, f.path, .{});
        try std.testing.expectEqual(@as(u64, 1), f.store.sequence);
        try std.testing.expectEqual(@as(u64, 123), try format.decodeGlobal(f.store.global));
    };
}

test "modeled unsynced partial appends and repaired lengths obey power-loss boundaries" {
    const a = std.testing.allocator;
    for ([_]io.Model.Survival{ .lose_unsynced, .survive_unsynced }) |survival| {
        var model = io.Model.init(a);
        defer model.deinit();
        io.test_model = &model;
        defer io.test_model = null;
        var f = try Fixture.init();
        defer f.deinit();
        const tick = format.encodeGlobal(1);
        try f.store.beginSnapshot(1, &tick, &.{}, 0, 0);
        _ = try f.store.commitSnapshot();
        var fault: io.Faults = .{ .operation = .write, .partial_write = 25 };
        f.store.setFaults(&fault);
        try std.testing.expectError(error.Io, f.store.beginSnapshot(2, &tick, &.{}, 0, 0));
        f.store.setFaults(null);
        try model.crash(survival);
        f.store.deinit();
        f.store = try Store.open(a, f.path, .{});
        try std.testing.expectEqual(@as(u64, 1), f.store.sequence);
        try f.store.beginSnapshot(3, &tick, &.{}, 0, 0);
        try f.store.cancelSnapshot();
        try model.crash(survival);
        f.store.deinit();
        f.store = try Store.open(a, f.path, .{});
        try std.testing.expectEqual(@as(u64, 1), f.store.sequence);
    }
}

test "modeled crash releases stable ownership while live compaction references retain it" {
    const a = std.testing.allocator;
    var model = io.Model.init(a);
    defer model.deinit();
    io.test_model = &model;
    defer io.test_model = null;
    var f = try Fixture.init();
    defer f.deinit();
    var compact = try f.store.prepareCompaction();
    f.store.deinit();
    try std.testing.expectError(error.Busy, Store.open(a, f.path, .{}));
    try model.crash(.lose_unsynced);
    compact.deinit();
    f.store = try Store.open(a, f.path, .{});
}

test "snapshot zero includes initial overrides and canonical players and survives reopen" {
    const a = std.testing.allocator;
    var model = io.Model.init(a);
    defer model.deinit();
    io.test_model = &model;
    defer io.test_model = null;
    const uuid: Uuid = @splat(0x4a);
    const descriptor = try format.encodeDescriptor(a, .{ .dimensions = .{ 4, 4, 4 }, .generator_id = 2, .seed = 0, .settings = &format.flat_settings });
    defer a.free(descriptor);
    var blocks: [32768]u8 = @splat(0);
    blocks[17] = 1;
    const encoded = try format.encodeChunk(a, uuid, .{ .id = 2, .revision = 9, .is_unreachable = true, .blocks = &blocks, .metadata = &.{} });
    defer a.free(encoded);
    const player = try format.encodePlayer(.{ .id = 17, .feet = .{ 1, 2, 3 }, .yaw = 0.5, .pitch = 0.25 });
    const tick = format.encodeGlobal(7);
    var store = try Store.create(a, "model", .{ .world_uuid = uuid, .descriptor = descriptor, .global = &tick, .players = &player, .player_count = 1, .chunks = &.{encoded} }, .{});
    const initial_digest = store.digest;
    store.deinit();
    try model.crash(.lose_unsynced);
    store = try Store.open(a, "model", .{});
    defer store.deinit();
    try std.testing.expectEqualSlices(u8, &initial_digest, &store.digest);
    try std.testing.expectEqual(@as(u64, 0), store.sequence);
    try std.testing.expectEqual(@as(u64, 7), try format.decodeGlobal(store.global));
    const record = (try store.readChunk(a, 2)).?;
    defer a.free(record);
    try std.testing.expectEqualSlices(u8, encoded, record);
    try std.testing.expectEqualSlices(u8, &player, store.players);
}

test "natural and seeded flat identities survive durable creation and reopen" {
    const a = std.testing.allocator;
    const natural_settings = format.encodeNaturalSettings(.{ .climate_displacement = 112, .island_count = 10 });
    const descriptors = [_]format.Descriptor{
        .{ .dimensions = .{ 4, 4, 4 }, .generator_id = format.generator_id, .seed = 0x123456789abcdef0, .settings = &format.flat_settings },
        .{ .dimensions = .{ 2048, 1024, 32 }, .generator_id = format.generator_id, .seed = 0xfedcba9876543210, .settings = &natural_settings },
    };
    for (descriptors) |descriptor| {
        var model = io.Model.init(a);
        defer model.deinit();
        io.test_model = &model;
        defer io.test_model = null;
        const encoded_descriptor = try format.encodeDescriptor(a, descriptor);
        defer a.free(encoded_descriptor);
        const global = format.encodeGlobal(0);
        var store = try Store.create(a, "model", .{ .world_uuid = @splat(0x6b), .descriptor = encoded_descriptor, .global = &global, .players = &.{}, .player_count = 0 }, .{});
        store.deinit();
        try model.crash(.lose_unsynced);
        store = try Store.open(a, "model", .{});
        defer store.deinit();
        const restored = try format.decodeDescriptor(store.descriptor);
        try std.testing.expectEqualDeep(descriptor, restored);
        try format.validateRuntimeIdentity(restored, descriptor.dimensions, descriptor.seed, try format.decodeGeneratorSettings(descriptor.settings));
    }
}

test "checksummed invalid descriptors fail before recovery or source retirement" {
    const a = std.testing.allocator;
    const Case = struct { offset: usize, value: u8, expected: anyerror };
    for ([_]Case{
        .{ .offset = 120, .value = 2, .expected = error.UnsupportedVersion },
        .{ .offset = 122, .value = 2, .expected = error.UnsupportedVersion },
        .{ .offset = 124, .value = 16, .expected = error.UnsupportedVersion },
        .{ .offset = 126, .value = 3, .expected = error.InvalidDescriptor },
        .{ .offset = 138, .value = 0, .expected = error.InvalidDescriptor },
        .{ .offset = 139, .value = 0, .expected = error.UnsupportedGenerator },
        .{ .offset = 139, .value = 1, .expected = error.UnsupportedGenerator },
        .{ .offset = 139, .value = 3, .expected = error.UnsupportedGenerator },
        .{ .offset = 141, .value = 2, .expected = error.UnsupportedVersion },
        .{ .offset = 157, .value = 255, .expected = error.UnsupportedGenerator },
        .{ .offset = 158, .value = 61, .expected = error.InvalidDescriptor },
    }) |case| {
        var model = io.Model.init(a);
        defer model.deinit();
        io.test_model = &model;
        defer io.test_model = null;
        var f = try Fixture.init();
        const base = try f.store.base.duplicate();
        defer base.close();
        const size = try base.size();
        f.store.deinit();
        try base.write(&.{case.value}, case.offset);
        const digest = try hashFile(base, size - 32, "ZGW-BASE-1\x00", null);
        try base.write(&digest, size - 32);
        try base.sync();
        const before = try readAlloc(a, base, 0, size);
        defer a.free(before);
        const before_names = model.working.items.len;
        try std.testing.expectError(case.expected, Store.open(a, f.path, .{}));
        const after = try readAlloc(a, base, 0, size);
        defer a.free(after);
        try std.testing.expectEqualSlices(u8, before, after);
        try std.testing.expectEqual(before_names, model.working.items.len);
        a.free(f.path);
    }
}

test "controlled commit rejects before hash mutation and durable footer I/O" {
    var f = try Fixture.init();
    defer f.deinit();
    const tick = format.encodeGlobal(1);
    try f.store.beginSnapshot(1, &tick, &.{}, 0, 0);
    const before = try f.store.segments.items[f.store.active.?].file.size();
    var allowed = false;
    const Gate = struct {
        fn authorize(context: *anyopaque) bool {
            const value: *bool = @ptrCast(@alignCast(context));
            return value.*;
        }
    };
    try std.testing.expectError(error.Cancelled, f.store.commitSnapshotControlled(&allowed, Gate.authorize));
    try std.testing.expectEqual(Phase.appending, f.store.phase);
    try std.testing.expectEqual(before, try f.store.segments.items[f.store.active.?].file.size());
    allowed = true;
    _ = try f.store.commitSnapshotControlled(&allowed, Gate.authorize);
    try f.reopen();
    try std.testing.expectEqual(@as(u64, 1), f.store.sequence);
}

test "native file offsets and durable sparse lengths exceed four GiB" {
    var f = try Fixture.init();
    defer f.deinit();
    const file = try f.store.directory.file("large.tmp", true);
    defer file.close();
    defer f.store.directory.remove("large.tmp") catch {};
    const offset: u64 = (@as(u64, 1) << 32) + 17;
    const bytes = [_]u8{ 1, 2, 3, 4 };
    try file.write(&bytes, offset);
    try file.sync();
    try std.testing.expectEqual(offset + bytes.len, try file.size());
    var restored: [4]u8 = undefined;
    try file.read(&restored, offset);
    try std.testing.expectEqualSlices(u8, &bytes, &restored);
    try file.truncate(offset + 2);
    try file.sync();
    try std.testing.expectEqual(offset + 2, try file.size());
}

test "modeled crash never publishes half a multi-chunk snapshot or its global/player state" {
    const a = std.testing.allocator;
    var model = io.Model.init(a);
    defer model.deinit();
    io.test_model = &model;
    defer io.test_model = null;
    var f = try Fixture.init();
    defer f.deinit();
    var blocks: [32768]u8 = @splat(0);
    blocks[0] = 255;
    const player1 = try format.encodePlayer(.{ .id = 1, .feet = .{ 1, 2, 3 }, .yaw = 0, .pitch = 0, .inventory = 2 });
    const tick1 = format.encodeGlobal(60);
    try f.store.beginSnapshot(1, &tick1, &player1, 1, 2);
    for (0..2) |section| {
        const metadata = try format.encodeMetadata(a, .{ .roads = &.{.{ .formation = .{ .high_endpoint = .{ 32, 0, 0 }, .direction = 1, .length = 2, .section = @intCast(section) } }}, .construction = &.{0}, .timers = &.{.{ .cell = 0, .kind = 1, .deadline = 100 }} });
        defer a.free(metadata);
        const record = try format.encodeChunk(a, f.store.world_uuid, .{ .id = @intCast(section), .revision = 1, .is_unreachable = section == 1, .blocks = &blocks, .metadata = metadata });
        defer a.free(record);
        try f.store.appendChunk(record);
    }
    _ = try f.store.commitSnapshot();
    const player2 = try format.encodePlayer(.{ .id = 1, .feet = .{ 9, 9, 9 }, .yaw = 1, .pitch = 1, .inventory = 8 });
    const tick2 = format.encodeGlobal(120);
    try f.store.beginSnapshot(2, &tick2, &player2, 1, 2);
    @memset(&blocks, 0);
    const changed = try format.encodeChunk(a, f.store.world_uuid, .{ .id = 0, .revision = 2, .is_unreachable = false, .blocks = &blocks, .metadata = &.{} });
    defer a.free(changed);
    try f.store.appendChunk(changed);
    // All unsynced bytes survive, including one newer chunk and newer global/player
    // records. The missing second chunk/footer must exclude this entire snapshot.
    try model.crash(.survive_unsynced);
    f.store.deinit();
    f.store = try Store.open(a, f.path, .{});
    try std.testing.expectEqual(@as(u64, 1), f.store.sequence);
    try std.testing.expectEqual(@as(u64, 60), try format.decodeGlobal(f.store.global));
    const player = try format.decodePlayer(f.store.players);
    try std.testing.expectEqual(@as(f64, 1), player.feet[0]);
    try std.testing.expectEqual(@as(?u8, 2), player.inventory);
    for (0..2) |section| {
        const record = (try f.store.readChunk(a, @intCast(section))).?;
        defer a.free(record);
        var chunk = try format.decodeChunk(a, f.store.world_uuid, record, f.store.dimensions);
        defer chunk.deinit(a);
        try std.testing.expectEqual(@as(u64, 1), chunk.revision);
        try std.testing.expectEqual(@as(u8, 255), chunk.blocks[0]);
        try std.testing.expectEqual(section == 1, chunk.is_unreachable);
        var meta = try format.decodeMetadata(a, chunk.blocks, chunk.metadata, f.store.dimensions);
        defer meta.deinit(a);
        try std.testing.expectEqual(@as(u32, @intCast(section)), meta.roads[0].formation.?.section);
        try std.testing.expectEqual(@as(u16, 0), meta.construction[0]);
        try std.testing.expectEqual(@as(u64, 100), meta.timers[0].deadline);
    }
}

test "modeled failed fullflush at publication and retirement has both uncertain outcomes" {
    const a = std.testing.allocator;
    for ([_]usize{ 1, 2 }) |failed_flush| for ([_]bool{ false, true }) |survives| {
        var model = io.Model.init(a);
        defer model.deinit();
        io.test_model = &model;
        defer io.test_model = null;
        var f = try Fixture.init();
        defer f.deinit();
        const tick = format.encodeGlobal(99);
        try f.store.beginSnapshot(1, &tick, &.{}, 0, 0);
        _ = try f.store.commitSnapshot();
        model.failed_sync_survives = survives;
        var fault: io.Faults = .{ .operation = .full_sync, .after = failed_flush };
        f.store.setFaults(&fault);
        try std.testing.expectError(error.Io, f.store.compact());
        f.store.setFaults(null);
        try model.crash(.lose_unsynced);
        f.store.deinit();
        const id = try model.open("world.base", false);
        var header: [120]u8 = undefined;
        try model.read(id, &header, 0);
        model.close(id);
        try std.testing.expectEqual(@as(u64, if (failed_flush == 1 and !survives) 0 else 1), get(u64, &header, 40));
        const names = try model.names(a, 128);
        defer {
            for (names) |name| a.free(name);
            a.free(names);
        }
        if (failed_flush == 2 and survives) try std.testing.expectEqual(@as(usize, 0), names.len) else try std.testing.expect(names.len > 0);
        f.store = try Store.open(a, f.path, .{});
        try std.testing.expectEqual(@as(u64, 1), f.store.sequence);
        try std.testing.expectEqual(@as(u64, 99), try format.decodeGlobal(f.store.global));
    };
}

test "creation preserves orphaned persistence artifacts and accepts an empty precreated directory" {
    const a = std.testing.allocator;
    const descriptor = try format.encodeDescriptor(a, .{ .dimensions = .{ 4, 4, 4 }, .generator_id = 2, .seed = 0, .settings = &format.flat_settings });
    defer a.free(descriptor);
    const global = format.encodeGlobal(0);
    for ([_]?[:0]const u8{ null, "world.base", "orphan.wal", "initial.tmp", "initial-chunks.tmp", "compact.tmp", "segment.pending" }) |artifact| {
        var uuid: Uuid = undefined;
        std.c.arc4random_buf(&uuid, uuid.len);
        const path = try std.fmt.allocPrintSentinel(a, "/private/tmp/zig-persistence-create-evidence-{x}", .{uuid}, 0);
        defer a.free(path);
        defer std.Io.Dir.cwd().deleteTree(std.testing.io, path) catch {};
        try io.makeDirectory(path);
        const evidence = "incomplete previous world: preserve these exact bytes";
        {
            const dir = try io.Directory.open(path);
            defer dir.close();
            if (artifact) |name| {
                const file = try dir.file(name, true);
                defer file.close();
                try file.write(evidence, 0);
                try file.sync();
                try dir.sync(file);
            }
        }
        const initial: Initial = .{ .world_uuid = uuid, .descriptor = descriptor, .global = &global, .players = &.{}, .player_count = 0 };
        if (artifact) |name| {
            if (Store.create(a, path, initial, .{})) |unexpected_store| {
                var unexpected = unexpected_store;
                unexpected.deinit();
                return error.ExpectedExistingEvidenceRejection;
            } else |err| try std.testing.expectEqual(error.AlreadyExists, err);
            const dir = try io.Directory.open(path);
            defer dir.close();
            const file = try dir.file(name, false);
            defer file.close();
            var restored: [evidence.len]u8 = undefined;
            try file.read(&restored, 0);
            try std.testing.expectEqualSlices(u8, evidence, &restored);
            try std.testing.expectEqual(@as(u64, evidence.len), try file.size());
            if (!std.mem.eql(u8, name, "world.base")) try std.testing.expect(!dir.exists("world.base"));
        } else {
            var store = try Store.create(a, path, initial, .{});
            defer store.deinit();
            try std.testing.expectEqual(@as(u64, 0), store.sequence);
        }
    }
}

test "fresh nested save path through a parent alias creates parents and preserves world identity" {
    const a = std.testing.allocator;
    var uuid: Uuid = undefined;
    std.c.arc4random_buf(&uuid, uuid.len);
    const root = try std.fmt.allocPrintSentinel(a, "/private/tmp/zig-persistence-nested-{x}", .{uuid}, 0);
    defer a.free(root);
    defer std.Io.Dir.cwd().deleteTree(std.testing.io, root) catch {};
    // macOS /tmp is a symlink to /private/tmp. Existing ancestor aliases
    // retain ordinary path semantics; only the world leaf rejects symlinks.
    const path = try std.fmt.allocPrintSentinel(a, "/tmp/zig-persistence-nested-{x}/saves/default", .{uuid}, 0);
    defer a.free(path);
    const descriptor = try format.encodeDescriptor(a, .{ .dimensions = .{ 4, 4, 4 }, .generator_id = 2, .seed = 0, .settings = &format.flat_settings });
    defer a.free(descriptor);
    const global = format.encodeGlobal(17);
    const initial: Initial = .{ .world_uuid = uuid, .descriptor = descriptor, .global = &global, .players = &.{}, .player_count = 0 };
    var trace: io.Faults = .{ .enabled = false };
    var store = try Store.createWithFaults(a, path, initial, .{}, &trace);
    store.setFaults(null);
    store.deinit();
    var created: usize = 0;
    var between_flushes: usize = 0;
    var max_directory_chain: usize = 0;
    for (trace.trace[0..trace.trace_len]) |operation| switch (operation) {
        .make_directory => created += 1,
        .directory_sync => between_flushes += 1,
        .full_sync => {
            max_directory_chain = @max(max_directory_chain, between_flushes);
            between_flushes = 0;
        },
        else => {},
    };
    try std.testing.expectEqual(@as(usize, 3), created);
    // New root/saves/default plus the existing parent must precede full flush.
    try std.testing.expect(max_directory_chain >= 4);
    try std.testing.expectError(error.AlreadyExists, Store.create(a, path, initial, .{}));
    var reopened = try Store.open(a, path, .{});
    defer reopened.deinit();
    try std.testing.expectEqualSlices(u8, &uuid, &reopened.world_uuid);
    try std.testing.expectEqual(@as(u64, 17), try format.decodeGlobal(reopened.global));
}

test "nested creation propagates mkdir namespace and fullflush failures without overwriting evidence" {
    const a = std.testing.allocator;
    const descriptor = try format.encodeDescriptor(a, .{ .dimensions = .{ 4, 4, 4 }, .generator_id = 2, .seed = 0, .settings = &format.flat_settings });
    defer a.free(descriptor);
    const global = format.encodeGlobal(0);
    const Failure = struct { operation: io.Operation, after: usize };
    // directory_sync0 is base installation, subsequent ones are bottom-up
    // ancestor barriers; full_sync2 is the flush after that complete chain.
    for ([_]Failure{ .{ .operation = .make_directory, .after = 1 }, .{ .operation = .directory_sync, .after = 2 }, .{ .operation = .full_sync, .after = 2 } }) |failure| {
        var uuid: Uuid = undefined;
        std.c.arc4random_buf(&uuid, uuid.len);
        const root = try std.fmt.allocPrintSentinel(a, "/private/tmp/zig-persistence-nested-fault-{x}", .{uuid}, 0);
        defer a.free(root);
        defer std.Io.Dir.cwd().deleteTree(std.testing.io, root) catch {};
        const path = try std.fmt.allocPrintSentinel(a, "{s}/saves/default", .{root}, 0);
        defer a.free(path);
        const initial: Initial = .{ .world_uuid = uuid, .descriptor = descriptor, .global = &global, .players = &.{}, .player_count = 0 };
        var fault: io.Faults = .{ .operation = failure.operation, .after = failure.after };
        try std.testing.expectError(error.Io, Store.createWithFaults(a, path, initial, .{}, &fault));
        if (failure.operation == .make_directory) {
            // The first parent remains. A retry must persist it too, even though
            // it now exists, and may create only the remaining two directories.
            var trace: io.Faults = .{ .enabled = false };
            var retry = try Store.createWithFaults(a, path, initial, .{}, &trace);
            retry.setFaults(null);
            retry.deinit();
            var created: usize = 0;
            for (trace.trace[0..trace.trace_len]) |op| if (op == .make_directory) {
                created += 1;
            };
            try std.testing.expectEqual(@as(usize, 2), created);
        } else {
            // A failed durability barrier cannot report successful creation or
            // establish a WAL; its installed base remains recovery evidence.
            const before = read_before: {
                const dir = try io.Directory.open(path);
                defer dir.close();
                const names = try dir.names(a, 128);
                defer a.free(names);
                for (names) |name| a.free(name);
                try std.testing.expectEqual(@as(usize, 0), names.len);
                const base = try dir.file("world.base", false);
                defer base.close();
                break :read_before try readAlloc(a, base, 0, try base.size());
            };
            defer a.free(before);
            try std.testing.expectError(error.AlreadyExists, Store.create(a, path, initial, .{}));
            const dir = try io.Directory.open(path);
            defer dir.close();
            const base = try dir.file("world.base", false);
            defer base.close();
            const after = try readAlloc(a, base, 0, try base.size());
            defer a.free(after);
            try std.testing.expectEqualSlices(u8, before, after);
        }
    }
}

test "legacy v1 snapshot zero and WAL migrate to persistent one-slot inventory" {
    const a = std.testing.allocator;
    var model = io.Model.init(a);
    defer model.deinit();
    io.test_model = &model;
    defer io.test_model = null;
    var f = try Fixture.init();
    defer f.deinit();
    // Construct the exact v1 player record and snapshot-zero identity. Empty v1
    // journals are retained to exercise mixed-version recovery and compaction.
    const current = try format.encodePlayer(.{ .id = 1, .feet = .{ 1, 2, 3 }, .yaw = 0, .pitch = 0 });
    var legacy = current[0..52].*;
    put(u32, &legacy, 0, 52);
    put(u16, &legacy, 46, 0);
    put(u32, &legacy, 48, 0);
    a.free(f.store.players);
    f.store.players = try a.dupe(u8, &legacy);
    f.store.player_count = 1;
    f.store.base_format_version = 1;
    var anchor = hasher("ZGW-INIT-1\x00");
    anchor.update(&f.store.world_uuid);
    hashInt(&anchor, u32, 1);
    hashInt(&anchor, u64, 0);
    hashInt(&anchor, u32, @intCast(f.store.descriptor.len));
    anchor.update(f.store.descriptor);
    hashInt(&anchor, u32, @intCast(f.store.global.len));
    anchor.update(f.store.global);
    hashInt(&anchor, u64, 1);
    hashInt(&anchor, u64, legacy.len);
    anchor.update(&legacy);
    hashInt(&anchor, u64, 0);
    anchor.final(&f.store.digest);
    try f.store.writeBase(f.store.base);
    try f.store.base.sync();
    for (f.store.segments.items) |*segment| {
        put(u32, &segment.header, 8, 1);
        @memcpy(segment.header[56..88], &f.store.digest);
        var header_hash = hasher("ZGW-WALHDR-1\x00");
        header_hash.update(segment.header[0..88]);
        header_hash.final(segment.header[88..120]);
        try segment.file.write(&segment.header, 0);
        try segment.file.sync();
    }
    f.store.deinit();
    f.store = try Store.open(a, f.path, .{});
    try std.testing.expectEqual(null, (try format.decodePlayer(f.store.players)).inventory);
    // Reopening must also validate the old snapshot-zero anchor after compaction.
    f.store.deinit();
    f.store = try Store.open(a, f.path, .{});
    const carried = try format.encodePlayer(.{ .id = 1, .feet = .{ 1, 2, 3 }, .yaw = 0, .pitch = 0, .inventory = 8 });
    const tick = format.encodeGlobal(1);
    try f.store.beginSnapshot(1, &tick, &carried, 1, 0);
    _ = try f.store.commitSnapshot();
    f.store.deinit();
    f.store = try Store.open(a, f.path, .{});
    try std.testing.expectEqual(@as(?u8, 8), (try format.decodePlayer(f.store.players)).inventory);
    try std.testing.expectEqual(@as(u64, 1), f.store.sequence);
}
