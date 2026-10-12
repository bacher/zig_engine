//! Run with `zig build bench-outlines -Doptimize=ReleaseFast`.
//! Measures cell classification and instance preparation, then CPU command encoding.
const std = @import("std");
const engine = @import("engine");
const outline = engine.block_outline;
const world_module = @import("world.zig");
const preview_module = @import("placement_preview.zig");
const rules = @import("block_rules.zig");
const Camera = std.meta.Child(@TypeOf(@as(engine.Scene, undefined).camera));
const frames_per_sample = 10000;

pub fn main(init: std.process.Init) !void {
    const layout = try engine.WorldLayout.init(.{ .size_in_chunks = .{ 8, 8, 8 } });
    var world = try world_module.World.init(init.gpa, &layout);
    defer world.deinit();
    try world.insertChunk(.{ 0, 0, 0 }, world_module.WorldChunk.initEmpty());
    var failure: rules.Failure = .{ .reason = .horizontal_span, .subject = .{ 8, 12, 8 }, .involved_count = 32 };
    for (&failure.involved, 0..) |*cell, index| {
        cell.* = .{ @intCast(8 + index % 8), @intCast(8 + index / 8), 8 };
        world.setBlockUnchecked(.{ @intCast(cell[0]), @intCast(cell[1]), 8 }, .rebar);
    }
    world.setBlockUnchecked(.{ 8, 12, 8 }, .rebar);
    world.pending_operations.clearRetainingCapacity();
    var camera = Camera.init(world.layout, 16.0 / 9.0);
    camera.updatePosition(.{ -117.5, -124, -117 });
    for ([_]usize{ 1, 20, 34 }) |count| {
        failure.involved_count = @intCast(if (count == 1) 0 else count - 2);
        const preview: preview_module.Preview = .{
            .block = .{ 8, 12, 9 },
            .material = .rebar,
            .result = .{ .status = .constraint_violation, .failure = failure },
        };
        var output: [outline.instance_capacity]outline.Instance = undefined;
        var samples: [11]u64 = undefined;
        for (&samples) |*sample| {
            const start = std.Io.Clock.awake.now(init.io);
            for (0..frames_per_sample) |frame| {
                // Prevent the compiler from hoisting unchanged camera/world reads.
                camera.clip_from_world_chunked[3][0] += if (frame % 2 == 0) @as(f32, 0.00001) else -0.00001;
                std.mem.doNotOptimizeAway(&world);
                std.mem.doNotOptimizeAway(&camera);
                std.mem.doNotOptimizeAway(&preview);
                if (count == 1) {
                    output[0] = outline.focusedInstance(&camera, .{ 8, 12, 8 }, .{ 1920, 1080 });
                } else {
                    const hints = preview.overlays(&world);
                    for (hints.cells[0..hints.count], 0..) |hint, index| {
                        output[index] = outline.overlayInstance(&camera, hint, .{ 1920, 1080 });
                    }
                }
                std.mem.doNotOptimizeAway(&output);
            }
            sample.* = @intCast(start.durationTo(std.Io.Clock.awake.now(init.io)).nanoseconds);
        }
        std.mem.sort(u64, &samples, {}, std.sort.asc(u64));
        std.debug.print("{d} {s}: CPU preparation median {d:.3} us/frame, min {d:.3} us/frame ({d} frames/sample, {s}; excludes GPU and command encoding)\n", .{
            count,
            if (count == 1) "focused cell" else "diagnostic cells",
            @as(f64, @floatFromInt(samples[samples.len / 2])) / (frames_per_sample * std.time.ns_per_us),
            @as(f64, @floatFromInt(samples[0])) / (frames_per_sample * std.time.ns_per_us),
            frames_per_sample,
            @tagName(@import("builtin").mode),
        });
    }
    @import("outline_submission_benchmark.zig").run(init) catch |err| switch (err) {
        error.NoGraphicsAdapter => std.debug.print("outline command encoding benchmark skipped: no graphics adapter\n", .{}),
        else => return err,
    };
}
