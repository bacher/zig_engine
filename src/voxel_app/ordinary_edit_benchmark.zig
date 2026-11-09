//! Detached ordinary edit validation beside a distant pending blueprint.
//! Called by `zig build bench-placement -Doptimize=ReleaseFast`.
const std = @import("std");
const engine = @import("engine");
const world = @import("world.zig");
const rules = world.block_rules;
const runtime = world.blueprint_runtime;
const BlockType = engine.voxel_chunk.BlockType;

const Fixture = struct {
    reads: usize = 0,

    fn read(context: *anyopaque, cell: [3]u32) ?BlockType {
        const self: *Fixture = @ptrCast(@alignCast(context));
        self.reads += 1;
        if (cell[0] >= 9 and cell[0] < 12 and cell[1] >= 9 and cell[1] < 12 and cell[2] >= 6 and cell[2] < 9) return .stone;
        if (cell[0] == 10 and cell[1] == 10 and cell[2] >= 9 and cell[2] < 13) return .planks;
        if (cell[0] == 11 and cell[1] == 10 and cell[2] == 11) return .planks;
        return .none;
    }
};

const ValidationPath = enum { physical, no_site, distant_site };
const ValidationCase = struct {
    label: []const u8,
    operation: world.BlockOperation,
    status: world.OperationStatus,
};
const cases = [_]ValidationCase{
    .{ .label = "put plank", .operation = .{ .block = .{ 11, 10, 10 }, .action = .{ .put = .planks } }, .status = .success },
    .{ .label = "remove foundation plank", .operation = .{ .block = .{ 10, 10, 9 }, .action = .remove }, .status = .constraint_violation },
    .{ .label = "remove leaf plank", .operation = .{ .block = .{ 11, 10, 11 }, .action = .remove }, .status = .success },
    .{ .label = "already exists", .operation = .{ .block = .{ 10, 10, 9 }, .action = .{ .put = .planks } }, .status = .already_exists },
};
const constructed = [_]rules.Cell{ .{ 10, 10, 9 }, .{ 10, 10, 10 }, .{ 10, 10, 11 }, .{ 11, 10, 11 }, .{ 10, 10, 12 } };

fn validate(validation_path: ValidationPath, allocator: std.mem.Allocator, reader: rules.Reader, empty_state: *const runtime.State, distant_state: *const runtime.State, operation: world.BlockOperation) world.EditResult {
    return switch (validation_path) {
        .physical => world.validateEdit(allocator, reader, &constructed, operation),
        .no_site => world.validateCompletedEdit(allocator, reader, empty_state, &constructed, operation),
        .distant_site => world.validateCompletedEdit(allocator, reader, distant_state, &constructed, operation),
    };
}

fn insertDistantDefinition(allocator: std.mem.Allocator, state: *runtime.State) !void {
    const name = try allocator.dupe(u8, "Distant");
    errdefer allocator.free(name);
    const cells = try allocator.dupe(BlockType, &.{.planks});
    errdefer allocator.free(cells);
    // State takes ownership only after successful insertion. End this scope
    // before further fallible setup so error defers cannot free owned payloads.
    try state.insertDefinition(allocator, .{
        .id = 1,
        .owner = 1,
        .name = name,
        .definition = .{ .size = .{ 1, 1, 1 }, .cells = cells, .target_count = 1 },
    });
}

pub fn run(init: std.process.Init) !void {
    const allocator = init.gpa;
    const layout = try engine.WorldLayout.init(.{ .size_in_chunks = .{ 8, 8, 8 } });
    var fixture: Fixture = .{};
    const reader: rules.Reader = .{ .layout = &layout, .context = &fixture, .block_at = Fixture.read };
    var empty_state: runtime.State = .{};
    defer empty_state.deinit(allocator);
    var distant_state: runtime.State = .{};
    defer distant_state.deinit(allocator);
    try insertDistantDefinition(allocator, &distant_state);
    var instance = try distant_state.prepareInstance(allocator, &layout, 1, 1, 1, .{ 160, 160, 10 }, 0);
    distant_state.insertInstance(allocator, &layout, instance) catch |err| {
        instance.deinit(allocator);
        return err;
    };

    const checks_per_sample = 1000;
    std.debug.print("build={s} samples=11 checks/sample={d}; synthetic resident reader, detached validation only\n", .{ @tagName(@import("builtin").mode), checks_per_sample });
    for (cases) |case| {
        const expected = validate(.physical, allocator, reader, &empty_state, &distant_state, case.operation);
        if (expected.status != case.status) return error.UnexpectedFixtureStatus;
        for ([_]ValidationPath{ .physical, .no_site, .distant_site }) |validation_path| {
            fixture.reads = 0;
            var counted_allocator = std.testing.FailingAllocator.init(allocator, .{});
            const actual = validate(validation_path, counted_allocator.allocator(), reader, &empty_state, &distant_state, case.operation);
            if (!std.meta.eql(expected, actual) or counted_allocator.allocated_bytes != counted_allocator.freed_bytes) return error.UnexpectedResult;
            const reads = fixture.reads;

            for (0..100) |_| {
                std.mem.doNotOptimizeAway(&fixture);
                _ = validate(validation_path, allocator, reader, &empty_state, &distant_state, case.operation);
            }
            var samples: [11]u64 = undefined;
            for (&samples) |*sample| {
                const started = std.Io.Clock.awake.now(init.io);
                for (0..checks_per_sample) |_| {
                    std.mem.doNotOptimizeAway(&fixture);
                    const result = validate(validation_path, allocator, reader, &empty_state, &distant_state, case.operation);
                    if (result.status != case.status) return error.UnexpectedTimedStatus;
                    std.mem.doNotOptimizeAway(result);
                }
                sample.* = @intCast(started.durationTo(std.Io.Clock.awake.now(init.io)).nanoseconds);
            }
            std.mem.sort(u64, &samples, {}, std.sort.asc(u64));
            std.debug.print("{s: <24} {s: <12}: reads={d: <5} allocations={d: <3} bytes={d: <7} median={d:.3} us/check min={d:.3}\n", .{
                case.label,
                @tagName(validation_path),
                reads,
                counted_allocator.allocations,
                counted_allocator.allocated_bytes,
                @as(f64, @floatFromInt(samples[samples.len / 2])) / (checks_per_sample * std.time.ns_per_us),
                @as(f64, @floatFromInt(samples[0])) / (checks_per_sample * std.time.ns_per_us),
            });
        }
    }
}
