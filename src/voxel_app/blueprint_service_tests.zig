//! Public service acceptance fixtures for blueprint publication, application,
//! coalesced progress, and software restart. Storage fault models cover power loss.
const std = @import("std");
const engine = @import("engine");
const service_api = @import("world_data_service.zig");
const blueprint = @import("blueprint.zig");
const runtime = @import("blueprint_runtime.zig");
const world = @import("world.zig");
const format = @import("persistence/format.zig");
const storage = @import("persistence/storage.zig");
const persistence = @import("persistence/coordinator.zig");
const wire = @import("persistence/blueprints.zig");
const a = std.testing.allocator;
const io = std.testing.io;
const origin: [3]u32 = .{ 40, 40, 48 };

fn deadline() i96 {
    return persistence.now(io) + 10 * std.time.ns_per_s;
}
fn pause() !void {
    try std.Io.sleep(io, .fromMilliseconds(1), .awake);
}

const Harness = struct {
    path: [:0]u8,
    layout: engine.WorldLayout,
    store: storage.Store,
    store_open: bool = false,
    service: ?*service_api.WorldDataService = null,
    client: ?*service_api.Client = null,
    local: world.World,
    operation_results: std.ArrayList(service_api.OperationResult) = .empty,
    blueprint_results: std.ArrayList(service_api.BlueprintResult) = .empty,
    fill_packages: usize = 0,
    fill_snapshots: usize = 0,

    fn create() !*Harness {
        const self = try a.create(Harness);
        errdefer a.destroy(self);
        var uuid: [16]u8 = undefined;
        std.c.arc4random_buf(&uuid, uuid.len);
        const path = try std.fmt.allocPrintSentinel(a, "/private/tmp/blueprint-service-{x}", .{uuid}, 0);
        errdefer a.free(path);
        const layout = try engine.WorldLayout.init(.{ .size_in_chunks = .{ 4, 4, 4 } });
        const descriptor = try format.encodeDescriptor(a, .{ .dimensions = .{ 4, 4, 4 }, .generator_id = 2, .seed = 0, .settings = &format.flat_settings });
        defer a.free(descriptor);
        const tick = format.encodeGlobal(0);
        var store = try storage.Store.create(a, path, .{ .world_uuid = uuid, .descriptor = descriptor, .global = &tick, .players = &.{}, .player_count = 0 }, .{});
        errdefer store.deinit();
        const local = try world.World.init(a, &layout);
        self.* = .{ .path = path, .layout = layout, .store = store, .store_open = true, .local = local };
        errdefer self.local.deinit();
        try self.start();
        return self;
    }
    fn start(self: *Harness) !void {
        self.service = try service_api.WorldDataService.createPersistent(io, a, &self.layout, .flat, &self.store, .{});
        errdefer {
            self.service.?.destroy();
            self.service = null;
        }
        self.client = try self.service.?.createClient();
        self.client.?.publishCheckpoint(.{ .id = 1, .feet = .{ 40.5, 40.5, 48 }, .yaw = 0, .pitch = 0 });
        _ = try self.client.?.tryRequestChunksInMode(.{ 1, 1 }, 1, 2, .blocks);
        const end = deadline();
        while (persistence.now(io) < end) {
            try self.pump();
            if (self.local.hasChunk(.{ 1, 1, 1 })) return;
            try pause();
        }
        return error.TestLoadTimeout;
    }
    fn destroy(self: *Harness) void {
        if (self.service) |service| service.destroy();
        self.local.deinit();
        if (self.store_open) self.store.deinit();
        self.operation_results.deinit(a);
        self.blueprint_results.deinit(a);
        std.Io.Dir.cwd().deleteTree(io, self.path) catch {};
        a.free(self.path);
        a.destroy(self);
    }
    fn pump(self: *Harness) !void {
        var packages: std.ArrayList(service_api.ResponsePackage) = .empty;
        defer {
            for (packages.items) |*package| package.deinit(a);
            packages.deinit(a);
        }
        self.client.?.takePackages(&packages);
        for (packages.items) |*package| {
            var has_fill = false;
            var block_count: usize = 0;
            for (package.blueprint_changes.items) |change| if (change == .fulfill) {
                has_fill = true;
            };
            try self.local.applyBlueprintChanges(package.blueprint_changes.items);
            for (package.responses.items) |response| if (response.operation) |result| {
                self.local.acknowledgeOperationResult(result.request_id, result.status);
                try self.operation_results.append(a, result);
            };
            for (package.responses.items) |response| if (response.data == .blocks) {
                const copy = try response.data.blocks.chunk.tryClone(a);
                self.local.insertChunk(response.coords, copy) catch |err| {
                    copy.deinit(a);
                    if (err != error.StaleChunk) return err;
                };
                block_count += 1;
            };
            if (has_fill) {
                var block_ids: std.AutoHashMapUnmanaged(u32, void) = .empty;
                defer block_ids.deinit(a);
                for (package.responses.items) |response| if (response.data == .blocks) {
                    const id = self.layout.encodeChunkCoords(response.coords);
                    try std.testing.expect(!block_ids.contains(id));
                    try block_ids.put(a, id, {});
                };
                self.fill_packages += 1;
                self.fill_snapshots += block_count;
            }
        }
        var results: std.ArrayList(service_api.BlueprintResult) = .empty;
        defer results.deinit(a);
        self.client.?.takeBlueprintResults(&results);
        try self.blueprint_results.appendSlice(a, results.items);
    }
    fn waitBlueprint(self: *Harness, id: u64) !service_api.BlueprintResult {
        const end = deadline();
        while (persistence.now(io) < end) {
            try self.pump();
            for (self.blueprint_results.items) |result| if (result.request_id == id) return result;
            try pause();
        }
        return error.TestBlueprintTimeout;
    }
    fn waitOperation(self: *Harness, id: u64) !service_api.OperationResult {
        const end = deadline();
        while (persistence.now(io) < end) {
            try self.pump();
            for (self.operation_results.items) |result| if (result.request_id == id) return result;
            try pause();
        }
        return error.TestOperationTimeout;
    }
    fn edit(self: *Harness, operation: world.BlockOperation) !service_api.OperationResult {
        return self.waitOperation(try self.client.?.trySubmitOperation(operation));
    }
    fn publish(self: *Harness, size: blueprint.Size, cells: []const blueprint.BlockType, name: []const u8) !u64 {
        const result = try blueprint.compile(a, .{ .size = size, .cells = cells }, .{ .horizontal_limit = blueprint.horizontalLimit(&self.layout) });
        if (result != .valid) return error.TestInvalidBlueprint;
        var candidate = result.valid;
        const request = self.client.?.trySaveBlueprint(1, name, &candidate) catch |err| {
            candidate.deinit(a);
            return err;
        };
        const reply = try self.waitBlueprint(request);
        try std.testing.expectEqual(.success, reply.status);
        const id = reply.definition_id.?;
        const end = deadline();
        while (persistence.now(io) < end) {
            try self.pump();
            if (self.local.blueprints.definitions.contains(id)) return id;
            try pause();
        }
        return error.TestLibraryTimeout;
    }
    fn apply(self: *Harness, owner: u64, id: u64, at: [3]u32, rotation: u2) !service_api.BlueprintResult {
        return self.waitBlueprint(try self.client.?.tryApplyBlueprint(owner, id, at, rotation));
    }
    fn waitInstance(self: *Harness, id: u64) !void {
        const end = deadline();
        while (persistence.now(io) < end) {
            try self.pump();
            if (self.local.blueprints.instances.contains(id)) return;
            try pause();
        }
        return error.TestInstanceTimeout;
    }
    fn save(self: *Harness) !void {
        try self.waitSave(self.service.?.requestSave(false));
    }
    fn waitSave(self: *Harness, intent: u64) !void {
        const end = deadline();
        while (persistence.now(io) < end) {
            try self.pump();
            const status = self.service.?.persistenceStatus();
            if (status.intent_id == intent and !status.active and (status.phase == .complete or status.phase == .failed)) {
                try std.testing.expectEqual(persistence.Phase.complete, status.phase);
                try std.testing.expectEqual(status.target_sequence, status.durable_sequence);
                return;
            }
            try pause();
        }
        return error.TestSaveTimeout;
    }
    fn restart(self: *Harness) !void {
        self.service.?.destroy();
        self.service = null;
        self.client = null;
        self.store.deinit();
        self.store_open = false;
        self.store = try storage.Store.open(a, self.path, .{});
        self.store_open = true;
        self.local.deinit();
        self.local = try world.World.init(a, &self.layout);
        self.operation_results.clearRetainingCapacity();
        self.blueprint_results.clearRetainingCapacity();
        try self.start();
    }
};

