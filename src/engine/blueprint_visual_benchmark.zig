//! Offscreen component benchmark, not application FPS or presentation latency.
//! `zig build bench-blueprint-visual-gpu -Doptimize=ReleaseFast`
const std = @import("std");
const builtin = @import("builtin");
const zgpu = @import("zgpu");
const wgpu = zgpu.wgpu;
const zmath = @import("zmath");
const blueprint = @import("blueprint_renderer.zig");
const Camera = @import("camera.zig").Camera;
const WorldLayout = @import("world_layout.zig").WorldLayout;
const BlockType = @import("voxel/voxel_chunk.zig").BlockType;

extern fn dniCreate() ?*anyopaque;
extern fn dniDestroy(instance: ?*anyopaque) void;
extern fn dniGetWgpuInstance(instance: ?*anyopaque) ?wgpu.Instance;
extern fn dnGetProcs() ?*anyopaque;
extern fn dawnProcSetProcs(procs: ?*anyopaque) void;

const AdapterResponse = struct {
    adapter: ?wgpu.Adapter = null,
    fn callback(status: wgpu.RequestAdapterStatus, adapter: wgpu.Adapter, message: ?[*:0]const u8, userdata: ?*anyopaque) callconv(.c) void {
        const self: *AdapterResponse = @ptrCast(@alignCast(userdata));
        if (status == .success) self.adapter = adapter else std.debug.print("adapter: {s}\n", .{message orelse "unavailable"});
    }
};
const DeviceResponse = struct {
    device: ?wgpu.Device = null,
    fn callback(status: wgpu.RequestDeviceStatus, device: wgpu.Device, message: ?[*:0]const u8, userdata: ?*anyopaque) callconv(.c) void {
        const self: *DeviceResponse = @ptrCast(@alignCast(userdata));
        if (status == .success) self.device = device else std.debug.print("device: {s}\n", .{message orelse "unavailable"});
    }
};
const Validation = struct {
    errors: usize = 0,
    fn callback(kind: wgpu.ErrorType, message: ?[*:0]const u8, userdata: ?*anyopaque) callconv(.c) void {
        if (kind == .no_error) return;
        const self: *Validation = @ptrCast(@alignCast(userdata));
        self.errors += 1;
        std.debug.print("GPU validation {s}: {s}\n", .{ @tagName(kind), message orelse "unknown" });
    }
};
const Completion = struct {
    done: bool = false,
    status: wgpu.QueueWorkDoneStatus = .unknown,
    fn callback(status: wgpu.QueueWorkDoneStatus, userdata: ?*anyopaque) callconv(.c) void {
        const self: *Completion = @ptrCast(@alignCast(userdata));
        self.status = status;
        self.done = true;
    }
};
const Mapping = struct {
    done: bool = false,
    status: wgpu.BufferMapAsyncStatus = .unknown,
    fn callback(status: wgpu.BufferMapAsyncStatus, userdata: ?*anyopaque) callconv(.c) void {
        const self: *Mapping = @ptrCast(@alignCast(userdata));
        self.status = status;
        self.done = true;
    }
};

const Gpu = struct {
    native: *anyopaque,
    adapter: wgpu.Adapter,
    device: wgpu.Device,
    fn init() !Gpu {
        dawnProcSetProcs(dnGetProcs());
        const native = dniCreate() orelse return error.NoGraphicsInstance;
        errdefer dniDestroy(native);
        const instance = dniGetWgpuInstance(native) orelse return error.NoGraphicsInstance;
        var adapter_response: AdapterResponse = .{};
        instance.requestAdapter(.{ .power_preference = .high_performance, .backend_type = if (builtin.os.tag == .macos) .metal else .undef }, AdapterResponse.callback, &adapter_response);
        const adapter = adapter_response.adapter orelse return error.NoGraphicsAdapter;
        errdefer adapter.release();
        var properties: wgpu.AdapterProperties = undefined;
        properties.next_in_chain = null;
        adapter.getProperties(&properties);
        if (properties.backend_type == .nul) return error.NoGraphicsAdapter;
        std.debug.print("adapter={s} backend={s} optimize={s} wrap_x={}\n", .{ properties.name, @tagName(properties.backend_type), @tagName(builtin.mode), WorldLayout.wrap_x });
        var device_response: DeviceResponse = .{};
        adapter.requestDevice(.{}, DeviceResponse.callback, &device_response);
        return .{ .native = native, .adapter = adapter, .device = device_response.device orelse return error.NoGraphicsDevice };
    }
    fn deinit(self: Gpu) void {
        self.device.destroy();
        self.device.release();
        self.adapter.release();
        dniDestroy(self.native);
    }
};

