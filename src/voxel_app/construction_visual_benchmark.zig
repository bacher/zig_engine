//! `zig build bench-construction-visuals -Doptimize=ReleaseFast`.
//! Small CPU replay of already accepted construction fills. Uses production mesh
//! extraction, blueprint target indexes, blockInstance, Queue and FrameBudget.
//! Excludes validation, service traffic, GPU/upload, and the full Game lifecycle.
//! Publication below means completion of CPU work at a nominal 60 Hz tick, not
//! GPU visibility or wall-paced end-to-end latency. CPU overruns do not slow input.
const std = @import("std");
const engine = @import("engine");
const world_module = @import("world.zig");
const extraction = @import("world_engine_glue.zig");
const runtime = @import("blueprint_runtime.zig");
const visuals = @import("chunk_visual_queue.zig");
const WorldChunkData = @import("world_chunk_data.zig").WorldChunkData;
const renderer = engine.blueprint_renderer;
const Camera = std.meta.Child(@TypeOf(@as(engine.Scene, undefined).camera));
const chunk_count = 27;
const input_frames = 240;
const repetitions = 3;
const max_frames = input_frames + 128;
const ns_per_second = std.time.ns_per_s;

const Variant = enum { legacy_dynamic_immediate, cached_immediate, cached_budget_age0, cached_budget_age2 };
const Scenario = enum { fill_1hz, fill_32hz, fill_128hz, fill_512hz, burst_27 };
const Event = struct { at_ns: u64, slot: usize, cell: runtime.Cell };
const Samples = struct {
    values: [max_frames * chunk_count]u64 = undefined,
    len: usize = 0,

    fn add(self: *Samples, value: u64) void {
        self.values[self.len] = value;
        self.len += 1;
    }

    fn print(self: *Samples, name: []const u8, divisor: f64) void {
        std.mem.sort(u64, self.values[0..self.len], {}, std.sort.asc(u64));
        std.debug.print(" {s}_n={d} {s}_p50={d:.4} {s}_p95={d:.4} {s}_p99={d:.4} {s}_max={d:.4}", .{
            name, self.len,
            name, self.quantile(50, divisor),
            name, self.quantile(95, divisor),
            name, self.quantile(99, divisor),
            name, if (self.len == 0) @as(f64, 0) else @as(f64, @floatFromInt(self.values[self.len - 1])) / divisor,
        });
    }

    fn quantile(self: *const Samples, percentile: usize, divisor: f64) f64 {
        if (self.len == 0) return 0;
        const rank = (self.len * percentile + 99) / 100;
        return @as(f64, @floatFromInt(self.values[rank - 1])) / divisor;
    }
};

const Report = struct {
    all: Samples = .{},
    active: Samples = .{},
    first_age: Samples = .{},
    latest_age: Samples = .{},
    mesh_builds: u64 = 0,
    source_builds: u64 = 0,
    target_reads: u64 = 0,
    source_cells: u64 = 0,
    source_bytes: u64 = 0,
    cpu_ns: u64 = 0,
    over_2ms: u32 = 0,
    over_16ms: u32 = 0,
    virtual_late_frames: u32 = 0,
    virtual_max_lateness_ns: u64 = 0,
    peak_backlog: usize = 0,
    backlog_at_input_stop: usize = 0,
    drain_frames: u64 = 0,
    checksum: u64 = 0,
};

