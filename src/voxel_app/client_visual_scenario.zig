//! Opt-in real-client construction workload. Setup and fills use a separate
//! public endpoint; the game receives the normal authoritative subscriptions.
const std = @import("std");
const engine = @import("engine");
const blueprint = @import("blueprint.zig");
const service_api = @import("world_data_service.zig");
const world = @import("world.zig");
const consts = @import("consts.zig");

pub const site_count = 9;
pub const fixture_size: blueprint.Size = .{ 28, 28, 49 };
const wall_thickness = 3;
const setup_timeout_ns = 60 * std.time.ns_per_s;
const max_outstanding = 256;

pub const Status = enum { pending, submitted, accepted, rejected, submission_failed };
pub const Record = struct {
    cell: [3]u32,
    instance_id: u64,
    cell_index: u32,
    material: blueprint.BlockType,
    request_id: u64 = 0,
    scheduled_ns: u64 = 0,
    submitted_ns: u64 = 0,
    ack_ns: u64 = 0,
    status: Status = .pending,
    operation_status: ?world.OperationStatus = null,
};

pub const Counters = struct {
    scheduled: usize = 0,
    admitted: usize = 0,
    accepted: usize = 0,
    rejected: usize = 0,
    busy_events: usize = 0,
    submission_failures: usize = 0,
    planned: usize = 0,
    outstanding: usize = 0,
    /// Requested operations beyond the finite fixture are reported explicitly.
    fixture_exhausted: bool = false,
};