test "Save and final Save include an earlier unresolved blueprint application" {
    for ([_]bool{ false, true }) |final| {
        const f = try Harness.create();
        defer f.destroy();
        const id = try f.publish(.{ 1, 1, 1 }, &.{.planks}, "Save application fence");
        const request = try f.client.?.tryApplyBlueprint(1, id, origin, 0);
        const intent = f.service.?.requestSave(final);
        try f.waitSave(intent);
        const applied = try f.waitBlueprint(request);
        try std.testing.expectEqual(.success, applied.status);
        const instance = applied.instance_id.?;
        try f.restart();
        try f.waitInstance(instance);
        try std.testing.expectEqual(@as(u32, 1), f.local.blueprints.instances.get(instance).?.remaining);
    }
}

const ReadGate = struct {
    entered: std.Io.Event = .unset,
    released: std.Io.Event = .unset,

    fn hook(context: ?*anyopaque, operation: @import("persistence/io.zig").Operation) void {
        if (operation != .read) return;
        const self: *@This() = @ptrCast(@alignCast(context.?));
        self.entered.set(io);
        self.released.waitUncancelable(io);
    }
};

test "Save and final Save wait for a queued blueprint application to finish admission" {
    for ([_]bool{ false, true }) |final| {
        const f = try Harness.create();
        defer f.destroy();
        const id = try f.publish(.{ 1, 1, 1 }, &.{.planks}, "Queued application fence");
        const distant: [3]u32 = .{ 80, 80, 48 };
        try std.testing.expectEqual(world.OperationStatus.success, (try f.edit(.{ .block = distant, .action = .{ .put = .planks } })).status);
        try f.waitSave(f.service.?.requestSave(true));
        f.service.?.destroy();
        f.service = null;
        f.client = null;
        f.local.deinit();
        f.local = try world.World.init(a, &f.layout);
        f.operation_results.clearRetainingCapacity();
        f.blueprint_results.clearRetainingCapacity();
        var gate: ReadGate = .{};
        defer gate.released.set(io);
        var faults: @import("persistence/io.zig").Faults = .{ .enabled = false, .context = &gate, .hook = ReadGate.hook };
        f.store.setFaults(&faults);
        try f.start();
        const edit = try f.client.?.trySubmitOperation(.{ .block = distant, .action = .remove });
        try gate.entered.waitTimeout(io, .{ .duration = .{ .raw = .fromSeconds(5), .clock = .awake } });
        const request = try f.client.?.tryApplyBlueprint(1, id, origin, 0);
        const intent = f.service.?.requestSave(final);
        gate.released.set(io);
        try std.testing.expectEqual(world.OperationStatus.success, (try f.waitOperation(edit)).status);
        try f.waitSave(intent);
        const applied = try f.waitBlueprint(request);
        try std.testing.expectEqual(.success, applied.status);
        f.store.setFaults(null);
        try f.restart();
        try f.waitInstance(applied.instance_id.?);
    }
}

