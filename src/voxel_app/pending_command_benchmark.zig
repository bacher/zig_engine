//! Queue-only comparison using the production retained-command payload type.
//! Both containers reserve the same capacity before timing; no terrain, threads,
//! persistence I/O, or client publication runs inside these measurements.
const std = @import("std");
const Mode = enum { drain, retry, rotate };
const operations = 65_536;

const Result = struct { ns: i96, digest: u64 };

pub fn run(comptime Pending: type, default_depth: usize) !void {
    std.debug.print("retained_queue pending_bytes={d} default_depth={d} default_buffer_bytes={d} array_metadata_bytes={d} deque_metadata_bytes={d} operations={d} samples=3\n", .{ @sizeOf(Pending), default_depth, default_depth * @sizeOf(Pending), @sizeOf(std.ArrayList(Pending)), @sizeOf(std.Deque(Pending)), operations });
    for ([_]usize{ 1, 64, default_depth, 1024 }) |depth| {
        for ([_]Mode{ .drain, .retry, .rotate }) |mode| {
            for (0..3) |sample| {
                var baseline: Result = undefined;
                var deque: Result = undefined;
                // Alternate execution order to reduce consistent cache/clock bias.
                if (sample % 2 == 0) {
                    baseline = try trial(Pending, true, depth, mode);
                    deque = try trial(Pending, false, depth, mode);
                } else {
                    deque = try trial(Pending, false, depth, mode);
                    baseline = try trial(Pending, true, depth, mode);
                }
                try std.testing.expectEqual(baseline.digest, deque.digest);
                std.debug.print("retained_queue mode={s} depth={d} sample={d} array_ms={d:.3} deque_ms={d:.3} ratio={d:.2} shifted_bytes={d} digest={d}\n", .{ @tagName(mode), depth, sample + 1, milliseconds(baseline.ns), milliseconds(deque.ns), @as(f64, @floatFromInt(baseline.ns)) / @as(f64, @floatFromInt(@max(deque.ns, 1))), shiftedItems(depth, mode) * @sizeOf(Pending), deque.digest });
            }
        }
    }
}

fn trial(comptime Pending: type, comptime baseline: bool, depth: usize, mode: Mode) !Result {
    const a = std.testing.allocator;
    const Queue = if (baseline) std.ArrayList(Pending) else std.Deque(Pending);
    var queue: Queue = .empty;
    defer queue.deinit(a);
    try queue.ensureTotalCapacityPrecise(a, depth);
    const initial_buffer = if (baseline) queue.items.ptr else queue.buffer.ptr;
    if (mode == .rotate) for (0..depth) |id| append(Pending, baseline, &queue, item(Pending, id));
    var digest: u64 = 0;
    const start = std.Io.Clock.awake.now(std.testing.io).nanoseconds;
    for (0..operations / depth) |round| {
        if (mode != .rotate) for (0..depth) |id| append(Pending, baseline, &queue, item(Pending, round * depth + id));
        for (0..depth) |index| {
            var pending = pop(Pending, baseline, &queue);
            // A blocked command returns to the same FIFO head before a later wake.
            if (mode == .retry and index % 4 == 0) {
                if (baseline) queue.insertAssumeCapacity(0, pending) else queue.pushFrontAssumeCapacity(pending);
                pending = pop(Pending, baseline, &queue);
            }
            digest = std.math.rotl(u64, digest, 7) ^ pending.request.operation.request_id;
            digest +%= @intCast(pending.since);
            if (mode == .rotate) append(Pending, baseline, &queue, item(Pending, depth + round * depth + index));
        }
    }
    const elapsed = std.Io.Clock.awake.now(std.testing.io).nanoseconds - start;
    // Capacity and allocations remain unchanged even through wraparound/retries.
    try std.testing.expect(initial_buffer == (if (baseline) queue.items.ptr else queue.buffer.ptr));
    try std.testing.expectEqual(if (mode == .rotate) depth else 0, if (baseline) queue.items.len else queue.len);
    return .{ .ns = elapsed, .digest = digest };
}

fn item(comptime Pending: type, id: usize) Pending {
    return .{ .request = .{ .operation = .{ .client = undefined, .request_id = id, .operation = .{ .block = .{ 10, 10, 70 }, .action = .{ .put = .snow } } } }, .since = @intCast(id * 3) };
}

fn append(comptime Pending: type, comptime baseline: bool, queue: *(if (baseline) std.ArrayList(Pending) else std.Deque(Pending)), pending: Pending) void {
    if (baseline) queue.appendAssumeCapacity(pending) else queue.pushBackAssumeCapacity(pending);
}

fn pop(comptime Pending: type, comptime baseline: bool, queue: *(if (baseline) std.ArrayList(Pending) else std.Deque(Pending))) Pending {
    return if (baseline) queue.orderedRemove(0) else queue.popFront().?;
}

fn shiftedItems(depth: usize, mode: Mode) usize {
    if (mode == .rotate) return operations * (depth - 1);
    var per_round = depth * (depth - 1) / 2;
    if (mode == .retry) for (0..depth) |index| {
        if (index % 4 == 0) per_round += 2 * (depth - index - 1);
    };
    return per_round * (operations / depth);
}

fn milliseconds(ns: i96) f64 {
    return @as(f64, @floatFromInt(ns)) / std.time.ns_per_ms;
}
