//! Optional headless Dawn validation; run with `zig build test-gpu`.
const std = @import("std");
const zgpu = @import("zgpu");
const wgpu = zgpu.wgpu;
const WorldLayout = @import("world_layout.zig").WorldLayout;
const WorldPipelines = @import("pipelines.zig").WorldPipelines;
const layouts_module = @import("bind_group_layouts.zig");

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

test "Dawn validates all six world pipelines for the compiled wrapping mode" {
    const allocator = std.testing.allocator;
    dawnProcSetProcs(dnGetProcs());
    const native = dniCreate() orelse return error.NoGraphicsInstance;
    defer dniDestroy(native);
    const instance = dniGetWgpuInstance(native) orelse return error.NoGraphicsInstance;
    var adapter_response: AdapterResponse = .{};
    instance.requestAdapter(.{ .power_preference = .high_performance, .backend_type = if (@import("builtin").os.tag == .macos) .metal else .undef }, AdapterResponse.callback, &adapter_response);
    const adapter = adapter_response.adapter orelse return error.NoGraphicsAdapter;
    defer adapter.release();
    var properties: wgpu.AdapterProperties = undefined;
    properties.next_in_chain = null;
    adapter.getProperties(&properties);
    if (properties.backend_type == .nul) return error.NoGraphicsAdapter;
    std.debug.print("Dawn adapter: {s} ({s})\n", .{ properties.name, @tagName(properties.backend_type) });
    var device_response: DeviceResponse = .{};
    adapter.requestDevice(.{}, DeviceResponse.callback, &device_response);
    const device = device_response.device orelse return error.NoGraphicsDevice;
    defer device.release();
    var uncaptured: ValidationResponse = .{};
    device.setUncapturedErrorCallback(ValidationResponse.callback, &uncaptured);

    // Pipeline creation only needs these three pools, with no window/swapchain.
    var gctx: zgpu.GraphicsContext = undefined;
    gctx.device = device;
    gctx.bind_group_layout_pool = .{ .pool = try @TypeOf(gctx.bind_group_layout_pool.pool).initCapacity(allocator, 16) };
    defer gctx.bind_group_layout_pool.pool.deinit();
    gctx.pipeline_layout_pool = .{ .pool = try @TypeOf(gctx.pipeline_layout_pool.pool).initCapacity(allocator, 16) };
    defer gctx.pipeline_layout_pool.pool.deinit();
    gctx.render_pipeline_pool = .{ .pool = try @TypeOf(gctx.render_pipeline_pool.pool).initCapacity(allocator, 16) };
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
    try std.testing.expectEqual(@as(usize, 0), uncaptured.errors);
}