const Fixture = struct {
    world: world_module.World,
    ids: [chunk_count]u32 = undefined,
    meshes: [chunk_count]engine.voxel_chunk.ChunkSideData = @splat(.{}),
    sources: [chunk_count]std.ArrayList(renderer.MiniatureCell) = @splat(.empty),
    dynamic: std.ArrayList(renderer.Instance) = .empty,
    revision: [chunk_count]u64 = @splat(0),
    published: [chunk_count]u64 = @splat(0),
    first_dirty: [chunk_count]?u64 = @splat(null),
    latest_dirty: [chunk_count]u64 = @splat(0),

    fn init(allocator: std.mem.Allocator) !Fixture {
        const layout = try engine.WorldLayout.init(.{ .size_in_chunks = .{ 8, 8, 8 } });
        var self: Fixture = .{ .world = try world_module.World.init(allocator, &layout) };
        errdefer self.deinit();
        self.world.blueprints.layout = self.world.layout;
        for (0..chunk_count) |slot| {
            const coords = coordinates(slot);
            const id = self.world.layout.encodeChunkCoords(coords);
            self.ids[slot] = id;
            const data = try allocator.create(WorldChunkData);
            data.* = WorldChunkData.initEmpty();
            // A complete stone floor and two existing six-block-high walls.
            for (0..32) |y| for (0..32) |x| {
                data.blocks[0][y][x] = .stone;
            };
            for (1..7) |z| for (2..30) |along| {
                data.blocks[z][2][along] = .rebar;
                data.blocks[z][along][2] = .rebar;
            };
            self.world.insertChunk(coords, world_module.WorldChunk.initBlocks(data)) catch |err| {
                allocator.destroy(data);
                return err;
            };
            var index: runtime.ChunkIndex = .{};
            errdefer index.deinit(allocator);
            // An unfinished 24x24 perimeter: eight wall courses, no roof.
            // These indexes represent already admitted targets, not validation.
            for (1..9) |z| for (4..28) |y| for (4..28) |x| {
                if (x != 4 and x != 27 and y != 4 and y != 27) continue;
                const cell: runtime.Cell = .{
                    @as(u32, @intCast(coords[0])) * 32 + @as(u32, @intCast(x)),
                    @as(u32, @intCast(coords[1])) * 32 + @as(u32, @intCast(y)),
                    @as(u32, @intCast(coords[2])) * 32 + @as(u32, @intCast(z)),
                };
                try index.lookup.put(allocator, cell, .{ .instance_id = slot + 1, .cell_index = @intCast(index.targets.items.len), .material = .planks, .chunk_slot = index.targets.items.len });
                try index.targets.append(allocator, cell);
            };
            try self.world.blueprints.chunks.put(allocator, id, index);
        }
        // Warm allocations and initial visual contents outside all timed frames.
        var ignored: Report = .{};
        for (0..chunk_count) |slot| try self.rebuild(slot, true, &ignored);
        var camera = Camera.init(self.world.layout, 16.0 / 9.0);
        try self.buildDynamic(&camera, &ignored);
        return self;
    }

    fn deinit(self: *Fixture) void {
        const allocator = self.world.allocator;
        for (&self.meshes) |*mesh| mesh.deinit(allocator);
        for (&self.sources) |*cells| cells.deinit(allocator);
        self.dynamic.deinit(allocator);
        self.world.deinit();
    }

    fn neighbors(self: *const Fixture, slot: usize) extraction.BoundaryMasks {
        var result: extraction.BoundaryMasks = @splat(.{});
        for (std.enums.values(engine.voxel_chunk.Side)) |side| {
            const adjacent = world_module.adjacentChunk(self.world.layout, coordinates(slot), side) orelse continue;
            if (self.world.getChunk(adjacent)) |chunk|
                result[@intFromEnum(side)] = chunk.boundaries[@intFromEnum(side.getOpposite())];
        }
        return result;
    }

    fn pack(self: *const Fixture, slot: usize, output: *std.ArrayList(renderer.MiniatureCell)) !void {
        output.clearRetainingCapacity();
        const targets = self.world.blueprints.chunkTargets(self.ids[slot]);
        try output.ensureTotalCapacity(self.world.allocator, targets.len);
        // Same public target/solid lookups and source record as Game's collector.
        for (targets) |cell| {
            const target = self.world.blueprints.targetAt(cell) orelse continue;
            if (try self.world.isBlockSolid(cell)) continue;
            const local = world_module.splitBlockCoords(cell)[1];
            output.appendAssumeCapacity(.{ .local = .{ local[0], local[1], local[2] }, .material = @intFromEnum(target.material) });
        }
    }

    fn rebuild(self: *Fixture, slot: usize, cached: bool, report: *Report) !void {
        const allocator = self.world.allocator;
        const climate: extraction.ClimateMap = @splat(@splat(.temperate));
        const replacement = try extraction.tryExtractChunkGeometryWithClimate(allocator, self.world.chunks.get(self.ids[slot]).?, self.neighbors(slot), &climate);
        self.meshes[slot].deinit(allocator);
        self.meshes[slot] = replacement;
        report.mesh_builds += 1;
        if (cached) {
            try self.pack(slot, &self.sources[slot]);
            report.source_builds += 1;
            report.target_reads += self.world.blueprints.chunkTargets(self.ids[slot]).len;
            report.source_cells += self.sources[slot].items.len;
            report.source_bytes += self.sources[slot].items.len * @sizeOf(renderer.MiniatureCell);
        }
    }

    fn buildDynamic(self: *Fixture, camera: *const Camera, report: *Report) !void {
        self.dynamic.clearRetainingCapacity();
        for (self.ids) |id| {
            const targets = self.world.blueprints.chunkTargets(id);
            report.source_builds += 1;
            report.target_reads += targets.len;
            for (targets) |cell| {
                const target = self.world.blueprints.targetAt(cell) orelse continue;
                if (try self.world.isBlockSolid(cell)) continue;
                try self.dynamic.append(self.world.allocator, renderer.blockInstance(camera, .{ cell[0], cell[1], cell[2] }, target.material, true, false));
                report.source_cells += 1;
                report.source_bytes += @sizeOf(renderer.Instance);
            }
        }
        std.mem.doNotOptimizeAway(self.dynamic.items);
    }

    fn apply(self: *Fixture, event: Event) !void {
        const target = self.world.blueprints.targetAt(event.cell) orelse return error.MissingTraceTarget;
        const chunk = self.world.chunks.getPtr(self.ids[event.slot]).?;
        if (try chunk.tryApply(self.world.allocator, world_module.splitBlockCoords(event.cell)[1], .{ .put = target.material }) != .success)
            return error.InvalidTraceFill;
        _ = self.world.blueprints.chunks.getPtr(self.ids[event.slot]).?.removeTarget(event.cell) orelse return error.MissingTraceTarget;
        self.revision[event.slot] += 1;
        if (self.first_dirty[event.slot] == null) self.first_dirty[event.slot] = event.at_ns;
        self.latest_dirty[event.slot] = event.at_ns;
    }

    fn publish(self: *Fixture, slot: usize, now_ns: u64, report: *Report) void {
        report.first_age.add(now_ns - self.first_dirty[slot].?);
        report.latest_age.add(now_ns - self.latest_dirty[slot]);
        self.first_dirty[slot] = null;
        self.published[slot] = self.revision[slot];
    }

    fn backlog(self: *const Fixture) usize {
        var count: usize = 0;
        for (self.first_dirty) |dirty| if (dirty != null) {
            count += 1;
        };
        return count;
    }

    fn verify(self: *Fixture, cached: bool, camera: *const Camera, events: []const Event) !u64 {
        var hash = std.hash.Wyhash.init(0);
        var expected: std.ArrayList(renderer.MiniatureCell) = .empty;
        defer expected.deinit(self.world.allocator);
        var dynamic_index: usize = 0;
        for (0..chunk_count) |slot| {
            if (self.published[slot] != self.revision[slot]) return error.UnpublishedFinalRevision;
            const chunk = self.world.chunks.get(self.ids[slot]).?;
            hash.update(std.mem.asBytes(chunk.content.blocks));
            var mesh = try extraction.tryExtractChunkGeometry(self.world.allocator, chunk, self.neighbors(slot));
            defer mesh.deinit(self.world.allocator);
            for (mesh.blocks_grouped_by_side, self.meshes[slot].blocks_grouped_by_side) |wanted, actual| {
                if (!std.mem.eql(u8, std.mem.sliceAsBytes(wanted.items), std.mem.sliceAsBytes(actual.items))) return error.StaleFinalMesh;
                hash.update(std.mem.sliceAsBytes(actual.items));
            }
            try self.pack(slot, &expected);
            if (cached) {
                if (!std.mem.eql(u8, std.mem.sliceAsBytes(expected.items), std.mem.sliceAsBytes(self.sources[slot].items))) return error.StaleFinalMiniatures;
            } else for (self.world.blueprints.chunkTargets(self.ids[slot])) |cell| {
                const target = self.world.blueprints.targetAt(cell).?;
                const wanted = renderer.blockInstance(camera, .{ cell[0], cell[1], cell[2] }, target.material, true, false);
                if (dynamic_index >= self.dynamic.items.len or !std.meta.eql(wanted, self.dynamic.items[dynamic_index])) return error.StaleFinalDynamic;
                dynamic_index += 1;
            }
            hash.update(std.mem.sliceAsBytes(expected.items));
        }
        if (!cached and dynamic_index != self.dynamic.items.len) return error.ExtraFinalDynamic;
        for (events) |event| {
            if (!try self.world.isBlockSolid(event.cell) or self.world.blueprints.targetAt(event.cell) != null) return error.TraceNotApplied;
        }
        return hash.final();
    }
};