fn elapsed(io: std.Io, start: std.Io.Timestamp) u64 {
    return @intCast(@max(0, start.durationTo(std.Io.Clock.awake.now(io)).nanoseconds));
}
fn wait(io: std.Io, device: wgpu.Device, done: *const bool) !void {
    const started = std.Io.Clock.awake.now(io);
    while (!done.*) {
        device.tick();
        if (elapsed(io, started) > 30 * std.time.ns_per_s) return error.GpuTimeout;
        if (!done.*) std.Thread.yield() catch {};
    }
}
fn complete(io: std.Io, gctx: *zgpu.GraphicsContext) !void {
    var response: Completion = .{};
    gctx.queue.onSubmittedWorkDone(0, Completion.callback, &response);
    try wait(io, gctx.device, &response.done);
    if (response.status != .success) return error.GpuCompletionFailed;
}

const TargetCell = struct { local: [3]u32, active: bool = true };
const Chunk = struct { coords: @Vector(3, i32), cells: std.ArrayList(TargetCell) = .empty, active_count: usize = 0 };
const Fixture = struct {
    chunks: std.ArrayList(Chunk) = .empty,
    ids: std.ArrayList(blueprint.ChunkId) = .empty,
    initial_targets: usize,
    offset: usize,

    fn init(allocator: std.mem.Allocator, targets: usize, offset: usize) !Fixture {
        // Exact 100x100x32 and 100x80x4 definitions retain realistic chunk-edge
        // occupancy, rather than treating every target as a separate draw.
        const size: [3]usize = if (targets == 320_000) .{ 100, 100, 32 } else if (targets == 32_000) .{ 100, 80, 4 } else return error.InvalidTargetCount;
        var self: Fixture = .{ .initial_targets = targets, .offset = offset };
        errdefer self.deinit(allocator);
        var cz: usize = 0;
        while (cz * 32 < size[2] + offset) : (cz += 1) {
            var cy: usize = 0;
            while (cy * 32 < size[1] + offset) : (cy += 1) {
                var cx: usize = 0;
                while (cx * 32 < size[0] + offset) : (cx += 1) {
                    try self.chunks.append(allocator, .{ .coords = .{ @intCast(2 + cx), @intCast(2 + cy), @intCast(2 + cz) } });
                    const chunk = &self.chunks.items[self.chunks.items.len - 1];
                    for ((if (cz == 0) offset else 0)..@min(32, size[2] + offset - cz * 32)) |z| for ((if (cy == 0) offset else 0)..@min(32, size[1] + offset - cy * 32)) |y| for ((if (cx == 0) offset else 0)..@min(32, size[0] + offset - cx * 32)) |x| {
                        try chunk.cells.append(allocator, .{ .local = .{ @intCast(x), @intCast(y), @intCast(z) } });
                    };
                    chunk.active_count = chunk.cells.items.len;
                    try self.ids.append(allocator, @intCast(self.ids.items.len));
                }
            }
        }
        var actual: usize = 0;
        for (self.chunks.items) |chunk| actual += chunk.cells.items.len;
        if (actual != targets) return error.InvalidFixture;
        return self;
    }
    fn deinit(self: *Fixture, allocator: std.mem.Allocator) void {
        for (self.chunks.items) |*chunk| chunk.cells.deinit(allocator);
        self.chunks.deinit(allocator);
        self.ids.deinit(allocator);
    }
    fn reset(self: *Fixture) void {
        for (self.chunks.items) |*chunk| {
            chunk.active_count = chunk.cells.items.len;
            for (chunk.cells.items) |*cell| cell.active = true;
        }
    }
    fn applyTrace(self: *Fixture, frame: usize, changed: usize) void {
        for (0..changed) |lane| {
            const chunk = &self.chunks.items[(frame + lane) % self.chunks.items.len];
            const cell = &chunk.cells.items[(frame * 131 + lane * 17) % chunk.cells.items.len];
            if (cell.active) {
                cell.active = false;
                chunk.active_count -= 1;
            }
        }
    }
};

