const std = @import("std");
const zgpu = @import("zgpu");
const WorldLayout = @import("world_layout.zig").WorldLayout;
const WorldPipelines = @import("pipelines.zig").WorldPipelines;
const BindGroupLayouts = @import("bind_group_layouts.zig").BindGroupLayouts;

/// Engine-owned sharing for its device and fixed bind-group layouts.
/// Accessed on the application thread; scenes must release before engine teardown.
pub const WorldPipelineCache = struct {
    const Entry = struct {
        key: u32,
        references: usize,
        pipelines: WorldPipelines,
    };

    allocator: std.mem.Allocator,
    gctx: *zgpu.GraphicsContext,
    entries: std.AutoHashMap(u32, *Entry),

    pub fn init(allocator: std.mem.Allocator, gctx: *zgpu.GraphicsContext) WorldPipelineCache {
        return .{
            .allocator = allocator,
            .gctx = gctx,
            .entries = .init(allocator),
        };
    }

    pub fn deinit(self: *WorldPipelineCache) void {
        // The final scene reference releases each set, so no GPU resources remain.
        std.debug.assert(self.entries.count() == 0);
        self.entries.deinit();
    }

    /// Acquire one scene reference, constructing shaders only on a cache miss.
    pub fn acquire(self: *WorldPipelineCache, bind_group_layouts: *const BindGroupLayouts, layout: *const WorldLayout) !*const WorldPipelines {
        // Unwrapped shaders ignore dimensions; wrapped shaders use only x width.
        const key: u32 = if (comptime WorldLayout.wrap_x) @intCast(layout.size_in_chunks[0]) else 0;
        if (self.entries.get(key)) |entry| {
            entry.references += 1;
            return &entry.pipelines;
        }

        // Reserve before creating GPU resources; insertion then cannot fail.
        try self.entries.ensureUnusedCapacity(1);
        const entry = try self.allocator.create(Entry);
        errdefer self.allocator.destroy(entry);
        entry.* = .{
            .key = key,
            .references = 1,
            .pipelines = try WorldPipelines.init(self.allocator, self.gctx, bind_group_layouts, layout),
        };
        self.entries.putAssumeCapacityNoClobber(key, entry);
        // Heap entries keep scene pointers stable when the map grows.
        return &entry.pipelines;
    }

    /// Release exactly one acquired reference. Evict on the last release.
    pub fn release(self: *WorldPipelineCache, pipelines: *const WorldPipelines) void {
        const entry: *Entry = @fieldParentPtr("pipelines", @constCast(pipelines));
        std.debug.assert(self.entries.get(entry.key).? == entry);
        std.debug.assert(entry.references > 0);
        entry.references -= 1;
        if (entry.references != 0) return;

        const removed = self.entries.remove(entry.key);
        std.debug.assert(removed);
        entry.pipelines.deinit(self.gctx);
        self.allocator.destroy(entry);
    }
};
