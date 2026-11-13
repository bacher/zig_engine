//! Opt-in windowed-client benchmark; ordinary launches allocate no observer state.
//! Submission timestamps describe chunk representations used by a submitted frame,
//! including clipped/occluded geometry, never physical monitor presentation.
const std = @import("std");
const engine = @import("engine");
const zmath = @import("zmath");
const scenario_api = @import("client_visual_scenario.zig");
const service_api = @import("world_data_service.zig");
const queue = @import("chunk_visual_queue.zig");
const ns_s = std.time.ns_per_s;
const max_frames = 65536;
const max_events = 65536;

pub const Options = struct {
    output_prefix: []const u8,
    policy: enum { immediate, budgeted } = .budgeted,
    camera: enum { orbit, travel } = .orbit,
    rate: u32 = 512,
    duration_seconds: u32 = 8,

    pub fn parse(args: []const []const u8) !?Options {
        var enabled = false;
        for (args) |arg| if (std.mem.eql(u8, arg, "--benchmark-visuals")) {
            enabled = true;
        };
        if (!enabled) return null;
        var result: Options = .{ .output_prefix = "" };
        var seen: u8 = 0;
        var index: usize = 0;
        while (index < args.len) : (index += 2) {
            if (index + 1 == args.len) return error.MissingBenchmarkValue;
            const key = args[index];
            const value = args[index + 1];
            const bit: u3 = if (std.mem.eql(u8, key, "--benchmark-visuals")) 0 else if (std.mem.eql(u8, key, "--visual-policy")) 1 else if (std.mem.eql(u8, key, "--benchmark-camera")) 2 else if (std.mem.eql(u8, key, "--benchmark-rate")) 3 else if (std.mem.eql(u8, key, "--benchmark-duration")) 4 else return error.UnknownBenchmarkOption;
            if (seen & (@as(u8, 1) << bit) != 0) return error.DuplicateBenchmarkOption;
            seen |= @as(u8, 1) << bit;
            switch (bit) {
                0 => {
                    if (value.len == 0) return error.InvalidBenchmarkPath;
                    result.output_prefix = value;
                },
                1 => result.policy = std.meta.stringToEnum(@TypeOf(result.policy), value) orelse return error.InvalidBenchmarkPolicy,
                2 => result.camera = std.meta.stringToEnum(@TypeOf(result.camera), value) orelse return error.InvalidBenchmarkCamera,
                3 => result.rate = try std.fmt.parseInt(u32, value, 10),
                4 => result.duration_seconds = try std.fmt.parseInt(u32, value, 10),
                else => unreachable,
            }
        }
        if (result.rate == 0 or result.rate > 8192 or result.duration_seconds == 0 or result.duration_seconds > 60 or @as(u64, result.rate) * result.duration_seconds > max_events) return error.InvalidBenchmarkSize;
        return result;
    }

    pub fn budget(self: Options) queue.FrameBudget {
        return if (self.policy == .immediate) .{ .max_items = std.math.maxInt(u32), .max_elapsed_ns = std.math.maxInt(u64) } else .{};
    }
};

const Progress = struct { received_ns: u64 = 0, terrain_submit_ns: u64 = 0, miniature_submit_ns: u64 = 0 };
const Chunk = struct {
    id: u32,
    events: std.ArrayList(usize) = .empty,
    prepared: usize = 0,
    uploaded: usize = 0,
    miniatures: usize = 0,
    terrain_submitted: usize = 0,
    miniature_submitted: usize = 0,
};
const Frame = struct {
    timing: engine.Engine.FrameMeasurement,
    receive_ns: u64,
    prepare_ns: u64,
    upload_ns: u64,
    queued: usize,
};
const Quantiles = struct { count: usize = 0, p50_ms: f64 = 0, p95_ms: f64 = 0, p99_ms: f64 = 0, max_ms: f64 = 0, mean_ms: f64 = 0 };