const Offscreen = struct {
    color: wgpu.Texture,
    color_view: wgpu.TextureView,
    depth: wgpu.Texture,
    depth_view: wgpu.TextureView,
    readback: wgpu.Buffer,
    side: u32,
    fn init(device: wgpu.Device, side: u32) Offscreen {
        const extent: wgpu.Extent3D = .{ .width = side, .height = side, .depth_or_array_layers = 1 };
        const color = device.createTexture(.{ .size = extent, .format = .rgba8_unorm, .usage = .{ .render_attachment = true, .copy_src = true } });
        const depth = device.createTexture(.{ .size = extent, .format = .depth32_float, .usage = .{ .render_attachment = true } });
        return .{ .color = color, .color_view = color.createView(.{}), .depth = depth, .depth_view = depth.createView(.{}), .readback = device.createBuffer(.{ .size = @as(u64, side) * side * 4, .usage = .{ .copy_dst = true, .map_read = true } }), .side = side };
    }
    fn deinit(self: Offscreen) void {
        self.readback.release();
        self.depth_view.release();
        self.depth.release();
        self.color_view.release();
        self.color.release();
    }
    fn checksum(self: Offscreen, io: std.Io, gctx: *zgpu.GraphicsContext) !u64 {
        const encoder = gctx.device.createCommandEncoder(null);
        defer encoder.release();
        encoder.copyTextureToBuffer(.{ .texture = self.color }, .{ .buffer = self.readback, .layout = .{ .bytes_per_row = self.side * 4, .rows_per_image = self.side } }, .{ .width = self.side, .height = self.side, .depth_or_array_layers = 1 });
        const command = encoder.finish(null);
        defer command.release();
        gctx.queue.submit(&.{command});
        var mapping: Mapping = .{};
        self.readback.mapAsync(.{ .read = true }, 0, @as(u64, self.side) * self.side * 4, Mapping.callback, &mapping);
        defer self.readback.unmap();
        try wait(io, gctx.device, &mapping.done);
        if (mapping.status != .success) return error.ReadbackFailed;
        const pixels = self.readback.getConstMappedRange(u8, 0, @as(usize, self.side) * self.side * 4) orelse return error.ReadbackFailed;
        var colored: usize = 0;
        for (0..pixels.len / 4) |index| if (pixels[index * 4] != 0 or pixels[index * 4 + 1] != 0 or pixels[index * 4 + 2] != 0) {
            colored += 1;
        };
        if (colored == 0) return error.EmptyBenchmarkImage;
        return std.hash.Wyhash.hash(0, pixels);
    }
};

const Mode = enum { dynamic, cached };
const Scenario = enum { stationary, camera, one_changed, quarter_changed };
const Sample = struct { pack: u64 = 0, source: u64 = 0, draw: u64 = 0, cpu: u64 = 0, completion: u64 = 0, total: u64 = 0 };
const Percentiles = struct { p50: u64, p95: u64, p99: u64 };
const Report = struct {
    times: [6]Percentiles,
    upload_bytes: u64,
    scanned_cells: u64,
    cold_pack_upload_ns: u64,
    checksum: u64,
    draw_calls: u64,
};
const metric_names = .{ "pack", "source", "draw", "cpu", "completion", "total" };