test "public blueprint publication application identity and atomic player fulfillment" {
    const f = try Harness.create();
    defer f.destroy();
    const id = try f.publish(.{ 1, 1, 1 }, &.{.planks}, "  Private house  ");
    try std.testing.expectEqualStrings("Private house", f.local.blueprints.definitions.get(id).?.name);
    try std.testing.expectEqual(@as(u64, 1), f.local.blueprints.definitions.get(id).?.owner);
    const wrong_owner = try f.apply(2, id, origin, 0);
    try std.testing.expect(wrong_owner.status != .success);
    const missing_platform = try f.apply(1, id, .{ 40, 40, 50 }, 0);
    try std.testing.expect(missing_platform.status != .success);
    const applied = try f.apply(1, id, origin, 0);
    try std.testing.expectEqual(.success, applied.status);
    const instance = applied.instance_id.?;
    try f.waitInstance(instance);
    const overlap = try f.apply(1, id, origin, 0);
    try std.testing.expect(overlap.status != .success);
    try std.testing.expectEqual(world.OperationStatus.target_changed, (try f.edit(.{ .block = origin, .action = .{ .put = .planks }, .blueprint = .{ .instance_id = instance + 1, .cell_index = 0 } })).status);
    try std.testing.expectEqual(world.OperationStatus.inventory_mismatch, (try f.edit(.{ .block = origin, .action = .{ .put = .dirt }, .blueprint = .{ .instance_id = instance, .cell_index = 0 } })).status);
    const source: [3]u32 = .{ 45, 45, 48 };
    try std.testing.expectEqual(world.OperationStatus.success, (try f.edit(.{ .block = source, .action = .{ .put = .planks } })).status);
    const history = f.local.getChunk(.{ 1, 1, 1 }).?.cell_changes.sequence;
    const mined = try f.edit(.{ .block = source, .action = .remove, .player = .{ .id = 1, .expected_sequence = history } });
    try std.testing.expectEqual(world.OperationStatus.success, mined.status);
    try std.testing.expectEqual(@as(?blueprint.BlockType, .planks), mined.player_inventory.?.material);
    const completed = try f.edit(.{ .block = origin, .action = .{ .put = .planks }, .player = .{ .id = 1, .expected_sequence = 0 }, .blueprint = .{ .instance_id = instance, .cell_index = 0 } });
    try std.testing.expectEqual(world.OperationStatus.success, completed.status);
    try std.testing.expectEqual(@as(?blueprint.BlockType, null), completed.player_inventory.?.material);
    const end = deadline();
    while (persistence.now(io) < end) {
        try f.pump();
        if (f.local.blueprints.targetAt(origin) == null and f.local.reader().get(.{ 40, 40, 48 }) == .planks) break;
        try pause();
    }
    try std.testing.expect(f.local.blueprints.targetAt(origin) == null);
    try std.testing.expect(f.local.blueprints.boxAt(f.local.layout, origin) == null);
    try std.testing.expectEqual(blueprint.BlockType.planks, f.local.reader().get(.{ 40, 40, 48 }).?);
    try std.testing.expect(f.fill_packages > 0);
    try std.testing.expect(f.fill_snapshots > 0);
    const occupied = try f.apply(1, id, origin, 0);
    try std.testing.expect(occupied.status != .success);
    try f.save();
    try f.restart();
    try std.testing.expectEqual(@as(u32, 1), f.local.blueprints.definitions.count());
    try std.testing.expectEqual(@as(u32, 0), f.local.blueprints.instances.count());
    try std.testing.expectEqual(@as(?u8, null), f.service.?.restoredPlayer(1).?.inventory);
    try std.testing.expectEqual(blueprint.BlockType.planks, f.local.reader().get(.{ 40, 40, 48 }).?);
}

