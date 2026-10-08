//! Optional headless Dawn validation; run with `zig build test-gpu`.
const std = @import("std");
const zgpu = @import("zgpu");
const wgpu = zgpu.wgpu;
const WorldLayout = @import("world_layout.zig").WorldLayout;
const WorldPipelines = @import("pipelines.zig").WorldPipelines;
const WorldPipelineCache = @import("world_pipeline_cache.zig").WorldPipelineCache;
const layouts_module = @import("bind_group_layouts.zig");
const coordinate_readback = @import("world_coordinate_readback.zig");

// Dawn's native entry points, also used by zgpu.GraphicsContext.create.
extern fn dniCreate() ?*anyopaque;
extern fn dniDestroy(instance: ?*anyopaque) void;
extern fn dniGetWgpuInstance(instance: ?*anyopaque) ?wgpu.Instance;
extern fn dnGetProcs() ?*anyopaque;
extern fn dawnProcSetProcs(procs: ?*anyopaque) void;

const AdapterResponse = struct {
    status: wgpu.RequestAdapterStatus = .unknown,
    adapter: ?wgpu.Adapter = null,

    fn callback(status: wgpu.RequestAdapterStatus, adapter: wgpu.Adapter, message: ?[*:0]const u8, userdata: ?*anyopaque) callconv(.c) void {
        const self: *AdapterResponse = @ptrCast(@alignCast(userdata));
        self.status = status;
        if (status == .success) self.adapter = adapter else if (message) |msg| std.debug.print("Dawn adapter: {s}\n", .{msg});
    }
};

const DeviceResponse = struct {
    status: wgpu.RequestDeviceStatus = .unknown,
    device: ?wgpu.Device = null,

    fn callback(status: wgpu.RequestDeviceStatus, device: wgpu.Device, message: ?[*:0]const u8, userdata: ?*anyopaque) callconv(.c) void {
        const self: *DeviceResponse = @ptrCast(@alignCast(userdata));
        self.status = status;
        if (status == .success) self.device = device else if (message) |msg| std.debug.print("Dawn device: {s}\n", .{msg});
    }
};

const ValidationResponse = struct {
    done: bool = false,
    errors: usize = 0,

    fn callback(kind: wgpu.ErrorType, message: ?[*:0]const u8, userdata: ?*anyopaque) callconv(.c) void {
        const self: *ValidationResponse = @ptrCast(@alignCast(userdata));
        self.done = true;
        if (kind != .no_error) {
            self.errors += 1;
            std.debug.print("Dawn validation ({s}): {s}\n", .{ @tagName(kind), message orelse "unknown" });
        }
    }
};

const HeadlessDawn = struct {
    native: *anyopaque,
    adapter: wgpu.Adapter,
    device: wgpu.Device,

    fn init() !HeadlessDawn {
        dawnProcSetProcs(dnGetProcs());
        const native = dniCreate() orelse return error.NoGraphicsInstance;
        errdefer dniDestroy(native);
        const instance = dniGetWgpuInstance(native) orelse return error.NoGraphicsInstance;
        var adapter_response: AdapterResponse = .{};
        instance.requestAdapter(.{ .power_preference = .high_performance, .backend_type = if (@import("builtin").os.tag == .macos) .metal else .undef }, AdapterResponse.callback, &adapter_response);
        const adapter = adapter_response.adapter orelse return error.NoGraphicsAdapter;
        errdefer adapter.release();
        var properties: wgpu.AdapterProperties = undefined;
        properties.next_in_chain = null;
        adapter.getProperties(&properties);
        if (properties.backend_type == .nul) return error.NoGraphicsAdapter;
        std.debug.print("Dawn adapter: {s} ({s})\n", .{ properties.name, @tagName(properties.backend_type) });
        var device_response: DeviceResponse = .{};
        adapter.requestDevice(.{}, DeviceResponse.callback, &device_response);
        const device = device_response.device orelse return error.NoGraphicsDevice;
        return .{ .native = native, .adapter = adapter, .device = device };
    }

    fn deinit(self: HeadlessDawn) void {
        self.device.destroy();
        self.device.release();
        self.adapter.release();
        dniDestroy(self.native);
    }
};