fn statistics(allocator: std.mem.Allocator, samples: []const Sample) ![6]Percentiles {
    const values = try allocator.alloc(u64, samples.len);
    defer allocator.free(values);
    var result: [6]Percentiles = undefined;
    inline for (metric_names, 0..) |field, index| {
        for (samples, values) |sample, *value| value.* = @field(sample, field);
        std.mem.sort(u64, values, {}, std.sort.asc(u64));
        result[index] = .{ .p50 = values[(values.len - 1) * 50 / 100], .p95 = values[(values.len - 1) * 95 / 100], .p99 = values[(values.len - 1) * 99 / 100] };
    }
    return result;
}

fn cameraFor(layout: *const WorldLayout, frame: usize, motion: bool, origin_offset: usize) Camera {
    var camera = Camera.init(layout, 1);
    const offset: f32 = if (motion) @sin(@as(f32, @floatFromInt(frame)) * 0.065) * 20 else 0;
    const anchor: f32 = @floatFromInt(origin_offset);
    const dx: i32 = @intFromFloat(@floor((anchor + offset) / 32));
    camera.chunk = .{ 2 + dx, 2, 2 };
    const local = anchor + offset - @as(f32, @floatFromInt(dx)) * 32;
    camera.clip_from_world_chunked = zmath.identity();
    camera.clip_from_world_chunked[0] = .{ 0.016, 0, 0, 0 };
    camera.clip_from_world_chunked[1] = .{ 0, 0.018, 0, 0 };
    camera.clip_from_world_chunked[2] = .{ 0.002, 0.002, -0.008, 0 };
    camera.clip_from_world_chunked[3] = .{ -0.9 - local * 0.016 - anchor * 0.002, -0.9 - anchor * 0.02, 0.8 + anchor * 0.008, 1 };
    return camera;
}

fn packChunk(chunk: Chunk, source_cells: *std.ArrayList(blueprint.MiniatureCell)) void {
    source_cells.clearRetainingCapacity();
    for (chunk.cells.items) |cell| if (cell.active) {
        source_cells.appendAssumeCapacity(.{ .local = cell.local, .material = @intFromEnum(BlockType.planks) });
    };
}

