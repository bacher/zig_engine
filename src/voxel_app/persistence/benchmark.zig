//! Repeatable CPU reference workload through the production capture encoder,
//! bounded output queue, durable WAL, and compactor. No window/GPU required.
//! This does not measure frame latency or replace service policy/fault tests.
const std = @import("std");
const format = @import("format.zig");
const storage = @import("storage.zig");
const coordinator = @import("coordinator.zig");
const c = @cImport({
    @cInclude("sys/resource.h");
});
pub const Workload = enum { terrain, raw, heavy };
pub const Config = struct {
    path: [:0]const u8,
    active: usize = 10000,
    dirty: usize = 2000,
    cycles: usize = 3,
    output_bytes: usize = 8 * 1024 * 1024,
    memory_budget: usize = 1024 * 1024 * 1024,
    capture_working_bytes: ?usize = null,
    seed: u64 = 1,
    workload: Workload = .raw,
    compact_every: usize = 2,
    write_stall_ns: u64 = 0,
    sync_stall_ns: u64 = 0,
};
pub const Cycle = struct {
    baseline_update_ns: u64,
    update_ns: u64,
    capture_setup_ns: u64,
    source_release_ns: u64,
    durable_ack_ns: u64,
    total_ns: u64,
    durable_boundary_age_ns: u64,
    output_peak_bytes: usize,
    source_bytes: usize,
    base_bytes: u64,
    rss_peak_bytes: u64,
    sequence: u64,
    write_calls: usize,
    sync_calls: usize,
    injected_stall_ns: u64,
    encode_active_ns: u64,
    output_wait_ns: u64,
    encoded_bytes: usize,
    write_ns: u64,
    commit_ns: u64,
    working_reserved_bytes: usize,
};
pub const Report = struct {
    config: Config,
    cycles: []Cycle,
    recovery_ns: u64,
    oracle_chunks: usize,
    release_p50_ns: u64,
    release_p95_ns: u64,
    release_p99_ns: u64,
    release_max_ns: u64,
    ack_p95_ns: u64,
    ack_p99_ns: u64,
    total_p95_ns: u64,
    total_p99_ns: u64,
    pub fn deinit(self: *Report, a: std.mem.Allocator) void {
        a.free(self.cycles);
        self.* = undefined;
    }
    pub fn print(self: Report) void {
        std.debug.print("{{\"schema\":2,\"runner\":\"production-coordinator\",\"active\":{d},\"dirty\":{d},\"seed\":{d},\"workload\":\"{s}\",\"output_budget\":{d},\"working_budget\":{d},\"capture_working_budget\":{d},\"warmup_cycles\":0,\"stall_scope\":\"transaction-only; missing segments established before capture\",\"write_stall_ns\":{d},\"sync_stall_ns\":{d},\"cycles\":[", .{ self.config.active, self.config.dirty, self.config.seed, @tagName(self.config.workload), self.config.output_bytes, self.config.memory_budget, captureWorkingBudget(self.config), self.config.write_stall_ns, self.config.sync_stall_ns });
        for (self.cycles, 0..) |v, i| {
            if (i > 0) std.debug.print(",", .{});
            std.debug.print("{{\"sequence\":{d},\"baseline_update_ns\":{d},\"update_ns\":{d},\"capture_setup_ns\":{d},\"source_release_ns\":{d},\"durable_ack_ns\":{d},\"total_ns\":{d},\"durable_boundary_age_ns\":{d},\"output_peak_bytes\":{d},\"source_bytes\":{d},\"base_bytes\":{d},\"rss_peak_bytes\":{d},\"write_calls\":{d},\"sync_calls\":{d},\"injected_stall_ns\":{d},\"encode_active_ns\":{d},\"output_wait_ns\":{d},\"encoded_bytes\":{d},\"write_ns\":{d},\"commit_ns\":{d},\"working_reserved_bytes\":{d}}}", .{ v.sequence, v.baseline_update_ns, v.update_ns, v.capture_setup_ns, v.source_release_ns, v.durable_ack_ns, v.total_ns, v.durable_boundary_age_ns, v.output_peak_bytes, v.source_bytes, v.base_bytes, v.rss_peak_bytes, v.write_calls, v.sync_calls, v.injected_stall_ns, v.encode_active_ns, v.output_wait_ns, v.encoded_bytes, v.write_ns, v.commit_ns, v.working_reserved_bytes });
        }
        std.debug.print("],\"summary\":{{\"source_release_p50_ns\":{d},\"source_release_p95_ns\":{d},\"source_release_p99_ns\":{d},\"source_release_max_ns\":{d},\"durable_ack_p95_ns\":{d},\"durable_ack_p99_ns\":{d},\"total_p95_ns\":{d},\"total_p99_ns\":{d},\"recovery_ns\":{d},\"oracle_chunks\":{d},\"oracle_passed\":true}}}}\n", .{ self.release_p50_ns, self.release_p95_ns, self.release_p99_ns, self.release_max_ns, self.ack_p95_ns, self.ack_p99_ns, self.total_p95_ns, self.total_p99_ns, self.recovery_ns, self.oracle_chunks });
    }
};
/// One independent stall at the first WAL write and commit flush of each cycle.
/// These deliberately block writer I/O, allowing the encoder queue to fill normally.
const Delays = struct {
    io: std.Io,
    write_ns: u64,
    sync_ns: u64,
    writes: usize = 0,
    syncs: usize = 0,
    elapsed_ns: u64 = 0,
    fn hook(context: ?*anyopaque, operation: storage.io.Operation) void {
        const self: *Delays = @ptrCast(@alignCast(context.?));
        var delay: u64 = 0;
        switch (operation) {
            .write => {
                if (self.writes == 0) delay = self.write_ns;
                self.writes += 1;
            },
            .full_sync => {
                if (self.syncs == 0) delay = self.sync_ns;
                self.syncs += 1;
            },
            else => {},
        }
        if (delay > 0) {
            const start = coordinator.now(self.io);
            std.Io.sleep(self.io, .fromNanoseconds(delay), .awake) catch {};
            self.elapsed_ns += duration(start, coordinator.now(self.io));
        }
    }
};
fn percentile(a: std.mem.Allocator, cycles: []const Cycle, comptime field: []const u8, percent: usize) !u64 {
    const values = try a.alloc(u64, cycles.len);
    defer a.free(values);
    for (cycles, values) |cycle, *value| value.* = @field(cycle, field);
    std.mem.sort(u64, values, {}, std.sort.asc(u64));
    return values[@min(values.len - 1, (values.len * percent + 99) / 100 - 1)];
}
const Observations = struct {
    io: std.Io,
    mutex: std.Io.Mutex = .init,
    release: i96 = 0,
    released_count: usize = 0,
    committed: i96 = 0,
    failure: ?anyerror = null,
    fn receive(context: *anyopaque, event: coordinator.Event) void {
        const self: *Observations = @ptrCast(@alignCast(context));
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        switch (event) {
            .released => |released| {
                // Sources are encoded in ascending ID order and released exactly once.
                std.debug.assert(released.id == self.released_count);
                self.released_count += 1;
                self.release = coordinator.now(self.io);
            },
            .encoded => if (self.release == 0) {
                self.release = coordinator.now(self.io);
            },
            .committed => self.committed = coordinator.now(self.io),
            .finished => |f| self.failure = f.failure,
            else => {},
        }
    }
};
fn duration(start: i96, end: i96) u64 {
    return @intCast(@max(0, end - start));
}
fn rss() u64 {
    var usage: c.struct_rusage = undefined;
    if (c.getrusage(c.RUSAGE_SELF, &usage) != 0) return 0;
    return @intCast(usage.ru_maxrss);
}
fn update(blocks: [][32768]u8, dirty: usize, cycle: usize, workload: Workload) u64 {
    var checksum: u64 = 0;
    for (blocks[0..dirty], 0..) |*chunk, index| {
        const slot = (index * 97 + cycle * 31) % 32768;
        if (workload != .heavy) chunk[slot] = @intCast((index + cycle) % 12 + 1);
        checksum +%= chunk[slot];
    }
    return checksum;
}
fn captureWorkingBudget(config: Config) usize {
    return config.capture_working_bytes orelse (config.memory_budget - config.active * 32768);
}