test "Dawn validates world pipeline sharing, lifetimes, and allocation cleanup" {
    const allocator = std.testing.allocator;
    var uncaptured: ValidationResponse = .{};
    const gpu = try HeadlessDawn.init();
    defer gpu.deinit();
    const device = gpu.device;
    device.setUncapturedErrorCallback(ValidationResponse.callback, &uncaptured);

    // Pipeline creation only needs these three pools, with no window/swapchain.
    var gctx: zgpu.GraphicsContext = undefined;
    gctx.device = device;
    gctx.bind_group_layout_pool = .{ .pool = try @TypeOf(gctx.bind_group_layout_pool.pool).initCapacity(allocator, 16) };
    defer gctx.bind_group_layout_pool.pool.deinit();
    gctx.pipeline_layout_pool = .{ .pool = try @TypeOf(gctx.pipeline_layout_pool.pool).initCapacity(allocator, 16) };
    defer gctx.pipeline_layout_pool.pool.deinit();
    gctx.render_pipeline_pool = .{ .pool = try @TypeOf(gctx.render_pipeline_pool.pool).initCapacity(allocator, 128) };
    defer gctx.render_pipeline_pool.pool.deinit();
    var layouts: layouts_module.BindGroupLayouts = undefined;
    layouts.scene = .init(&gctx);
    defer layouts.scene.deinit(&gctx);
    layouts.regular = .init(&gctx, .tvdim_2d);
    defer layouts.regular.deinit(&gctx);
    layouts.joints = .init(&gctx);
    defer layouts.joints.deinit(&gctx);
    layouts.shadow_map = .init(&gctx);
    defer layouts.shadow_map.deinit(&gctx);
    layouts.voxel = .init(&gctx);
    defer layouts.voxel.deinit(&gctx);

    for ([_][3]u32{ .{ 512, 256, 8 }, .{ 128, 64, 16 } }) |size| {
        const layout = try WorldLayout.init(.{ .size_in_chunks = size });
        device.pushErrorScope(.validation);
        var pipelines = try WorldPipelines.init(allocator, &gctx, &layouts, &layout);
        defer pipelines.deinit(&gctx);
        var response: ValidationResponse = .{};
        _ = device.popErrorScope(ValidationResponse.callback, &response);
        for (0..10000) |_| {
            if (response.done) break;
            device.tick();
        }
        try std.testing.expect(response.done);
        try std.testing.expectEqual(@as(usize, 0), response.errors);
    }

    device.pushErrorScope(.validation);
    try checkCompatibleLayouts(&gctx, &layouts);
    try checkCacheGrowth(&gctx, &layouts);
    try checkCacheHitWithoutAllocation(&gctx, &layouts);
    try std.testing.checkAllAllocationFailures(allocator, checkAllocationCleanup, .{ &gctx, &layouts });
    var response: ValidationResponse = .{};
    _ = device.popErrorScope(ValidationResponse.callback, &response);
    for (0..10000) |_| {
        if (response.done) break;
        device.tick();
    }
    try std.testing.expect(response.done);
    try std.testing.expectEqual(@as(usize, 0), response.errors);
    try std.testing.expectEqual(@as(usize, 0), uncaptured.errors);
}

test "GPU coordinate readback agrees with CPU at seams, precision boundaries, and signed limits" {
    // Callback state outlives the device, including cancellation on a timeout.
    var uncaptured: ValidationResponse = .{};
    var validation: ValidationResponse = .{};
    var mapping: coordinate_readback.MapResponse = .{};
    const gpu = try HeadlessDawn.init();
    defer gpu.deinit();
    gpu.device.setUncapturedErrorCallback(ValidationResponse.callback, &uncaptured);
    for ([_]u32{ 128, 512, 1 << 26 }) |width| {
        const layout = try WorldLayout.init(.{ .size_in_chunks = .{ width, 2, 2 } });
        gpu.device.pushErrorScope(.validation);
        const checked = coordinate_readback.check(gpu.device, &layout, &mapping);
        validation = .{};
        _ = gpu.device.popErrorScope(ValidationResponse.callback, &validation);
        try coordinate_readback.waitForCallback(gpu.device, &validation.done);
        try std.testing.expectEqual(@as(usize, 0), validation.errors);
        try checked;
    }
    try std.testing.expectEqual(@as(usize, 0), uncaptured.errors);
}

fn expectPipelineHandles(gctx: *zgpu.GraphicsContext, pipelines: WorldPipelines, valid: bool) !void {
    inline for (std.meta.fields(WorldPipelines)) |field| {
        try std.testing.expectEqual(valid, gctx.isResourceValid(@field(pipelines, field.name).pipeline_handle));
    }
}

fn checkCompatibleLayouts(gctx: *zgpu.GraphicsContext, layouts: *const layouts_module.BindGroupLayouts) !void {
    var cache = WorldPipelineCache.init(std.testing.allocator, gctx);
    defer cache.deinit();
    const a = try WorldLayout.init(.{ .size_in_chunks = .{ 512, 256, 8 } });
    const b = try WorldLayout.init(.{ .size_in_chunks = .{ 512, 64, 16 } });
    const c = try WorldLayout.init(.{ .size_in_chunks = .{ 128, 64, 16 } });
    var released_handles: WorldPipelines = undefined;
    {
        const first = try cache.acquire(layouts, &a);
        defer cache.release(first);
        released_handles = first.*;
        {
            const same = try cache.acquire(layouts, &a);
            defer cache.release(same);
            const different_yz = try cache.acquire(layouts, &b);
            defer cache.release(different_yz);
            const different_x = try cache.acquire(layouts, &c);
            defer cache.release(different_x);
            try std.testing.expect(first == same);
            try std.testing.expect(first == different_yz);
            try std.testing.expectEqual(!WorldLayout.wrap_x, first == different_x);
            try std.testing.expectEqual(@as(usize, if (WorldLayout.wrap_x) 12 else 6), gctx.render_pipeline_pool.pool.liveHandleCount());
        }
        // Other scenes released their references; this scene can still render.
        try expectPipelineHandles(gctx, first.*, true);
        try std.testing.expectEqual(@as(usize, 6), gctx.render_pipeline_pool.pool.liveHandleCount());
    }
    try expectPipelineHandles(gctx, released_handles, false);
    try std.testing.expectEqual(@as(usize, 0), gctx.render_pipeline_pool.pool.liveHandleCount());
    try std.testing.expectEqual(@as(u32, 0), cache.entries.count());

    // No idle retention: a later scene constructs a new live set.
    const recreated = try cache.acquire(layouts, &a);
    defer cache.release(recreated);
    try expectPipelineHandles(gctx, recreated.*, true);
    try expectPipelineHandles(gctx, released_handles, false);
}