pub const Scenario = struct {
    allocator: std.mem.Allocator,
    package_allocator: std.mem.Allocator,
    io: std.Io,
    client: *service_api.Client,
    records: []Record,
    counters: Counters = .{},
    target_count: usize,
    anchor: [3]u32,
    center: [3]f64,
    site_origins: [site_count][3]u32,
    definition_id: u64,
    start_ns: ?u64 = null,
    rate: ?u32 = null,
    duration_ns: u64 = 0,
    first_fill_request_id: ?u64 = null,
    submission_error: ?service_api.Client.BatchSubmitError = null,
    generation_complete: bool = false,
    packages: std.ArrayList(service_api.ResponsePackage) = .empty,
    blueprint_results: std.ArrayList(service_api.BlueprintResult) = .empty,

    /// The caller supplies a fresh ephemeral flat world and keeps its service
    /// alive until after deinit. The service owns the setup endpoint's lifetime.
    pub fn init(allocator: std.mem.Allocator, io: std.Io, service: *service_api.WorldDataService, owner: u64) !Scenario {
        const origins = try fixtureOrigins(service.layout);
        const client = try service.createClient();
        var result: Scenario = .{
            .allocator = allocator,
            .package_allocator = service.allocator,
            .io = io,
            .client = client,
            .records = &.{},
            .target_count = 0,
            .anchor = origins[4],
            .center = .{
                @as(f64, @floatFromInt(origins[4][0])) + @as(f64, fixture_size[0]) / 2,
                @as(f64, @floatFromInt(origins[4][1])) + @as(f64, fixture_size[1]) / 2,
                @as(f64, @floatFromInt(origins[4][2])) + @as(f64, fixture_size[2]) / 2,
            },
            .site_origins = origins,
            .definition_id = 0,
        };
        errdefer result.deinit();
        client.publishCheckpoint(.{
            .id = owner,
            .feet = .{ @as(f64, @floatFromInt(result.anchor[0])) + 0.5, @as(f64, @floatFromInt(result.anchor[1])) + 0.5, @floatFromInt(result.anchor[2]) },
            .yaw = 0,
            .pitch = 0,
        });
        const deadline = monotonicNs(io) +| setup_timeout_ns;
        const cells = try makeFixture(allocator);
        defer allocator.free(cells);
        // Successful Save transfers this allocation to the service, so compile
        // with its allocator even when the record allocator differs.
        var cancel = std.atomic.Value(bool).init(false);
        var compile_timeout = try io.concurrent(cancelCompilation, .{ io, &cancel, deadline });
        defer compile_timeout.cancel(io);
        const compiled = try blueprint.compile(service.allocator, .{ .size = fixture_size, .cells = cells }, .{ .horizontal_limit = blueprint.horizontalLimit(service.layout), .cancel = &cancel });
        if (compiled == .cancelled) return error.VisualFixtureSetupTimeout;
        if (compiled != .valid) return error.InvalidVisualFixture;
        var candidate = compiled.valid;
        var candidate_owned = true;
        defer if (candidate_owned) candidate.deinit(service.allocator);
        const targets_per_site = candidate.definition.target_count;
        const owned_cells = try allocator.dupe(blueprint.BlockType, candidate.definition.cells);
        defer allocator.free(owned_cells);
        const save = try client.trySaveBlueprint(owner, "Client visual benchmark", &candidate);
        candidate_owned = false;
        const saved = try result.waitBlueprint(save, deadline);
        if (saved.status != .success) return error.VisualFixtureSaveRejected;
        result.definition_id = saved.definition_id orelse return error.MissingVisualFixtureDefinition;
        var instances: [site_count]u64 = undefined;
        // Applications are deliberately serialized: each admission observes the
        // real preceding publication and the normal overlap/support checks.
        for (origins, 0..) |origin, index| {
            const request = try client.tryApplyBlueprint(owner, result.definition_id, origin, 0);
            const applied = try result.waitBlueprint(request, deadline);
            if (applied.status != .success) return error.VisualFixtureApplyRejected;
            instances[index] = applied.instance_id orelse return error.MissingVisualFixtureInstance;
        }
        result.target_count = @as(usize, targets_per_site) * site_count;
        result.records = try allocator.alloc(Record, result.target_count);
        var next: usize = 0;
        for (owned_cells, 0..) |material, cell_index| {
            if (material == .none) continue;
            const local = blueprint.cellAtIndex(fixture_size, cell_index);
            for (origins, instances) |origin, instance| {
                result.records[next] = .{
                    .cell = .{ origin[0] + local[0], origin[1] + local[1], origin[2] + local[2] },
                    .instance_id = instance,
                    .cell_index = @intCast(cell_index),
                    .material = material,
                };
                next += 1;
            }
        }
        std.debug.assert(next == result.records.len);
        return result;
    }

    pub fn deinit(self: *Scenario) void {
        for (self.packages.items) |*package| package.deinit(self.package_allocator);
        self.packages.deinit(self.package_allocator);
        self.blueprint_results.deinit(self.package_allocator);
        self.allocator.free(self.records);
        self.* = undefined;
    }

    pub fn start(self: *Scenario, now_ns: u64) void {
        std.debug.assert(self.start_ns == null);
        self.start_ns = now_ns;
    }

    /// Absolute awake-clock nanoseconds drive arrivals. Busy admission retains
    /// the due prefix for a later pump; after duration the finite backlog drains.
    /// A pump never sleeps and reserves at most max_outstanding operation slots.
    pub fn pump(self: *Scenario, now_ns: u64, rate: u32, duration_ns: u64) !void {
        try self.collect(now_ns);
        if (self.submission_error) |err| return err;
        const started = self.start_ns orelse return error.VisualScenarioNotStarted;
        if (rate == 0 or duration_ns == 0) return error.InvalidVisualScenarioRate;
        if (self.rate) |previous| {
            if (previous != rate or self.duration_ns != duration_ns) return error.VisualScenarioScheduleChanged;
        } else {
            self.rate = rate;
            self.duration_ns = duration_ns;
            const requested = operationCount(rate, duration_ns);
            self.counters.fixture_exhausted = requested > self.records.len;
            self.counters.planned = @intCast(@min(requested, self.records.len));
            for (self.records[0..self.counters.planned], 0..) |*record, index| record.scheduled_ns = started +| scheduledOffset(index, rate);
        }
        const elapsed = now_ns -| started;
        self.counters.scheduled = @intCast(@min(operationCount(rate, @min(elapsed, duration_ns)), self.counters.planned));
        self.generation_complete = elapsed >= duration_ns;
        while (self.counters.admitted < self.counters.scheduled and self.counters.outstanding < max_outstanding) {
            const first = self.counters.admitted;
            const count = @min(service_api.Client.max_operation_batch, self.counters.scheduled - first, max_outstanding - self.counters.outstanding);
            var operations: [service_api.Client.max_operation_batch]world.BlockOperation = undefined;
            for (self.records[first..][0..count], operations[0..count]) |record, *operation| operation.* = .{
                .block = record.cell,
                .action = .{ .put = record.material },
                .blueprint = .{ .instance_id = record.instance_id, .cell_index = record.cell_index },
            };
            const submitted = self.client.trySubmitOperations(operations[0..count]) catch |err| switch (err) {
                error.Busy => {
                    self.counters.busy_events += 1;
                    return;
                },
                else => {
                    for (self.records[first..][0..count]) |*record| record.status = .submission_failed;
                    self.counters.submission_failures += count;
                    self.submission_error = err;
                    return err;
                },
            };
            if (self.first_fill_request_id == null) self.first_fill_request_id = submitted.first_request_id;
            for (self.records[first..][0..count], 0..) |*record, index| {
                record.request_id = submitted.requestId(index);
                record.submitted_ns = now_ns;
                record.status = .submitted;
            }
            self.counters.admitted += count;
            self.counters.outstanding += count;
        }
    }

    /// No more arrivals remain and every scheduled intent has an authority reply.
    pub fn isComplete(self: *const Scenario) bool {
        return self.generation_complete and self.counters.admitted == self.counters.planned and self.isDrained();
    }

    pub fn isDrained(self: *const Scenario) bool {
        return self.counters.outstanding == 0;
    }

    fn collect(self: *Scenario, now_ns: u64) !void {
        self.client.takePackages(&self.packages);
        defer {
            for (self.packages.items) |*package| package.deinit(self.package_allocator);
            self.packages.clearRetainingCapacity();
        }
        for (self.packages.items) |package| for (package.responses.items) |response| if (response.operation) |operation| {
            const first = self.first_fill_request_id orelse return error.UnexpectedVisualOperationReply;
            const index = std.math.sub(u64, operation.request_id, first) catch return error.UnexpectedVisualOperationReply;
            if (index >= self.counters.admitted) return error.UnexpectedVisualOperationReply;
            const record = &self.records[@intCast(index)];
            if (record.request_id != operation.request_id or record.status != .submitted) return error.DuplicateVisualOperationReply;
            record.ack_ns = now_ns;
            record.operation_status = operation.status;
            record.status = if (operation.status == .success) .accepted else .rejected;
            if (record.status == .accepted) self.counters.accepted += 1 else self.counters.rejected += 1;
            self.counters.outstanding -= 1;
        };
    }

    fn waitBlueprint(self: *Scenario, request_id: u64, deadline_ns: u64) !service_api.BlueprintResult {
        while (monotonicNs(self.io) < deadline_ns) {
            try self.collect(monotonicNs(self.io));
            self.client.takeBlueprintResults(&self.blueprint_results);
            defer self.blueprint_results.clearRetainingCapacity();
            for (self.blueprint_results.items) |result| if (result.request_id == request_id) return result;
            try std.Io.sleep(self.io, .fromMilliseconds(1), .awake);
        }
        return error.VisualFixtureSetupTimeout;
    }
};