fn run(io: std.Io, allocator: std.mem.Allocator, gctx: *zgpu.GraphicsContext, atlas_layout: zgpu.BindGroupLayoutHandle, atlas: wgpu.BindGroup, offscreen: Offscreen, fixture: *Fixture, mode: Mode, scenario: Scenario, frames: usize, warmup: usize) !Report {
    fixture.reset();
    const layout = try WorldLayout.init(.{ .size_in_chunks = .{ 64, 64, 64 } });
    var renderer = blueprint.Renderer.initWithAllocator(gctx, atlas_layout, .rgba8_unorm, allocator);
    defer renderer.deinit(gctx);
    var dynamic: std.ArrayList(blueprint.Instance) = .empty;
    defer dynamic.deinit(allocator);
    try dynamic.ensureTotalCapacityPrecise(allocator, fixture.initial_targets);
    var source_cells: std.ArrayList(blueprint.MiniatureCell) = .empty;
    defer source_cells.deinit(allocator);
    try source_cells.ensureTotalCapacityPrecise(allocator, 32 * 32 * 32);
    const samples = try allocator.alloc(Sample, frames);
    defer allocator.free(samples);
    const cold = std.Io.Clock.awake.now(io);
    if (mode == .cached) for (fixture.chunks.items, 0..) |chunk, id| {
        packChunk(chunk, &source_cells);
        var prepared = try renderer.prepareMiniatureChunk(gctx, @intCast(id), chunk.coords, 1, source_cells.items);
        renderer.commitMiniatureChunk(gctx, &prepared);
    };
    const cold_ns = if (mode == .cached) elapsed(io, cold) else 0;
    try complete(io, gctx);
    const changed = switch (scenario) {
        .stationary, .camera => @as(usize, 0),
        .one_changed => 1,
        .quarter_changed => (fixture.chunks.items.len + 3) / 4,
    };
    var upload_bytes: u64 = 0;
    var scanned_cells: u64 = 0;
    var draw_calls: u64 = 0;
    for (0..warmup + frames) |frame| {
        fixture.applyTrace(frame, changed);
        const camera = cameraFor(&layout, frame, scenario != .stationary, fixture.offset);
        var sample: Sample = .{};
        const started = std.Io.Clock.awake.now(io);
        if (mode == .dynamic) {
            const packing = std.Io.Clock.awake.now(io);
            dynamic.clearRetainingCapacity();
            for (fixture.chunks.items) |chunk| for (chunk.cells.items) |cell| if (cell.active) {
                const world: blueprint.Cell = @as(blueprint.Cell, chunk.coords) * @as(blueprint.Cell, @splat(32)) + blueprint.Cell{ cell.local[0], cell.local[1], cell.local[2] };
                dynamic.appendAssumeCapacity(blueprint.blockInstance(&camera, world, .planks, true, false));
            };
            sample.pack = elapsed(io, packing);
            if (frame >= warmup) {
                upload_bytes += dynamic.items.len * @sizeOf(blueprint.Instance);
                scanned_cells += fixture.initial_targets;
            }
        } else for (0..changed) |lane| {
            const id = (frame + lane) % fixture.chunks.items.len;
            const chunk = fixture.chunks.items[id];
            const packing = std.Io.Clock.awake.now(io);
            packChunk(chunk, &source_cells);
            sample.pack += elapsed(io, packing);
            const uploading = std.Io.Clock.awake.now(io);
            var prepared = try renderer.prepareMiniatureChunk(gctx, @intCast(id), chunk.coords, @intCast(frame + 2), source_cells.items);
            renderer.commitMiniatureChunk(gctx, &prepared);
            sample.source += elapsed(io, uploading);
            if (frame >= warmup) {
                upload_bytes += source_cells.items.len * @sizeOf(blueprint.MiniatureCell);
                scanned_cells += chunk.cells.items.len;
            }
        }
        const drawing = std.Io.Clock.awake.now(io);
        {
            const encoder = gctx.device.createCommandEncoder(null);
            defer encoder.release();
            const attachments = [_]wgpu.RenderPassColorAttachment{.{ .view = offscreen.color_view, .load_op = .clear, .store_op = .store, .clear_value = .{ .r = 0, .g = 0, .b = 0, .a = 1 } }};
            const pass = encoder.beginRenderPass(.{ .color_attachments = &attachments, .color_attachment_count = attachments.len, .depth_stencil_attachment = &.{ .view = offscreen.depth_view, .depth_load_op = .clear, .depth_store_op = .store, .depth_clear_value = 1 } });
            defer pass.release();
            switch (mode) {
                .dynamic => renderer.draw(gctx, pass, atlas, &camera, dynamic.items, null),
                .cached => try renderer.drawMiniatures(gctx, pass, atlas, &camera, fixture.ids.items, blueprint.capacity),
            }
            pass.end();
            const command = encoder.finish(null);
            defer command.release();
            gctx.queue.submit(&.{command});
        }
        sample.draw = elapsed(io, drawing);
        const waiting = std.Io.Clock.awake.now(io);
        try complete(io, gctx);
        sample.completion = elapsed(io, waiting);
        sample.total = elapsed(io, started);
        sample.cpu = sample.pack + sample.source + sample.draw;
        if (frame >= warmup) {
            samples[frame - warmup] = sample;
            if (mode == .dynamic) draw_calls += 1 else for (fixture.chunks.items) |chunk| {
                draw_calls += @intFromBool(chunk.active_count != 0);
            }
        }
    }
    return .{ .times = try statistics(allocator, samples), .upload_bytes = upload_bytes, .scanned_cells = scanned_cells, .cold_pack_upload_ns = cold_ns, .checksum = try offscreen.checksum(io, gctx), .draw_calls = draw_calls };
}