fn checkCacheGrowth(gctx: *zgpu.GraphicsContext, layouts: *const layouts_module.BindGroupLayouts) !void {
    var cache = WorldPipelineCache.init(std.testing.allocator, gctx);
    defer cache.deinit();
    var handles: [16]WorldPipelines = undefined;
    {
        var borrowed: [handles.len]*const WorldPipelines = undefined;
        var count: usize = 0;
        defer for (borrowed[0..count]) |pipelines| cache.release(pipelines);
        var initial_capacity: u32 = 0;
        for (0..borrowed.len) |i| {
            const layout = try WorldLayout.init(.{ .size_in_chunks = .{ @as(u32, 2) << @as(u5, @intCast(i)), 2, 2 } });
            borrowed[i] = try cache.acquire(layouts, &layout);
            count += 1;
            handles[i] = borrowed[i].*;
            if (i == 0) initial_capacity = cache.entries.capacity();
        }
        try std.testing.expectEqual(@as(u32, if (WorldLayout.wrap_x) 16 else 1), cache.entries.count());
        if (comptime WorldLayout.wrap_x) try std.testing.expect(cache.entries.capacity() > initial_capacity);

        // Reacquire after growth and verify all original scene pointers and handles.
        for (borrowed, 0..) |original, i| {
            const layout = try WorldLayout.init(.{ .size_in_chunks = .{ @as(u32, 2) << @as(u5, @intCast(i)), 4, 4 } });
            const acquired = try cache.acquire(layouts, &layout);
            defer cache.release(acquired);
            try std.testing.expect(original == acquired);
            try std.testing.expectEqualDeep(handles[i], original.*);
            try expectPipelineHandles(gctx, original.*, true);
        }
    }
    for (handles) |released| try expectPipelineHandles(gctx, released, false);
    try std.testing.expectEqual(@as(usize, 0), gctx.render_pipeline_pool.pool.liveHandleCount());
}

fn checkAllocationCleanup(allocator: std.mem.Allocator, gctx: *zgpu.GraphicsContext, layouts: *const layouts_module.BindGroupLayouts) !void {
    var cache = WorldPipelineCache.init(allocator, gctx);
    defer cache.deinit();
    // Also checked on errors after any of the six shader-source allocations.
    defer std.debug.assert(gctx.render_pipeline_pool.pool.liveHandleCount() == 0);
    defer std.debug.assert(gctx.pipeline_layout_pool.pool.liveHandleCount() == 0);
    const layout = try WorldLayout.init(.{ .size_in_chunks = .{ 512, 256, 8 } });
    const pipelines = try cache.acquire(layouts, &layout);
    defer cache.release(pipelines);

    const shared = try cache.acquire(layouts, &layout);
    defer cache.release(shared);
    try std.testing.expect(shared == pipelines);

    // A failed miss must preserve the existing borrowed set and release every
    // partially constructed pipeline before returning the allocation error.
    {
        defer std.debug.assert(gctx.render_pipeline_pool.pool.liveHandleCount() == 6);
        defer inline for (std.meta.fields(WorldPipelines)) |field| {
            std.debug.assert(gctx.isResourceValid(@field(pipelines, field.name).pipeline_handle));
        };
        const different = try WorldLayout.init(.{ .size_in_chunks = .{ 128, 64, 16 } });
        const other = try cache.acquire(layouts, &different);
        defer cache.release(other);
    }
}

fn checkCacheHitWithoutAllocation(gctx: *zgpu.GraphicsContext, layouts: *const layouts_module.BindGroupLayouts) !void {
    var failing = std.testing.FailingAllocator.init(std.testing.allocator, .{});
    var cache = WorldPipelineCache.init(failing.allocator(), gctx);
    defer cache.deinit();
    const layout = try WorldLayout.init(.{ .size_in_chunks = .{ 512, 256, 8 } });
    const first = try cache.acquire(layouts, &layout);
    defer cache.release(first);
    failing.fail_index = failing.alloc_index;
    const shared = try cache.acquire(layouts, &layout);
    defer cache.release(shared);
    try std.testing.expect(first == shared);
    try std.testing.expect(!failing.has_induced_failure);
}