fn monotonicNs(io: std.Io) u64 {
    return @intCast(@max(0, std.Io.Clock.awake.now(io).nanoseconds));
}

fn cancelCompilation(io: std.Io, cancel: *std.atomic.Value(bool), deadline_ns: u64) void {
    const remaining_ms = std.math.divCeil(u64, deadline_ns -| monotonicNs(io), std.time.ns_per_ms) catch unreachable;
    std.Io.sleep(io, .fromMilliseconds(@intCast(remaining_ms)), .awake) catch return;
    cancel.store(true, .release);
}

fn operationCount(rate: u32, elapsed_ns: u64) u128 {
    return @as(u128, rate) * elapsed_ns / std.time.ns_per_s;
}

fn scheduledOffset(index: usize, rate: u32) u64 {
    // Ceil avoids admitting an event before its exact rational wall-clock time.
    return @intCast(((@as(u128, index) + 1) * std.time.ns_per_s + rate - 1) / rate);
}

fn fixtureOrigins(layout: *const engine.WorldLayout) ![site_count][3]u32 {
    if (layout.size_in_chunks[0] < 4 or layout.size_in_chunks[1] < 4 or layout.size_in_chunks[2] < 4 or @mod(layout.size_in_chunks[2], 2) != 0) return error.VisualFixtureWorldTooSmall;
    const surface: u32 = layout.size_in_blocks[2] / 2 - consts.CHUNK_SIZE / 2;
    if (surface + fixture_size[2] > layout.size_in_blocks[2]) return error.VisualFixtureWorldTooSmall;
    var result: [site_count][3]u32 = undefined;
    for (0..3) |y| for (0..3) |x| {
        result[y * 3 + x] = .{
            @as(u32, @intCast(@divTrunc(layout.size_in_chunks[0], 2) - 1)) * consts.CHUNK_SIZE + @as(u32, @intCast(x)) * consts.CHUNK_SIZE + 2,
            @as(u32, @intCast(@divTrunc(layout.size_in_chunks[1], 2) - 1)) * consts.CHUNK_SIZE + @as(u32, @intCast(y)) * consts.CHUNK_SIZE + 2,
            surface,
        };
    };
    return result;
}