pub fn validateConfig(config: Config) !void {
    if (config.active == 0 or config.dirty > config.active or config.cycles == 0 or config.cycles > 10000 or config.active > 1024 * 1024 or config.output_bytes < format.max_chunk_record_bytes or config.compact_every == 0) return error.InvalidBenchmarkConfig;
    const live = try std.math.mul(usize, config.active, 32768);
    const manifest = try std.math.mul(usize, config.dirty, @sizeOf(coordinator.Source));
    const minimum = try std.math.add(usize, try std.math.add(usize, live, config.output_bytes), try std.math.add(usize, manifest, 16 * 1024 * 1024));
    if (minimum > config.memory_budget) return error.WorkingBudgetTooSmall;
    if (config.capture_working_bytes) |capture| {
        if (capture == 0 or try std.math.add(usize, live, capture) > config.memory_budget) return error.WorkingBudgetTooSmall;
    }
}
pub fn run(a: std.mem.Allocator, io: std.Io, config: Config) !Report {
    try validateConfig(config);
    const blocks = try a.alloc([32768]u8, config.active);
    defer a.free(blocks);
    var random = std.Random.DefaultPrng.init(config.seed);
    for (blocks) |*chunk| {
        switch (config.workload) {
            .raw => for (chunk) |*cell| {
                cell.* = random.random().intRangeAtMost(u8, 1, 13);
            },
            .terrain => {
                @memset(chunk[0..16384], 1);
                @memset(chunk[16384..16416], 3);
                @memset(chunk[16416..], 0);
            },
            .heavy => @memset(chunk, 255),
        }
    }
    // Heavy metadata is shared immutable input, as normal resident capture sources are.
    const Road = @import("../road_data.zig").Road;
    const transformations = @import("../block_transformations.zig");
    const roads = try a.alloc(Road, if (config.workload == .heavy) 32768 else 0);
    defer a.free(roads);
    const construction = try a.alloc(transformations.BlockIndex, roads.len);
    defer a.free(construction);
    const events = try a.alloc(transformations.Event, roads.len);
    defer a.free(events);
    for (roads, 0..) |*road, i| {
        road.* = .{ .index = @intCast(i), .slope = .{ .high_endpoint = .{ 0, 0, 0 }, .downhill = .positive_x, .length = 32768, .section = @intCast(i) } };
        construction[i] = @intCast(i);
        events[i] = .{ .block = @intCast(i), .kind = .grow_grass, .due_tick = 999999 };
    }
    const descriptor = try format.encodeDescriptor(a, .{ .dimensions = .{ 512, 256, 8 }, .generator_id = 0, .seed = 0, .settings = &.{} });
    defer a.free(descriptor);
    var uuid: [16]u8 = undefined;
    std.c.arc4random_buf(&uuid, 16);
    const global = format.encodeGlobal(0);
    var store = try storage.Store.create(a, config.path, .{ .world_uuid = uuid, .descriptor = descriptor, .global = &global, .players = &.{}, .player_count = 0 }, .{});
    var owns_store = true;
    defer if (owns_store) store.deinit();
    const cycles = try a.alloc(Cycle, config.cycles);
    errdefer a.free(cycles);
    var store_mutex: std.Io.Mutex = .init;
    for (cycles, 0..) |*result, cycle| {
        // Delay experiments target transaction writes/commit synchronization,
        // independently of creation/rotation header establishment.
        if ((config.write_stall_ns > 0 or config.sync_stall_ns > 0) and store.active == null) try store.rotate();
        const baseline_start = coordinator.now(io);
        const baseline_checksum = update(blocks, config.dirty, cycle, config.workload);
        std.mem.doNotOptimizeAway(baseline_checksum);
        const baseline_end = coordinator.now(io);
        const update_start = coordinator.now(io);
        const checksum = update(blocks, config.dirty, cycle, config.workload);
        std.mem.doNotOptimizeAway(checksum);
        const capture_start = coordinator.now(io);
        const job = try a.create(coordinator.Job);
        var owns_job = true;
        errdefer if (owns_job) a.destroy(job);
        const sources = try a.alloc(coordinator.Source, config.dirty);
        var owns_sources = true;
        errdefer if (owns_sources) a.free(sources);
        for (sources, 0..) |*source, i| source.* = .{ .id = @intCast(i), .revision = cycle + 1, .epoch = cycle + 1, .is_unreachable = false, .blocks = &blocks[i], .roads = roads, .constructed = construction, .events = events };
        var source_bytes: usize = 0;
        for (sources) |source| source_bytes = try std.math.add(usize, source_bytes, source.pinnedBytes());
        var observation: Observations = .{ .io = io };
        const players = try a.alloc(u8, 0);
        var owns_players = true;
        errdefer if (owns_players) a.free(players);
        job.* = .{ .allocator = a, .io = io, .store = &store, .store_mutex = &store_mutex, .limits = .{ .output_bytes = config.output_bytes, .working_bytes = captureWorkingBudget(config) }, .notify = .{ .context = &observation, .send = Observations.receive }, .epoch = cycle + 1, .sequence = cycle + 1, .tick = (cycle + 1) * 3600, .final = (cycle + 1) % config.compact_every == 0, .sources = sources, .players = players, .player_count = 0 };
        const setup_end = coordinator.now(io);
        var delays: Delays = .{ .io = io, .write_ns = config.write_stall_ns, .sync_ns = config.sync_stall_ns };
        var faults: storage.io.Faults = .{ .enabled = false, .hook = Delays.hook, .context = &delays };
        store.setFaults(&faults);
        try job.start();
        owns_job = false;
        owns_sources = false;
        owns_players = false;
        job.writer.await(io);
        job.encoder.await(io);
        const peak = job.peak_bytes;
        const encode_active_ns = job.encode_active_ns;
        const output_wait_ns = job.output_wait_ns;
        const encoded_bytes = job.encoded_bytes;
        const write_ns = job.write_ns;
        const commit_ns = job.commit_ns;
        const working_reserved_bytes = job.working_reserved_bytes;
        job.deinit();
        store.setFaults(null);
        const end = coordinator.now(io);
        if (observation.failure) |failure| return failure;
        if (store.sequence != cycle + 1 or observation.committed == 0 or observation.release == 0) return error.BenchmarkIncomplete;
        result.* = .{ .baseline_update_ns = duration(baseline_start, baseline_end), .update_ns = duration(update_start, capture_start), .capture_setup_ns = duration(capture_start, setup_end), .source_release_ns = duration(capture_start, observation.release), .durable_ack_ns = duration(capture_start, observation.committed), .total_ns = duration(capture_start, end), .durable_boundary_age_ns = duration(capture_start, observation.committed), .output_peak_bytes = peak, .source_bytes = source_bytes, .base_bytes = try store.base.size(), .rss_peak_bytes = rss(), .sequence = store.sequence, .write_calls = delays.writes, .sync_calls = delays.syncs, .injected_stall_ns = delays.elapsed_ns, .encode_active_ns = encode_active_ns, .output_wait_ns = output_wait_ns, .encoded_bytes = encoded_bytes, .write_ns = write_ns, .commit_ns = commit_ns, .working_reserved_bytes = working_reserved_bytes };
        if (peak > config.output_bytes) return error.OutputBudgetExceeded;
    }
    // Startup follows production recovery (including WAL-only last cycles), then
    // compare against independently retained logical source arrays, not sequence alone.
    store.deinit();
    owns_store = false;
    const recovery_start = coordinator.now(io);
    store = try storage.Store.open(a, config.path, .{});
    owns_store = true;
    const recovery_ns = duration(recovery_start, coordinator.now(io));
    if (store.sequence != config.cycles or try format.decodeGlobal(store.global) != config.cycles * 3600 or store.player_count != 0) return error.OracleMismatch;
    for (0..config.dirty) |i| {
        const encoded = (try store.readChunk(a, @intCast(i))) orelse return error.OracleMismatch;
        defer a.free(encoded);
        var decoded = try format.decodeChunk(a, store.world_uuid, encoded, store.dimensions);
        defer decoded.deinit(a);
        if (decoded.revision != config.cycles or decoded.is_unreachable or !std.mem.eql(u8, decoded.blocks, &blocks[i])) return error.OracleMismatch;
        if (config.workload == .heavy) {
            var meta = try format.decodeMetadata(a, decoded.blocks, decoded.metadata, store.dimensions);
            defer meta.deinit(a);
            if (meta.roads.len != 32768 or meta.construction.len != 32768 or meta.timers.len != 32768) return error.OracleMismatch;
            for (0..32768) |cell| {
                const formation = meta.roads[cell].formation orelse return error.OracleMismatch;
                if (formation.section != cell or formation.length != 32768 or formation.direction != 0 or !std.mem.eql(u32, &formation.high_endpoint, &.{ 0, 0, 0 }) or meta.construction[cell] != cell or meta.timers[cell].cell != cell or meta.timers[cell].kind != 1 or meta.timers[cell].deadline != 999999) return error.OracleMismatch;
            }
        } else if (decoded.metadata.len != 0) return error.OracleMismatch;
    }
    return .{ .config = config, .cycles = cycles, .recovery_ns = recovery_ns, .oracle_chunks = config.dirty, .release_p50_ns = try percentile(a, cycles, "source_release_ns", 50), .release_p95_ns = try percentile(a, cycles, "source_release_ns", 95), .release_p99_ns = try percentile(a, cycles, "source_release_ns", 99), .release_max_ns = try percentile(a, cycles, "source_release_ns", 100), .ack_p95_ns = try percentile(a, cycles, "durable_ack_ns", 95), .ack_p99_ns = try percentile(a, cycles, "durable_ack_ns", 99), .total_p95_ns = try percentile(a, cycles, "total_ns", 95), .total_p99_ns = try percentile(a, cycles, "total_ns", 99) };
}
pub fn main(init: std.process.Init) !void {
    const args = try init.minimal.args.toSlice(init.arena.allocator());
    if (args.len < 2) {
        std.debug.print("usage: persistence-benchmark NEW_SAVE_PATH [active=10000] [dirty=2000] [cycles=3] [output_MiB=8] [working_MiB=1024] [terrain|raw|heavy] [first_write_stall_ms=0] [first_sync_stall_ms=0] [capture_working_MiB=workspace_minus_resident]\n", .{});
        return error.MissingSavePath;
    }
    var config: Config = .{ .path = args[1] };
    if (args.len > 2) config.active = try std.fmt.parseInt(usize, args[2], 10);
    if (args.len > 3) config.dirty = try std.fmt.parseInt(usize, args[3], 10);
    if (args.len > 4) config.cycles = try std.fmt.parseInt(usize, args[4], 10);
    if (args.len > 5) config.output_bytes = try std.math.mul(usize, try std.fmt.parseInt(usize, args[5], 10), 1024 * 1024);
    if (args.len > 6) config.memory_budget = try std.math.mul(usize, try std.fmt.parseInt(usize, args[6], 10), 1024 * 1024);
    if (args.len > 7) config.workload = std.meta.stringToEnum(Workload, args[7]) orelse return error.InvalidWorkload;
    if (args.len > 8) config.write_stall_ns = try std.math.mul(u64, try std.fmt.parseInt(u64, args[8], 10), std.time.ns_per_ms);
    if (args.len > 9) config.sync_stall_ns = try std.math.mul(u64, try std.fmt.parseInt(u64, args[9], 10), std.time.ns_per_ms);
    if (args.len > 10) config.capture_working_bytes = try std.math.mul(usize, try std.fmt.parseInt(usize, args[10], 10), 1024 * 1024);
    var report = try run(init.gpa, init.io, config);
    defer report.deinit(init.gpa);
    report.print();
}
test "benchmark refuses insufficient workspace before allocating active world" {
    try std.testing.expectError(error.WorkingBudgetTooSmall, validateConfig(.{ .path = "unused", .memory_budget = 1024 }));
    try std.testing.expectError(error.InvalidBenchmarkConfig, validateConfig(.{ .path = "unused", .dirty = 10001 }));
    try validateConfig(.{ .path = "unused", .capture_working_bytes = 16 * 1024 * 1024 });
    try std.testing.expectError(error.WorkingBudgetTooSmall, validateConfig(.{ .path = "unused", .capture_working_bytes = 1024 * 1024 * 1024 }));
    try validateConfig(.{ .path = "unused", .active = 4000, .dirty = 1000, .output_bytes = 64 * 1024 * 1024, .memory_budget = 512 * 1024 * 1024 });
}