fn coordinates(slot: usize) engine.ChunkCoords {
    return .{ @intCast(2 + slot % 3), @intCast(2 + slot / 3 % 3), @intCast(2 + slot / 9) };
}

fn slotOf(layout: *const engine.WorldLayout, id: u32) usize {
    const coords = layout.decodeChunkId(id);
    return @intCast((coords[0] - 2) + (coords[1] - 2) * 3 + (coords[2] - 2) * 9);
}

fn makeTrace(allocator: std.mem.Allocator, fixture: *const Fixture, scenario: Scenario) ![]Event {
    const rate: u64 = switch (scenario) {
        .fill_1hz => 1,
        .fill_32hz => 32,
        .fill_128hz => 128,
        .fill_512hz => 512,
        .burst_27 => 0,
    };
    const count: usize = if (rate == 0) chunk_count else @intCast(rate * input_frames / 60);
    const events = try allocator.alloc(Event, count);
    errdefer allocator.free(events);
    for (events, 0..) |*event, index| {
        const slot = index % chunk_count;
        const targets = fixture.world.blueprints.chunkTargets(fixture.ids[slot]);
        if (index / chunk_count >= targets.len) return error.TraceExhaustsTargets;
        event.* = .{ .at_ns = if (rate == 0) ns_per_second else @as(u64, @intCast(index)) * ns_per_second / rate, .slot = slot, .cell = targets[index / chunk_count] };
    }
    return events;
}