test "public partial blueprint restart retains exact progress and completion deltas are compact" {
    const f = try Harness.create();
    defer f.destroy();
    const id = try f.publish(.{ 4, 1, 1 }, &.{ .planks, .planks, .planks, .planks }, "Beam");
    const applied = try f.apply(1, id, origin, 0);
    try std.testing.expectEqual(.success, applied.status);
    const instance = applied.instance_id.?;
    try f.waitInstance(instance);
    const first = try f.edit(.{ .block = origin, .action = .{ .put = .planks }, .blueprint = .{ .instance_id = instance, .cell_index = 0 } });
    try std.testing.expectEqual(world.OperationStatus.success, first.status);
    try f.save();
    try f.restart();
    try f.waitInstance(instance);
    try std.testing.expectEqual(@as(u32, 3), f.local.blueprints.instances.get(instance).?.remaining);
    try std.testing.expect(f.local.blueprints.instances.get(instance).?.isFulfilled(0));
    try std.testing.expectEqual(blueprint.BlockType.planks, f.local.reader().get(.{ 40, 40, 48 }).?);
    try std.testing.expectEqual(blueprint.BlockType.none, f.local.reader().get(.{ 41, 40, 48 }).?);
    try std.testing.expect(f.local.blueprints.targetAt(.{ 40, 40, 48 }) == null);
    try std.testing.expect(f.local.blueprints.targetAt(.{ 41, 40, 48 }) != null);
    var requests: [3]u64 = undefined;
    for (1..4) |index| requests[index - 1] = try f.client.?.trySubmitOperation(.{ .block = .{ 40 + @as(u32, @intCast(index)), 40, 48 }, .action = .{ .put = .planks }, .blueprint = .{ .instance_id = instance, .cell_index = @intCast(index) } });
    for (requests) |request| try std.testing.expectEqual(world.OperationStatus.success, (try f.waitOperation(request)).status);
    const delta = try wire.encodeOps(a, &.{ .{ .fulfill = .{ .instance_id = instance, .cell_index = 1 } }, .{ .fulfill = .{ .instance_id = instance, .cell_index = 2 } }, .{ .fulfill = .{ .instance_id = instance, .cell_index = 3 } } });
    defer a.free(delta);
    try std.testing.expectEqual(@as(usize, 39), delta.len);
    try f.save();
    try f.restart();
    try std.testing.expectEqual(@as(u32, 0), f.local.blueprints.instances.count());
    try std.testing.expectEqual(instance, f.store.blueprints.max_instance_id);
    for (40..44) |x| try std.testing.expectEqual(blueprint.BlockType.planks, f.local.reader().get(.{ @intCast(x), 40, 48 }).?);
}