const Options = struct { frames: usize = 100, warmup: usize = 12, repeats: usize = 3, targets: ?usize = null, offset: usize = 0, scenario: ?Scenario = null };
fn options(init: std.process.Init) !Options {
    const args = try init.minimal.args.toSlice(init.arena.allocator());
    var result: Options = .{};
    var index: usize = 1;
    while (index < args.len) : (index += 1) {
        if (index + 1 == args.len) return error.InvalidArguments;
        if (std.mem.eql(u8, args[index], "--scenario")) {
            result.scenario = std.meta.stringToEnum(Scenario, args[index + 1]) orelse return error.InvalidArguments;
            index += 1;
            continue;
        }
        const value = try std.fmt.parseInt(usize, args[index + 1], 10);
        if (std.mem.eql(u8, args[index], "--frames")) result.frames = value else if (std.mem.eql(u8, args[index], "--warmup")) result.warmup = value else if (std.mem.eql(u8, args[index], "--repeats")) result.repeats = value else if (std.mem.eql(u8, args[index], "--targets")) result.targets = value else if (std.mem.eql(u8, args[index], "--offset")) result.offset = value else return error.InvalidArguments;
        index += 1;
    }
    if (result.frames == 0 or result.frames > 1000 or result.repeats == 0 or result.repeats > 9 or result.warmup > 1000 or result.offset > 31) return error.InvalidArguments;
    if (result.targets) |targets| if (targets != 32_000 and targets != 320_000) return error.InvalidTargetCount;
    return result;
}
fn ms(ns: u64) f64 {
    return @as(f64, @floatFromInt(ns)) / 1_000_000;
}