fn elapsed(io: std.Io, start: std.Io.Timestamp) u64 {
    return @intCast(@max(0, start.durationTo(std.Io.Clock.awake.now(io)).nanoseconds));
}

fn run(init: std.process.Init, variant: Variant, events: []const Event) !Report {
    var fixture = try Fixture.init(init.gpa);
    defer fixture.deinit();
    var camera = Camera.init(fixture.world.layout, 16.0 / 9.0);
    var queue: visuals.Queue = .{ .min_age_frames = if (variant == .cached_budget_age2) 2 else 0 };
    defer queue.deinit(init.gpa);
    var report: Report = .{};
    var next_event: usize = 0;
    var frame: u64 = 0;
    var virtual_finished_ns: u64 = 0;
    const cached = variant != .legacy_dynamic_immediate;
    while (frame < input_frames or fixture.backlog() != 0) : (frame += 1) {
        if (frame >= max_frames) return error.QueueDidNotDrain;
        // Each frame receives its complete fixed timestamp interval. The final
        // frame therefore consumes arrivals just before the four-second stop.
        const now_ns = (frame + 1) * ns_per_second / 60;
        const begin_event = next_event;
        while (next_event < events.len and events[next_event].at_ns <= now_ns) : (next_event += 1)
            try fixture.apply(events[next_event]);
        camera.updatePosition(.{ @as(f64, @floatFromInt(frame)) / 60, 0, 0 });
        report.peak_backlog = @max(report.peak_backlog, fixture.backlog());
        const before_builds = report.mesh_builds + report.source_builds;
        const started = std.Io.Clock.awake.now(init.io);
        for (events[begin_event..next_event]) |event| try queue.mark(init.gpa, fixture.ids[event.slot], 1, frame);
        var budget: visuals.FrameBudget = if (variant == .cached_budget_age0 or variant == .cached_budget_age2) .{} else .{ .max_items = std.math.maxInt(u32), .max_elapsed_ns = std.math.maxInt(u64) };
        while (budget.canStart(elapsed(init.io, started))) {
            const item = queue.take(frame) orelse break;
            const slot = slotOf(fixture.world.layout, item.id);
            try fixture.rebuild(slot, cached, &report);
            fixture.publish(slot, now_ns, &report);
            budget.record();
        }
        if (!cached) try fixture.buildDynamic(&camera, &report);
        const cpu_ns = elapsed(init.io, started);
        report.all.add(cpu_ns);
        if (report.mesh_builds + report.source_builds != before_builds) report.active.add(cpu_ns);
        report.cpu_ns += cpu_ns;
        if (cpu_ns > 2_000_000) report.over_2ms += 1;
        if (cpu_ns > ns_per_second / 60) report.over_16ms += 1;
        // Serialized visual-work-only model; other game costs are absent. This
        // does not change the nominal input ticks or scheduled-publication ages.
        virtual_finished_ns = @max(now_ns, virtual_finished_ns) + cpu_ns;
        const virtual_lateness = virtual_finished_ns -| ((frame + 2) * ns_per_second / 60);
        if (virtual_lateness != 0) report.virtual_late_frames += 1;
        report.virtual_max_lateness_ns = @max(report.virtual_max_lateness_ns, virtual_lateness);
        if (frame == input_frames - 1) report.backlog_at_input_stop = fixture.backlog();
    }
    if (next_event != events.len or queue.count() != 0) return error.UnconsumedTrace;
    report.drain_frames = frame - input_frames;
    report.checksum = try fixture.verify(cached, &camera, events);
    return report;
}