test "unsubmitted candidates never autosave and invalid names preserve candidate ownership" {
    const f = try Harness.create();
    defer f.destroy();
    var result = try blueprint.compile(a, .{ .size = .{ 1, 1, 1 }, .cells = &.{.planks} }, .{ .horizontal_limit = blueprint.horizontalLimit(&f.layout) });
    try std.testing.expect(result == .valid);
    defer result.valid.deinit(a);
    try std.testing.expectError(error.InvalidBlueprintName, f.client.?.trySaveBlueprint(1, "\nName", &result.valid));
    try std.testing.expectEqual(blueprint.BlockType.planks, result.valid.definition.cells[0]);
    try f.save();
    try f.restart();
    try std.testing.expectEqual(@as(u32, 0), f.store.blueprints.definitions.count());
    try std.testing.expectEqual(@as(u32, 0), f.store.blueprints.instances.count());
}

test "Save rechecks compact size and accepts independent stable IDs with duplicate names" {
    const f = try Harness.create();
    defer f.destroy();
    const compiled = try blueprint.compile(a, .{ .size = .{ 1, 1, 1 }, .cells = &.{.planks} }, .{ .horizontal_limit = blueprint.horizontalLimit(&f.layout) });
    try std.testing.expect(compiled == .valid);
    var malformed = compiled.valid;
    malformed.definition.size[0] = blueprint.horizontalLimit(&f.layout) + 1;
    const request = f.client.?.trySaveBlueprint(1, "Oversized", &malformed) catch |err| {
        malformed.deinit(a);
        return err;
    };
    const rejected = try f.waitBlueprint(request);
    try std.testing.expect(rejected.status != .success);
    try std.testing.expectEqual(@as(u32, 0), f.local.blueprints.definitions.count());
    const first = try f.publish(.{ 1, 1, 1 }, &.{.planks}, "Duplicate");
    const second = try f.publish(.{ 1, 1, 1 }, &.{.planks}, "Duplicate");
    try std.testing.expect(first != second);
    try f.save();
    try f.restart();
    const third = try f.publish(.{ 1, 1, 1 }, &.{.planks}, "Duplicate");
    try std.testing.expect(third > second);
    try std.testing.expectEqual(@as(u32, 3), f.local.blueprints.definitions.count());
}

