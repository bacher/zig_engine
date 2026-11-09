//! Deterministic queue-work benchmark, excluding mesh generation and GPU work.
//! Run `zig build bench-chunk-visual-queue -Doptimize=ReleaseFast`.
const std = @import("std");
const visuals = @import("chunk_visual_queue.zig");

pub const Report = struct {
    chunks: u32,
    per_frame_rebuilds: u64,
    max_frame_builds: u32,
    work_frames: u64,
    idle_head_checks: u64,
    stats: visuals.Stats,
};

/// Four edit frames contain 2,048 invalidations each, touching every chunk each
/// frame. Builds read current state; no mark payload or old revision is retained.
/// After edits stop, drain the queue and then check 1,024 idle frames.
pub fn runScenario(allocator: std.mem.Allocator, chunks: u32) !Report {
    if (chunks == 0 or chunks > 2048) return error.InvalidChunkCount;
    var queue: visuals.Queue = .{};
    defer queue.deinit(allocator);
    var frame: u64 = 0;
    var max_frame_builds: u32 = 0;
    while (frame < 4 or queue.count() != 0) : (frame += 1) {
        if (frame < 4) {
            for (0..2048) |mark| try queue.mark(allocator, @intCast(mark % chunks), 1, frame);
        }
        var budget: visuals.FrameBudget = .{};
        while (budget.canStart(0)) {
            _ = queue.take(frame) orelse break;
            budget.record();
        }
        max_frame_builds = @max(max_frame_builds, budget.completed);
        if (frame > chunks + 4) return error.QueueDidNotDrain;
    }
    const head_checks = queue.stats.head_checks;
    for (0..1024) |idle_frame| {
        if (queue.take(frame + idle_frame) != null) return error.UnexpectedIdleWork;
    }
    return .{
        .chunks = chunks,
        .per_frame_rebuilds = @as(u64, chunks) * 4,
        .max_frame_builds = max_frame_builds,
        .work_frames = frame,
        .idle_head_checks = queue.stats.head_checks - head_checks,
        .stats = queue.stats,
    };
}

pub fn main(init: std.process.Init) !void {
    for ([_]u32{ 128, 343 }) |chunks| {
        const report = try runScenario(init.gpa, chunks);
        std.debug.print("queue only: chunks={d} marks={d} per-frame-rebuilds={d} budgeted-builds={d} coalesced={d} peak-pending={d} max-builds/frame={d} work-frames={d} head-checks={d} idle-head-checks={d}\n", .{
            report.chunks,
            report.stats.marks,
            report.per_frame_rebuilds,
            report.stats.taken,
            report.stats.coalesced,
            report.stats.peak_pending,
            report.max_frame_builds,
            report.work_frames,
            report.stats.head_checks,
            report.idle_head_checks,
        });
    }
}

test "128 and 343 chunk workloads coalesce 8192 marks with bounded builds and no idle visits" {
    for ([_]u32{ 128, 343 }) |chunks| {
        const report = try runScenario(std.testing.allocator, chunks);
        try std.testing.expectEqual(@as(u64, 8192), report.stats.marks);
        try std.testing.expectEqual(@as(u64, chunks) + 12, report.stats.taken);
        try std.testing.expectEqual(report.stats.taken, report.stats.enqueued);
        try std.testing.expectEqual(report.stats.marks - report.stats.enqueued, report.stats.coalesced);
        try std.testing.expectEqual(@as(usize, chunks), report.stats.peak_pending);
        try std.testing.expectEqual(@as(u32, 4), report.max_frame_builds);
        try std.testing.expectEqual(report.stats.taken, report.stats.head_checks);
        try std.testing.expectEqual(@as(u64, 0), report.idle_head_checks);
        try std.testing.expect(report.stats.taken * 3 < report.per_frame_rebuilds);
    }
}