pub fn main(init: std.process.Init) !void {
    std.debug.print("construction visual CPU replay build={s} chunks=27 input_frames=240 nominal_hz=60 repeats=3 warm_initial_builds_excluded=true\n", .{@tagName(@import("builtin").mode)});
    std.debug.print("scope=production_meshing+target_lookup+CPU_packing+scheduling excludes=GPU,upload,validation,service,full_Game_lifecycle ages=fixed_60Hz_scheduled_frame_ms_not_wall_clock_present_latency input_does_not_slow_with_CPU virtual_lateness=serialized_measured_visual_CPU_only timings_include_publication_age_accounting=true fixture_geometry_not_full_admission=true\n", .{});
    std.debug.print("legacy_dynamic=48-byte_camera_instances_each_frame cached=16-byte_local_records_on_dirty; this isolates mesh/cache CPU work and does not establish the value of staging machinery or NPC throughput\n", .{});
    var trace_fixture = try Fixture.init(init.gpa);
    defer trace_fixture.deinit();
    const variants = std.enums.values(Variant);
    for (std.enums.values(Scenario)) |scenario| {
        const events = try makeTrace(init.gpa, &trace_fixture, scenario);
        defer init.gpa.free(events);
        var trace_hash = std.hash.Wyhash.init(0);
        for (events) |event| {
            trace_hash.update(std.mem.asBytes(&event.at_ns));
            trace_hash.update(std.mem.asBytes(&event.cell));
        }
        var checksum: ?u64 = null;
        for (0..repetitions) |repeat| for (0..variants.len) |order| {
            const variant = variants[if (repeat % 2 == 0) order else variants.len - order - 1];
            var report = try run(init, variant, events);
            if (checksum) |expected| {
                if (report.checksum != expected) return error.VariantFinalStateMismatch;
            } else checksum = report.checksum;
            std.debug.print("scenario={s} repeat={d} variant={s} events={d} trace={x} checksum={x} cpu_total_ms={d:.3} meshes={d} source_builds={d} target_reads={d} source_cells={d} source_bytes={d} peak_backlog={d} backlog_at_input_stop={d} drain_frames={d} drain_nominal_ms={d:.3} frames_over_2ms={d} frames_over_16_667ms={d} virtual_late_frames={d} virtual_max_lateness_ms={d:.3}", .{
                @tagName(scenario),                                          repeat + 1,                                                                   @tagName(variant),    events.len,                                               trace_hash.final(),  report.checksum,
                @as(f64, @floatFromInt(report.cpu_ns)) / std.time.ns_per_ms, report.mesh_builds,                                                           report.source_builds, report.target_reads,                                      report.source_cells, report.source_bytes,
                report.peak_backlog,                                         report.backlog_at_input_stop,                                                 report.drain_frames,  @as(f64, @floatFromInt(report.drain_frames)) * 1000 / 60, report.over_2ms,     report.over_16ms,
                report.virtual_late_frames,                                  @as(f64, @floatFromInt(report.virtual_max_lateness_ns)) / std.time.ns_per_ms,
            });
            report.all.print("all_cpu_ms", std.time.ns_per_ms);
            report.active.print("active_cpu_ms", std.time.ns_per_ms);
            report.first_age.print("first_dirty_age_ms", std.time.ns_per_ms);
            report.latest_age.print("latest_dirty_age_ms", std.time.ns_per_ms);
            std.debug.print("\n", .{});
        };
    }
}