fn makeFixture(allocator: std.mem.Allocator) ![]blueprint.BlockType {
    const cells = try allocator.alloc(blueprint.BlockType, fixture_size[0] * fixture_size[1] * fixture_size[2]);
    for (cells, 0..) |*material, index| {
        const local = blueprint.cellAtIndex(fixture_size, index);
        material.* = if (local[0] < wall_thickness or local[1] < wall_thickness or local[0] >= fixture_size[0] - wall_thickness or local[1] >= fixture_size[1] - wall_thickness) .rebar else .none;
    }
    return cells;
}

test "visual scenario schedule is wall-time driven and exact at boundaries" {
    try std.testing.expectEqual(@as(u128, 4096), operationCount(512, 8 * std.time.ns_per_s));
    for ([_]u32{ 1, 60, 512, 1000, 100_000 }) |rate| {
        for (0..100) |index| {
            const at = scheduledOffset(index, rate);
            try std.testing.expect(operationCount(rate, at - 1) <= index);
            try std.testing.expect(operationCount(rate, at) >= index + 1);
        }
    }
}

test "visual scenario fixture certifies without changing materials" {
    const allocator = std.testing.allocator;
    const cells = try makeFixture(allocator);
    defer allocator.free(cells);
    var result = try blueprint.compile(allocator, .{ .size = fixture_size, .cells = cells }, .{ .horizontal_limit = 255 });
    try std.testing.expect(result == .valid);
    defer result.valid.deinit(allocator);
    try std.testing.expectEqual(@as(u32, 14_700), result.valid.definition.target_count);
    try std.testing.expectEqual(@as(u32, 0), result.valid.substituted_count);
    try std.testing.expectEqualSlices(blueprint.BlockType, cells, result.valid.definition.cells);
}

test "visual scenario origins occupy exactly three by three by three chunks" {
    const layout = try engine.WorldLayout.init(.{ .size_in_chunks = .{ 16, 16, 4 } });
    const origins = try fixtureOrigins(&layout);
    try std.testing.expectEqual([3]u32{ 258, 258, 48 }, origins[4]);
    for (origins, 0..) |origin, index| {
        try std.testing.expectEqual(@as(u32, @intCast(7 + index % 3)), origin[0] / consts.CHUNK_SIZE);
        try std.testing.expectEqual(@as(u32, @intCast(7 + index / 3)), origin[1] / consts.CHUNK_SIZE);
        try std.testing.expectEqual(@as(u32, 1), origin[2] / consts.CHUNK_SIZE);
        try std.testing.expectEqual(@as(u32, 3), (origin[2] + fixture_size[2] - 1) / consts.CHUNK_SIZE);
        try std.testing.expectEqual(origin[0] / consts.CHUNK_SIZE, (origin[0] + fixture_size[0] - 1) / consts.CHUNK_SIZE);
        try std.testing.expectEqual(origin[1] / consts.CHUNK_SIZE, (origin[1] + fixture_size[1] - 1) / consts.CHUNK_SIZE);
    }
}

test "visual scenario uses public publication admission and batched fulfillment" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;
    const layout = try engine.WorldLayout.init(.{ .size_in_chunks = .{ 16, 16, 4 } });
    const service = try service_api.WorldDataService.create(io, allocator, &layout, .flat);
    defer service.destroy();
    var scenario = try Scenario.init(allocator, io, service, 1);
    defer scenario.deinit();
    try std.testing.expectEqual(@as(usize, 132_300), scenario.target_count);
    scenario.start(0);
    try scenario.pump(std.time.ns_per_s, 300, std.time.ns_per_s);
    try std.testing.expectEqual(@as(usize, max_outstanding), scenario.counters.admitted);
    try std.testing.expectEqual(@as(usize, max_outstanding), scenario.counters.outstanding);
    const deadline = monotonicNs(io) + 10 * std.time.ns_per_s;
    while (!scenario.isComplete() and monotonicNs(io) < deadline) {
        try scenario.pump(std.time.ns_per_s, 300, std.time.ns_per_s);
        try std.Io.sleep(io, .fromMilliseconds(1), .awake);
    }
    try std.testing.expect(scenario.isComplete());
    try std.testing.expectEqual(@as(usize, 300), scenario.counters.accepted);
    try std.testing.expectEqual(@as(usize, 0), scenario.counters.rejected);
    for (scenario.records[0..site_count], scenario.site_origins) |record, origin| {
        try std.testing.expectEqual(origin, record.cell);
        try std.testing.expectEqual(Status.accepted, record.status);
        try std.testing.expectEqual(world.OperationStatus.success, record.operation_status.?);
        try std.testing.expect(record.request_id != 0);
    }
}