pub fn main(init: std.process.Init) !void {
    const config = try options(init);
    const gpu = try Gpu.init();
    defer gpu.deinit();
    var validation: Validation = .{};
    gpu.device.setUncapturedErrorCallback(Validation.callback, &validation);
    var gctx: zgpu.GraphicsContext = undefined;
    gctx.device = gpu.device;
    gctx.queue = gpu.device.getQueue();
    defer gctx.queue.release();
    const pools = .{ "buffer_pool", "bind_group_pool", "bind_group_layout_pool", "pipeline_layout_pool", "render_pipeline_pool" };
    inline for (pools) |name| @field(gctx, name) = .{ .pool = try @TypeOf(@field(gctx, name).pool).initCapacity(init.gpa, 256) };
    defer inline for (pools) |name| @field(gctx, name).pool.deinit();
    var atlas_layout = @import("bind_group_layouts/regular.zig").RegularBindGroupLayout.init(&gctx, .tvdim_2d);
    defer atlas_layout.deinit(&gctx);
    const atlas = gpu.device.createTexture(.{ .size = .{ .width = 1, .height = 1, .depth_or_array_layers = 1 }, .format = .rgba8_unorm, .usage = .{ .texture_binding = true, .copy_dst = true } });
    defer atlas.release();
    const atlas_view = atlas.createView(.{});
    defer atlas_view.release();
    const sampler = gpu.device.createSampler(.{});
    defer sampler.release();
    const entries = [_]wgpu.BindGroupEntry{ .{ .binding = 0, .texture_view = atlas_view, .size = 0 }, .{ .binding = 1, .sampler = sampler, .size = 0 } };
    const binding = gpu.device.createBindGroup(.{ .layout = gctx.lookupResource(atlas_layout.bind_group_layout_handle).?, .entries = &entries, .entry_count = entries.len });
    defer binding.release();
    gctx.queue.writeTexture(.{ .texture = atlas }, .{ .bytes_per_row = 4, .rows_per_image = 1 }, .{ .width = 1, .height = 1, .depth_or_array_layers = 1 }, u8, &.{ 255, 255, 255, 255 });
    const offscreen = Offscreen.init(gpu.device, 256);
    defer offscreen.deinit();
    std.debug.print("offscreen=256x256 frames={d} warmup={d} repeats={d} origin_offset_xyz={d}; serialized completion fence each frame; no window/present; no world hash lookups, terrain, rails, UI, queue scheduling or deferred publication\n", .{ config.frames, config.warmup, config.repeats, config.offset });
    std.debug.print("pack=synthetic grouped target scan+coordinate packing; source=cache prepare/upload/commit calls; draw=production source/uniform uploads+encode+submit; completion=wall wait, NOT GPU timestamp; total=serialized component wall\n", .{});
    for ([_]usize{ 32_000, 320_000 }) |targets| {
        if (config.targets != null and config.targets.? != targets) continue;
        var fixture = try Fixture.init(init.gpa, targets, config.offset);
        defer fixture.deinit(init.gpa);
        for (std.enums.values(Scenario)) |scenario| {
            if (config.scenario != null and config.scenario.? != scenario) continue;
            var reports: [2][9]Report = undefined;
            for (0..config.repeats) |repeat| {
                for (0..2) |order| {
                    const mode: Mode = @enumFromInt((order + repeat) % 2);
                    const report = try run(init.io, init.gpa, &gctx, atlas_layout.bind_group_layout_handle, binding, offscreen, &fixture, mode, scenario, config.frames, config.warmup);
                    reports[@intFromEnum(mode)][repeat] = report;
                    std.debug.print("sample targets={d} chunks={d} offset={d} scenario={s} mode={s} repeat={d} cpu_p50_ms={d:.4} cpu_p95_ms={d:.4} total_p50_ms={d:.4} total_p95_ms={d:.4} checksum={x}\n", .{ targets, fixture.chunks.items.len, config.offset, @tagName(scenario), @tagName(mode), repeat, ms(report.times[3].p50), ms(report.times[3].p95), ms(report.times[5].p50), ms(report.times[5].p95), report.checksum });
                }
                if (reports[0][repeat].checksum != reports[1][repeat].checksum) return error.DynamicCachedImageMismatch;
            }
            for (std.enums.values(Mode)) |mode| {
                const selected = reports[@intFromEnum(mode)][0..config.repeats];
                const draws = selected[0].draw_calls / config.frames;
                var cold_values: [9]u64 = undefined;
                for (selected, 0..) |report, index| cold_values[index] = report.cold_pack_upload_ns;
                std.mem.sort(u64, cold_values[0..config.repeats], {}, std.sort.asc(u64));
                std.debug.print("summary targets={d} chunks={d} offset={d} scenario={s} mode={s} source_bytes/frame={d} scanned_cells/frame={d} draws/frame={d} uniform_bytes/frame={d} cold_cache_seed_ms={d:.4}", .{ targets, fixture.chunks.items.len, config.offset, @tagName(scenario), @tagName(mode), selected[0].upload_bytes / config.frames, selected[0].scanned_cells / config.frames, draws, draws * 128, ms(cold_values[config.repeats / 2]) });
                inline for (metric_names, 0..) |metric, metric_index| {
                    inline for (.{ "p50", "p95", "p99" }) |percentile| {
                        var values: [9]u64 = undefined;
                        for (selected, 0..) |report, index| values[index] = @field(report.times[metric_index], percentile);
                        std.mem.sort(u64, values[0..config.repeats], {}, std.sort.asc(u64));
                        std.debug.print(" {s}_{s}_ms={d:.4}", .{ metric, percentile, ms(values[config.repeats / 2]) });
                    }
                }
                std.debug.print("\n", .{});
            }
        }
    }
    if (validation.errors != 0) return error.GpuValidationFailed;
}