test "startup rejects checksum-valid blueprint progress that disagrees with pending or fulfilled terrain" {
    for ([_]bool{ false, true }) |fulfilled| {
        const f = try Harness.create();
        defer f.destroy();
        const id = try f.publish(.{ 2, 1, 1 }, &.{ .planks, .planks }, "Corruption fixture");
        const applied = try f.apply(1, id, origin, 0);
        try std.testing.expectEqual(.success, applied.status);
        const instance = applied.instance_id.?;
        try f.waitInstance(instance);
        if (fulfilled) try std.testing.expectEqual(world.OperationStatus.success, (try f.edit(.{ .block = origin, .action = .{ .put = .planks }, .blueprint = .{ .instance_id = instance, .cell_index = 0 } })).status);
        try f.waitSave(f.service.?.requestSave(true));
        f.service.?.destroy();
        f.service = null;
        f.client = null;
        const chunk_id = f.layout.encodeChunkCoords(.{ 1, 1, 1 });
        var blocks: [32768]u8 = undefined;
        var revision: u64 = 1;
        if (try f.store.readChunk(a, chunk_id)) |encoded| {
            defer a.free(encoded);
            var chunk = try format.decodeChunk(a, f.store.world_uuid, encoded, f.store.dimensions);
            defer chunk.deinit(a);
            @memcpy(&blocks, chunk.blocks);
            revision = chunk.revision + 1;
        } else {
            var prepared = try @import("world_generator.zig").WorldGenerator.prepare(.flat, a, &f.layout);
            defer prepared.deinit(a);
            const column = @import("world_generator.zig").ColumnGenerator.init(&prepared, .{ 1, 1 });
            const chunk = try column.tryGenerateChunk(a, 1);
            defer chunk.deinit(a);
            const data = chunk.content.toData();
            @memcpy(&blocks, std.mem.asBytes(&data.blocks));
        }
        const index = 16 * 1024 + 8 * 32 + 8;
        blocks[index] = if (fulfilled) 0 else @intFromEnum(blueprint.BlockType.planks);
        const encoded = try format.encodeChunk(a, f.store.world_uuid, .{ .id = chunk_id, .revision = revision, .is_unreachable = false, .blocks = &blocks, .metadata = &.{} });
        defer a.free(encoded);
        try f.store.beginSnapshot(f.store.sequence + 1, f.store.global, f.store.players, f.store.player_count, 1);
        try f.store.appendChunk(encoded);
        _ = try f.store.commitSnapshot();
        f.store.deinit();
        f.store_open = false;
        f.store = try storage.Store.open(a, f.path, .{});
        f.store_open = true;
        try std.testing.expectError(error.BlueprintTerrainMismatch, service_api.WorldDataService.createPersistent(io, a, &f.layout, .flat, &f.store, .{}));
    }
}