pub const Runner = struct {
    allocator: std.mem.Allocator,
    io: std.Io,
    options: Options,
    scenario: scenario_api.Scenario,
    phase: enum { warmup, active, drain, done } = .warmup,
    start_ns: u64 = 0,
    warmup_ns: u64 = 0,
    ready_since_ns: ?u64 = null,
    resolution: [2]u32 = .{ 0, 0 },
    invalid_reason: ?[]const u8 = null,
    frames: std.ArrayList(Frame) = .empty,
    progress: []Progress,
    cell_index: std.AutoHashMapUnmanaged([3]u32, usize) = .empty,
    chunks: std.ArrayList(Chunk) = .empty,
    chunk_index: std.AutoHashMapUnmanaged(u32, usize) = .empty,
    receive_ns: u64 = 0,
    prepare_ns: u64 = 0,
    upload_ns: u64 = 0,
    peak_queue: usize = 0,
    drain_ns: u64 = 0,
    measured_this_frame: bool = false,
    miniatures_encoded: bool = false,
    checksum: u64 = 0,

    pub fn init(a: std.mem.Allocator, io: std.Io, options: Options, service: *service_api.WorldDataService, owner: u64) !Runner {
        var scenario = try scenario_api.Scenario.init(a, io, service, owner);
        var scenario_owned = true;
        errdefer if (scenario_owned) scenario.deinit();
        const count = @as(usize, options.rate) * options.duration_seconds;
        if (count > scenario.records.len) return error.BenchmarkFixtureExhausted;
        const progress = try a.alloc(Progress, count);
        @memset(progress, .{});
        var result: Runner = .{ .allocator = a, .io = io, .options = options, .scenario = scenario, .progress = progress };
        scenario_owned = false;
        errdefer result.deinit();
        try result.frames.ensureTotalCapacity(a, max_frames);
        try result.cell_index.ensureTotalCapacity(a, @intCast(count));
        for (scenario.records[0..count], 0..) |record, index| {
            try result.cell_index.put(a, record.cell, index);
            const id = service.layout.encodeChunkId(record.cell[0] / 32, record.cell[1] / 32, record.cell[2] / 32);
            const entry = try result.chunk_index.getOrPut(a, id);
            if (!entry.found_existing) {
                entry.value_ptr.* = result.chunks.items.len;
                try result.chunks.append(a, .{ .id = id });
            }
            // Reserve every possible received event before measurements start.
            try result.chunks.items[entry.value_ptr.*].events.ensureUnusedCapacity(a, count / 9 + 9);
        }
        return result;
    }

    pub fn deinit(self: *Runner) void {
        self.scenario.deinit();
        self.frames.deinit(self.allocator);
        self.allocator.free(self.progress);
        self.cell_index.deinit(self.allocator);
        for (self.chunks.items) |*chunk| chunk.events.deinit(self.allocator);
        self.chunks.deinit(self.allocator);
        self.chunk_index.deinit(self.allocator);
    }

    pub fn now(game: anytype) u64 {
        return @intCast(@max(0, game.engine.clock_start.durationTo(std.Io.Clock.awake.now(game.engine.io)).nanoseconds));
    }

    pub fn beginUpdate(self: *Runner, game: anytype) void {
        const at = now(game);
        self.receive_ns = 0;
        self.prepare_ns = 0;
        self.upload_ns = 0;
        self.miniatures_encoded = false;
        self.measured_this_frame = self.phase == .active;
        if (self.warmup_ns == 0) self.warmup_ns = at;
        const scene = game.engine.active_scene.?;
        game.control_mode = .spectator;
        scene.spectator_enabled = false;
        const seconds = if (self.phase == .active) @as(f64, @floatFromInt(at - self.start_ns)) / ns_s else 0;
        const angle = seconds * 0.65;
        const dx = if (self.options.camera == .travel) 40 * @sin(angle) else 8 * @sin(angle);
        const dy = if (self.options.camera == .travel) -4.0 else 8 * @cos(angle);
        const origin = scene.layout.origin_chunk;
        scene.camera.updatePosition(.{
            self.scenario.center[0] - @as(f64, @floatFromInt(origin[0] * 32)) + dx,
            self.scenario.center[1] - @as(f64, @floatFromInt(origin[1] * 32)) + dy,
            @as(f64, @floatFromInt(self.scenario.anchor[2])) - @as(f64, @floatFromInt(origin[2] * 32)) + 6,
        });
        // Same yaw/pitch convention as the normal player controller.
        const yaw: f32 = @floatCast(@mod(seconds * 0.25, 2 * std.math.pi));
        scene.camera.updateView(engine.utils.matMul(zmath.rotationX(0.18), zmath.rotationY(-yaw)));
        if (self.phase == .active or self.phase == .drain) {
            self.scenario.pump(at, self.options.rate, @as(u64, self.options.duration_seconds) * ns_s) catch |err| {
                self.fail(@errorName(err));
                return;
            };
            if (at - self.start_ns >= @as(u64, self.options.duration_seconds) * ns_s) self.phase = .drain;
        }
    }

    pub fn received(self: *Runner, cell: [3]u32, at: u64, layout: *const engine.WorldLayout) void {
        if (self.phase == .warmup or self.phase == .done) return;
        const index = self.cell_index.get(cell) orelse return;
        if (self.progress[index].received_ns != 0) return;
        self.progress[index].received_ns = at;
        const id = layout.encodeChunkId(cell[0] / 32, cell[1] / 32, cell[2] / 32);
        self.chunks.items[self.chunk_index.get(id).?].events.appendAssumeCapacity(index);
    }

    pub fn terrainPrepared(self: *Runner, id: u32) void {
        const index = self.chunk_index.get(id) orelse return;
        const chunk = &self.chunks.items[index];
        chunk.prepared = chunk.events.items.len;
    }
    pub fn terrainPreparedFromBlocks(self: *Runner, id: u32, source: anytype) void {
        const index = self.chunk_index.get(id) orelse return;
        const chunk = &self.chunks.items[index];
        // A mode handoff can retain an older physical snapshot while newer
        // fulfillment notifications have already arrived. Prove source contents.
        while (chunk.prepared < chunk.events.items.len) {
            const record = self.scenario.records[chunk.events.items[chunk.prepared]];
            const local: [3]u5 = .{ @intCast(record.cell[0] % 32), @intCast(record.cell[1] % 32), @intCast(record.cell[2] % 32) };
            if (source.content.getBlock(local) != record.material) break;
            chunk.prepared += 1;
        }
    }
    pub fn terrainUploaded(self: *Runner, id: u32) void {
        const index = self.chunk_index.get(id) orelse return;
        const chunk = &self.chunks.items[index];
        chunk.uploaded = chunk.prepared;
    }
    pub fn miniaturePrepared(self: *Runner, id: u32) void {
        const index = self.chunk_index.get(id) orelse return;
        const chunk = &self.chunks.items[index];
        chunk.miniatures = chunk.events.items.len;
    }

    pub fn fail(self: *Runner, reason: []const u8) void {
        if (self.invalid_reason == null) self.invalid_reason = reason;
        self.phase = .done;
    }

    fn ready(self: *Runner, game: anytype) bool {
        _ = self;
        if (game.loaded_chunk_ids.count() != game.chunk_subscriptions.count() or game.chunk_packages.items.len != 0 or game.chunk_visuals.count() != 0 or game.engine.active_scene.?.voxel_grid.chunks_to_upload.items.len != 0) return false;
        var subscriptions = game.chunk_subscriptions.iterator();
        while (subscriptions.next()) |entry| {
            if (game.chunk_modes.get(entry.key_ptr.*) == .blocks and
                (game.block_snapshot_tokens.get(entry.key_ptr.*) != entry.value_ptr.* or !game.world.?.hasChunk(game.world.?.layout.decodeChunkId(entry.key_ptr.*)))) return false;
        }
        return true;
    }

    pub fn endFrame(self: *Runner, game: anytype, timing: engine.Engine.FrameMeasurement) void {
        const at = timing.finished_ns;
        const scene = game.engine.active_scene.?;
        const resolution: [2]u32 = .{ game.engine.gctx.swapchain_descriptor.width, game.engine.gctx.swapchain_descriptor.height };
        if (game.render_radius != 3) self.fail("RenderRadiusReduced");
        if (self.phase == .warmup) {
            const source_count = game.blueprint_renderer.?.miniatureCacheStats().cached_instances;
            if (self.ready(game) and source_count == self.scenario.target_count and game.engine.window_context.window.getAttribute(.focused)) {
                if (self.ready_since_ns == null) self.ready_since_ns = at;
                if (at - self.ready_since_ns.? >= ns_s) {
                    self.resolution = resolution;
                    self.start_ns = at;
                    self.scenario.start(at);
                    self.phase = .active;
                    std.debug.print("client visual benchmark ready: policy={s} resolution={d}x{d} targets={d}\n", .{ @tagName(self.options.policy), resolution[0], resolution[1], source_count });
                }
            } else self.ready_since_ns = null;
            if (at - self.warmup_ns > 60 * ns_s) self.fail("WarmupTimeout");
        } else if (self.phase != .done) {
            if (!game.engine.window_context.window.getAttribute(.focused)) self.fail("WindowLostFocus");
            if (!std.mem.eql(u32, &resolution, &self.resolution)) self.fail("ResolutionChanged");
            self.peak_queue = @max(self.peak_queue, game.chunk_visuals.count());
            for (self.chunks.items) |*chunk| {
                // Terrain draws all resident chunks; uploaded replacements therefore
                // enter this frame even when clipping/occlusion produces no pixels.
                for (chunk.events.items[chunk.terrain_submitted..chunk.uploaded]) |index| self.progress[index].terrain_submit_ns = timing.submitted_ns;
                chunk.terrain_submitted = chunk.uploaded;
                if (self.miniatures_encoded) {
                    const coords = scene.layout.decodeChunkId(chunk.id);
                    const delta = scene.layout.getChunkDelta(coords, scene.camera.chunk);
                    const in_range = @max(@abs(delta[0]), @abs(delta[1]), @abs(delta[2])) <= @as(u32, @intCast(game.render_radius));
                    if (game.loaded_chunk_ids.contains(chunk.id) and in_range) {
                        for (chunk.events.items[chunk.miniature_submitted..chunk.miniatures]) |index| self.progress[index].miniature_submit_ns = timing.submitted_ns;
                        chunk.miniature_submitted = chunk.miniatures;
                    }
                }
            }
            if (self.measured_this_frame) {
                if (self.frames.items.len == max_frames) self.fail("FrameSampleCapacity") else self.frames.appendAssumeCapacity(.{ .timing = timing, .receive_ns = self.receive_ns, .prepare_ns = self.prepare_ns, .upload_ns = self.upload_ns, .queued = game.chunk_visuals.count() });
            }
            if (self.phase == .drain and self.scenario.isComplete() and self.ready(game) and self.unresolved() == 0) {
                self.drain_ns = at -| (self.start_ns + @as(u64, self.options.duration_seconds) * ns_s);
                self.verify(game) catch |err| self.fail(@errorName(err));
                self.phase = .done;
            }
            if (at - self.start_ns > (@as(u64, self.options.duration_seconds) + 30) * ns_s) self.fail("DrainTimeout");
        }
        if (self.phase == .done) game.engine.requestExit();
    }

    fn verify(self: *Runner, game: anytype) !void {
        if (self.scenario.counters.admitted != self.progress.len or self.scenario.counters.accepted != self.progress.len or self.scenario.counters.rejected != 0) return error.WorkloadNotAccepted;
        if (game.blueprint_renderer.?.miniatureCacheStats().cached_instances != self.scenario.target_count - self.progress.len) return error.StaleFinalMiniatures;
        var hash = std.hash.Wyhash.init(0);
        const reader = game.world.?.reader();
        for (self.scenario.records[0..self.progress.len]) |record| {
            const material = reader.get(record.cell) orelse return error.MissingFinalBlock;
            if (material != record.material) return error.StaleFinalBlock;
            hash.update(std.mem.asBytes(&record.cell));
            hash.update(std.mem.asBytes(&material));
        }
        self.checksum = hash.final();
    }

    fn unresolved(self: *const Runner) usize {
        var count: usize = 0;
        for (self.chunks.items) |chunk| count += chunk.events.items.len - chunk.terrain_submitted + chunk.events.items.len - chunk.miniature_submitted;
        // Include events not received yet, not just the currently dirty prefix.
        var received_count: usize = 0;
        for (self.chunks.items) |chunk| received_count += chunk.events.items.len;
        return count + 2 * (self.progress.len - received_count);
    }

    fn quantiles(a: std.mem.Allocator, values: []u64) Quantiles {
        _ = a;
        if (values.len == 0) return .{};
        std.mem.sort(u64, values, {}, std.sort.asc(u64));
        var total: f64 = 0;
        for (values) |value| total += @floatFromInt(value);
        return .{ .count = values.len, .p50_ms = ms(values[(values.len * 50 + 99) / 100 - 1]), .p95_ms = ms(values[(values.len * 95 + 99) / 100 - 1]), .p99_ms = ms(values[(values.len * 99 + 99) / 100 - 1]), .max_ms = ms(values[values.len - 1]), .mean_ms = total / @as(f64, @floatFromInt(values.len)) / std.time.ns_per_ms };
    }
    fn frameMetric(self: *Runner, comptime name: []const u8) !Quantiles {
        const samples = try self.allocator.alloc(u64, self.frames.items.len);
        defer self.allocator.free(samples);
        for (self.frames.items, samples) |frame, *sample| sample.* = if (comptime std.mem.eql(u8, name, "frame")) frame.timing.finished_ns - frame.timing.started_ns else if (comptime std.mem.eql(u8, name, "interval")) frame.timing.frame_interval_ns else if (comptime std.mem.eql(u8, name, "prepare")) frame.prepare_ns else if (comptime std.mem.eql(u8, name, "upload")) frame.upload_ns else @field(frame.timing, name ++ "_ns");
        return quantiles(self.allocator, samples);
    }
    fn latencyMetric(self: *Runner, comptime name: []const u8) !Quantiles {
        var samples: std.ArrayList(u64) = .empty;
        defer samples.deinit(self.allocator);
        for (self.progress) |progress| if (@field(progress, name) != 0 and progress.received_ns != 0) try samples.append(self.allocator, @field(progress, name) - progress.received_ns);
        return quantiles(self.allocator, samples.items);
    }
    fn write(self: *Runner, suffix: []const u8, data: []const u8) !void {
        const path = try std.fmt.allocPrint(self.allocator, "{s}{s}", .{ self.options.output_prefix, suffix });
        defer self.allocator.free(path);
        try std.Io.Dir.cwd().writeFile(self.io, .{ .sub_path = path, .data = data });
    }

    pub fn exportResults(self: *Runner) !void {
        if (self.phase != .done) self.fail("Interrupted");
        var csv: std.ArrayList(u8) = .empty;
        defer csv.deinit(self.allocator);
        try csv.appendSlice(self.allocator, "frame,started_ns,interval_ns,frame_ns,poll_ns,update_ns,draw_ns,submit_ns,present_ns,receive_ns,prepare_ns,upload_ns,queued_chunks\n");
        var over16: usize = 0;
        var over33: usize = 0;
        for (self.frames.items, 0..) |frame, index| {
            const t = frame.timing;
            const duration = t.finished_ns - t.started_ns;
            if (duration > 16_666_667) over16 += 1;
            if (duration > 33_333_333) over33 += 1;
            try appendPrint(&csv, self.allocator, "{d},{d},{d},{d},{d},{d},{d},{d},{d},{d},{d},{d},{d}\n", .{ index, t.started_ns, t.frame_interval_ns, duration, t.poll_ns, t.update_ns, t.draw_ns, t.submit_ns, t.present_ns, frame.receive_ns, frame.prepare_ns, frame.upload_ns, frame.queued });
        }
        try self.write(".frames.csv", csv.items);
        csv.clearRetainingCapacity();
        try csv.appendSlice(self.allocator, "event,x,y,z,status,scheduled_ns,admitted_ns,ack_ns,received_ns,terrain_submit_ns,miniature_submit_ns\n");
        for (self.progress, self.scenario.records[0..self.progress.len], 0..) |p, event, index| try appendPrint(&csv, self.allocator, "{d},{d},{d},{d},{s},{d},{d},{d},{d},{d},{d}\n", .{ index, event.cell[0], event.cell[1], event.cell[2], @tagName(event.status), event.scheduled_ns, event.submitted_ns, event.ack_ns, p.received_ns, p.terrain_submit_ns, p.miniature_submit_ns });
        try self.write(".events.csv", csv.items);
        var hash_text: [16]u8 = undefined;
        const checksum = try std.fmt.bufPrint(&hash_text, "{x:0>16}", .{self.checksum});
        var last_ack_elapsed_ns: u64 = @as(u64, self.options.duration_seconds) * ns_s;
        for (self.scenario.records[0..self.progress.len]) |event| last_ack_elapsed_ns = @max(last_ack_elapsed_ns, event.ack_ns -| self.start_ns);
        const acceptance_window_seconds = @as(f64, @floatFromInt(last_ack_elapsed_ns)) / ns_s;
        const summary = try std.json.Stringify.valueAlloc(self.allocator, .{
            .schema_version = 1,
            .valid = self.invalid_reason == null and self.frames.items.len > 0 and self.unresolved() == 0,
            .invalid_reason = self.invalid_reason,
            .policy = @tagName(self.options.policy),
            .camera = @tagName(self.options.camera),
            .rate = self.options.rate,
            .duration_seconds = self.options.duration_seconds,
            .resolution = self.resolution,
            .frame_count = self.frames.items.len,
            .planned_edits = self.progress.len,
            .admitted_edits = self.scenario.counters.admitted,
            .accepted_edits = self.scenario.counters.accepted,
            .rejected_edits = self.scenario.counters.rejected,
            .acceptance_window_seconds = acceptance_window_seconds,
            .accepted_edits_per_second = @as(f64, @floatFromInt(self.scenario.counters.accepted)) / acceptance_window_seconds,
            .busy_events = self.scenario.counters.busy_events,
            .final_checksum = checksum,
            .unresolved_visuals = self.unresolved(),
            .frames_over_16_7ms = over16,
            .frames_over_33_3ms = over33,
            .peak_queue = self.peak_queue,
            .drain_ms = ms(self.drain_ns),
            .metrics = .{ .frame = try self.frameMetric("frame"), .interval = try self.frameMetric("interval"), .update = try self.frameMetric("update"), .draw = try self.frameMetric("draw"), .prepare = try self.frameMetric("prepare"), .upload = try self.frameMetric("upload"), .terrain_submit_latency = try self.latencyMetric("terrain_submit_ns"), .miniature_submit_latency = try self.latencyMetric("miniature_submit_ns") },
            .latency_scope = "client fulfillment receipt to first submitted chunk representation; may be clipped or occluded; not physical display latency",
            .comparison_scope = "budget limits only; immediate retains FIFO and miniature cache",
        }, .{ .whitespace = .indent_2 });
        defer self.allocator.free(summary);
        try self.write(".summary.json", summary);
    }
};

