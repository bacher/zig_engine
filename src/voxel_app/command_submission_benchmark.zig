//! Times real endpoint admission/enqueue. The adapter runs authoritative request
//! processing, package publication, and result collection between timed windows.
const std = @import("std");
const world = @import("world.zig");
const operation_count = 131_072;
const window = 256;

const Result = struct { ns: i96, digest: u64 };

test "bounded command submission benchmark" {
    if (!@import("benchmark_options").enabled or @import("builtin").mode != .ReleaseFast) return error.SkipZigTest;
    try @import("world_data_service.zig").CommandSubmissionBenchmark.run();
}

pub fn run(comptime Adapter: type) !void {
    std.debug.print("command_submission operations={d} window={d} samples=3 producer_threads=1 worker=manual_between_timed_windows\n", .{ operation_count, window });
    for ([_]usize{ 1, 4, 16, 64 }) |batch_size| for (0..3) |sample| {
        var single: Result = undefined;
        var batch: Result = undefined;
        if (sample % 2 == 0) {
            single = try trial(Adapter, true, batch_size);
            batch = try trial(Adapter, false, batch_size);
        } else {
            batch = try trial(Adapter, false, batch_size);
            single = try trial(Adapter, true, batch_size);
        }
        try std.testing.expectEqual(single.digest, batch.digest);
        std.debug.print("command_submission batch={d} sample={d} single_ms={d:.3} batch_ms={d:.3} ratio={d:.2} single_locks_signals_reservations={d} batch_locks_signals_reservations={d} digest={d}\n", .{ batch_size, sample + 1, milliseconds(single.ns), milliseconds(batch.ns), @as(f64, @floatFromInt(single.ns)) / @as(f64, @floatFromInt(@max(batch.ns, 1))), operation_count, operation_count / batch_size, batch.digest });
    };
}

fn trial(comptime Adapter: type, comptime singles: bool, batch_size: usize) !Result {
    var fixture: Adapter.Fixture = undefined;
    try Adapter.init(&fixture, window);
    defer Adapter.deinit(&fixture);
    const client = Adapter.client(&fixture);
    const operations: [64]world.BlockOperation = @splat(.{ .block = .{ 10, 10, 255 }, .action = .remove });
    var elapsed: i96 = 0;
    var digest: u64 = 0;
    for (0..operation_count / window) |window_index| {
        const start = std.Io.Clock.awake.now(std.testing.io).nanoseconds;
        for (0..window / batch_size) |_| {
            if (singles) {
                for (operations[0..batch_size]) |operation| _ = try client.trySubmitOperation(operation);
            } else {
                _ = try client.trySubmitOperations(operations[0..batch_size]);
            }
        }
        elapsed += std.Io.Clock.awake.now(std.testing.io).nanoseconds - start;
        // Use real per-command validation, publication, and slot collection, but
        // exclude them from admission/enqueue timing. Check every result/identity.
        digest = try Adapter.finishWindow(&fixture, window_index * window + 1, window, digest);
    }
    try std.testing.expectEqual(@as(u64, operation_count + 1), client.next_request_id);
    return .{ .ns = elapsed, .digest = digest };
}

fn milliseconds(ns: i96) f64 {
    return @as(f64, @floatFromInt(ns)) / std.time.ns_per_ms;
}