fn ms(ns: u64) f64 {
    return @as(f64, @floatFromInt(ns)) / std.time.ns_per_ms;
}
fn appendPrint(list: *std.ArrayList(u8), a: std.mem.Allocator, comptime fmt: []const u8, args: anytype) !void {
    const text = try std.fmt.allocPrint(a, fmt, args);
    defer a.free(text);
    try list.appendSlice(a, text);
}

test "client benchmark options are opt-in bounded and reject ambiguous flags" {
    try std.testing.expectEqual(@as(?Options, null), try Options.parse(&.{"--ephemeral"}));
    const options = (try Options.parse(&.{ "--benchmark-visuals", "/tmp/result", "--visual-policy", "immediate", "--benchmark-rate", "512" })).?;
    try std.testing.expectEqual(@as(u32, 512), options.rate);
    try std.testing.expectEqual(std.math.maxInt(u32), options.budget().max_items);
    try std.testing.expectError(error.DuplicateBenchmarkOption, Options.parse(&.{ "--benchmark-visuals", "a", "--benchmark-rate", "2", "--benchmark-rate", "3" }));
    try std.testing.expectError(error.InvalidBenchmarkSize, Options.parse(&.{ "--benchmark-visuals", "a", "--benchmark-rate", "0" }));
    try std.testing.expectError(error.UnknownBenchmarkOption, Options.parse(&.{ "--benchmark-visuals", "a", "--world", "save" }));
}

test "client latency watermarks preserve independently prepared coalesced events" {
    const a = std.testing.allocator;
    var runner: Runner = undefined;
    runner.allocator = a;
    runner.chunks = .empty;
    runner.chunk_index = .empty;
    defer {
        for (runner.chunks.items) |*chunk| chunk.events.deinit(a);
        runner.chunks.deinit(a);
        runner.chunk_index.deinit(a);
    }
    try runner.chunks.append(a, .{ .id = 12 });
    try runner.chunk_index.put(a, 12, 0);
    try runner.chunks.items[0].events.appendSlice(a, &.{ 0, 1 });
    runner.terrainPrepared(12);
    try runner.chunks.items[0].events.append(a, 2);
    runner.miniaturePrepared(12);
    runner.terrainUploaded(12);
    try std.testing.expectEqual(@as(usize, 2), runner.chunks.items[0].uploaded);
    try std.testing.expectEqual(@as(usize, 3), runner.chunks.items[0].miniatures);
    runner.terrainPrepared(12);
    runner.terrainUploaded(12);
    try std.testing.expectEqual(@as(usize, 3), runner.chunks.items[0].uploaded);
}

test "client terrain latency requires actual prepared blocks after a mode handoff" {
    const a = std.testing.allocator;
    var runner: Runner = undefined;
    runner.chunks = .empty;
    runner.chunk_index = .empty;
    defer {
        for (runner.chunks.items) |*chunk| chunk.events.deinit(a);
        runner.chunks.deinit(a);
        runner.chunk_index.deinit(a);
    }
    var records = [_]scenario_api.Record{
        .{ .cell = .{ 32, 32, 48 }, .instance_id = 1, .cell_index = 0, .material = .rebar },
        .{ .cell = .{ 33, 32, 48 }, .instance_id = 1, .cell_index = 1, .material = .rebar },
    };
    runner.scenario = undefined;
    runner.scenario.records = &records;
    try runner.chunks.append(a, .{ .id = 12 });
    try runner.chunk_index.put(a, 12, 0);
    try runner.chunks.items[0].events.appendSlice(a, &.{ 0, 1 });
    const world = @import("world.zig");
    runner.terrainPreparedFromBlocks(12, world.WorldChunk.initEmpty());
    try std.testing.expectEqual(@as(usize, 0), runner.chunks.items[0].prepared);
    var data = @import("world_chunk_data.zig").WorldChunkData.initEmpty();
    data.blocks[16][0][0] = .rebar;
    const source = world.WorldChunk.initBlocks(&data);
    runner.terrainPreparedFromBlocks(12, source);
    runner.terrainUploaded(12);
    try std.testing.expectEqual(@as(usize, 1), runner.chunks.items[0].uploaded);
    data.blocks[16][0][1] = .rebar;
    runner.terrainPreparedFromBlocks(12, source);
    runner.terrainUploaded(12);
    try std.testing.expectEqual(@as(usize, 2), runner.chunks.items[0].uploaded);
}
