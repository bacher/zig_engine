const ChunkCoords = @import("engine").ChunkCoords;
const std = @import("std");
const math = std.math;
const zgpu = @import("engine").zgpu;
const wgpu = zgpu.wgpu;
const zgui = @import("engine").zgui;
const zglfw = @import("engine").zglfw;
const gltf_loader = @import("gltf_loader");
const content_dir = @import("build_options").content_dir;
const zmath = @import("zmath");

const debug = @import("debug");
const WindowContext = @import("engine").WindowContext;
const Engine = @import("engine").Engine;
const KeyParams = @import("engine").KeyParams;
const MouseButtonParams = @import("engine").MouseButtonParams;
const GameObject = @import("engine").GameObject;
const GameObjectGroup = @import("engine").GameObjectGroup;
const Scene = @import("engine").Scene;
const voxel_chunk_module = @import("engine").voxel_chunk;
const Side = @import("engine").voxel_chunk.Side;
const tube = @import("engine").tube;
const utils = @import("engine").utils;
const zgui_utils = @import("engine").zgui_utils;
const Position = @import("engine").world_math.Position;

const world_module = @import("world.zig");
const World = @import("world.zig").World;
const WorldLayout = @import("engine").WorldLayout;
const test_layout = @import("test_world.zig").layout;
const WorldChunk = @import("world.zig").WorldChunk;
const world_generator = @import("./world_generator.zig");
const world_data_service = @import("./world_data_service.zig");
const WorldDataService = world_data_service.WorldDataService;
const ChunkResponse = world_data_service.ChunkResponse;
const SimulationWorker = @import("./simulation_worker.zig").SimulationWorker;
const player_module = @import("player_controller.zig");
const PlayerController = player_module.PlayerController;
const player_interaction = @import("player_interaction.zig");
const terrain_collision = @import("terrain_collision.zig");
const consts = @import("./consts.zig");
const world_engine = @import("./world_engine_glue.zig");
const transformations = @import("block_transformations.zig");
const block_targeting = @import("block_targeting.zig");
const placement_preview = @import("placement_preview.zig");
const block_diagnostics = @import("block_diagnostics.zig");
const block_messages = @import("block_messages.zig");
const held_block = @import("engine").held_block;
const empty_hands = @import("engine").empty_hands;
const held_item_motion = @import("engine").held_item_motion;
const persistence_format = @import("persistence/format.zig");
const persistence_storage = @import("persistence/storage.zig");
const persistence_launch = @import("persistence/launch.zig");

// Shared camera-space held pose for player and spectator modes.
const held_block_pose: held_block.Pose = .{};

const DEBUG = true;

/// Chunks within this distance are requested; reachable chunks are uploaded to the GPU.
const CHUNK_LOAD_RADIUS = 3;
const BLOCK_LOAD_RADIUS = 1;

const menu = @import("menu.zig");
const world_map = @import("world_map.zig");

const Game = struct {
    const MeshVersion = struct { chunk_revision: u64, mesh_revision: u64 };
    const BoundarySnapshot = struct { masks: world_engine.BoundaryMasks, mesh_revision: u64 };
    const Overlay = enum { none, menu, world_map };
    allocator: std.mem.Allocator,
    engine: *Engine,
    world: ?World = null,
    world_data: ?*WorldDataService = null,
    world_client: ?*world_data_service.Client = null,
    simulation: ?*SimulationWorker = null,
    persistence_store: ?*persistence_storage.Store = null,
    player_id: u64 = 1,
    next_autosave_at: f64 = 60,
    next_compaction_at: f64 = 600,
    overlay: Overlay = .none,
    map_state: world_map.State = .{},
    map_teleport: ?struct { xy: [2]f64, request_id: ?u64 = null } = null,
    map_teleport_error: ?[]const u8 = null,
    /// Future multiplayer sessions leave simulation running behind the menu.
    menu_pauses_game: bool = true,
    exit_requested: bool = false,
    exit_intent: ?u64 = null,
    close_ready: bool = false,
    exit_progress: u64 = 0,
    exit_progress_at: f64 = 0,
    player: ?PlayerController = null,
    control_mode: enum { player, spectator } = .player,
    block_mode: block_targeting.Mode = .removing,
    block_interaction: player_interaction.Interaction = .{},
    jump_requested: bool = false,
    /// Keyboard and mouse presses retain their order and material until the camera updates.
    tool_commands: std.ArrayList(BlockAction) = .empty,
    last_missing_collision: ?ChunkCoords = null,
    recovery_warning: bool = false,
    selected_material: voxel_chunk_module.BlockType = .dirt,
    held_block_renderer: ?held_block.Renderer = null,
    empty_hands_renderer: ?empty_hands.Renderer = null,
    player_skin: ?@import("engine").TextureDescriptor = null,
    held_motion: held_item_motion.Motion = .{},
    placement_validation: ?struct {
        block: [3]u32,
        material: voxel_chunk_module.BlockType,
        window: world_module.ValidationWindow,
        result: world_module.EditResult,
    } = null,
    current_placement_preview: ?placement_preview.Preview = null,
    block_action_error: block_messages.TimedError = .{},
    fractional_ticks: f64 = 0,
    /// Active subscriptions, including loads still in flight. Kept until cache eviction.
    chunk_subscriptions: std.AutoHashMapUnmanaged(u32, u64) = .empty,
    /// Last accepted block snapshot's subscription; retained blocks may predate a promotion.
    block_snapshot_tokens: std.AutoHashMapUnmanaged(u32, u64) = .empty,
    chunk_packages: std.ArrayList(world_data_service.ResponsePackage) = .empty,
    chunk_modes: std.AutoHashMapUnmanaged(u32, world_data_service.Representation) = .empty,
    /// Metadata only: CPU mesh arrays transfer directly to the GPU upload queue.
    mesh_versions: std.AutoHashMapUnmanaged(u32, MeshVersion) = .empty,
    /// Authoritative fallback planes for block subscriptions, including retained demotions.
    boundary_snapshots: std.AutoHashMapUnmanaged(u32, BoundarySnapshot) = .empty,
    pinned_chunks: std.AutoHashMapUnmanaged(u32, void) = .empty,
    render_radius: i32 = CHUNK_LOAD_RADIUS,
    gpu_capacity_warning: bool = false,

    loaded_chunk_ids: std.AutoHashMapUnmanaged(u32, void) = .empty,
    /// Loaded chunks whose meshes must be rebuilt at the end of this frame's world update.
    dirty_chunk_ids: std.AutoHashMapUnmanaged(u32, void) = .empty,
    last_camera_chunk_coords: ?ChunkCoords = null,
    saved_game_objects: std.StringHashMapUnmanaged(*GameObject) = .empty,
    saved_game_object_groups: std.StringHashMapUnmanaged(*GameObjectGroup) = .empty,

    fn setOverlay(game: *Game, overlay: Overlay) void {
        if (game.exit_requested or overlay == game.overlay) return;
        if (game.overlay == .world_map and game.map_teleport != null) return;
        if (game.overlay == .world_map) game.cancelMapTeleport();
        game.overlay = overlay;
        game.engine.setPaused(overlay == .menu and game.menu_pauses_game);
        game.engine.setGameplayInputBlocked(overlay != .none);
    }

    fn cancelMapTeleport(game: *Game) void {
        // Shutdown may abandon the read; request IDs keep its late reply from
        // being applied if exiting is canceled and a new teleport is requested.
        game.map_teleport = null;
        game.map_teleport_error = null;
    }

    fn mapView(game: *const Game, scene: *const Scene) world_map.View {
        return .{
            .player = if (game.player) |player| .{ .position = player.position, .yaw = player.yaw } else null,
            .spectator = if (game.control_mode == .spectator) .{
                .position = scene.camera.position,
                .yaw = scene.spectator_camera.yaw,
            } else null,
            .teleport_pending = game.map_teleport != null,
            .teleport_status = game.map_teleport_error orelse if (game.map_teleport != null) "Finding a safe surface..." else null,
        };
    }

    fn handleMapAction(game: *Game, action: world_map.Action) void {
        if (game.overlay != .world_map or game.exit_requested) return;
        if (action.close) {
            game.setOverlay(.none);
            return;
        }
        // Keep the map locked to one active teleport destination at a time.
        if (game.map_teleport != null) return;
        if (comptime !world_map.debug_teleport_enabled) return;
        const xy = action.teleport_xy orelse return;
        for (xy) |coordinate| if (!std.math.isFinite(coordinate)) return;
        const scene = game.engine.active_scene orelse return;
        const size = scene.layout.size_in_blocks;
        const width: f64 = @floatFromInt(size[0]);
        const height: f64 = @floatFromInt(size[1]);
        if (xy[0] < -width / 2 or xy[0] >= width / 2 or xy[1] < -height / 2 or xy[1] >= height / 2) return;
        game.map_teleport_error = null;
        if (game.control_mode == .spectator) {
            const service = game.world_data orelse return;
            const environment = service.preparedGenerator().columnEnvironmentAt(@intFromFloat(@floor(xy[0] + width / 2)), @intFromFloat(@floor(xy[1] + height / 2)));
            const surface = @max(environment.terrain_height, if (environment.water_present) environment.sea_level else 0);
            const z = @as(f64, @floatFromInt(surface)) - @as(f64, @floatFromInt(scene.layout.origin_chunk[2])) * consts.CHUNK_SIZE + 4;
            scene.camera.updatePosition(.{ xy[0], xy[1], z });
            game.resetAfterMapTeleport();
        } else {
            if (game.player == null or game.world_client == null) return;
            game.map_teleport = .{ .xy = xy };
        }
    }

    fn updateMapTeleport(game: *Game) void {
        if (comptime !world_map.debug_teleport_enabled) return;
        const pending = game.map_teleport orelse return;
        const client = game.world_client orelse return;
        if (pending.request_id == null) {
            // Submitted edits can still be delayed by persistence capture. Wait
            // for acknowledgments so the lookup sees their final terrain state.
            if (game.world.?.pending_operations.items.len != 0) return;
            const player = if (game.player) |*player| player else return;
            game.map_teleport.?.request_id = client.requestStandingSpace(.{
                .preferred_xy = pending.xy,
                .clearance_size = .{ player.body.half_width * 2, player.body.half_width * 2, player.body.height },
                .support_size = .{ player.body.half_width * 2, player.body.half_width * 2 },
            });
            return;
        }
        const response = client.pollStandingSpace(pending.request_id.?) orelse return;
        game.map_teleport = null;
        if (game.overlay != .world_map or game.exit_requested or game.control_mode != .player) return;
        const position = response.result catch |err| {
            game.map_teleport_error = switch (err) {
                error.NoSpace, error.NoSurface => "No safe surface at this point",
                else => "Teleport unavailable; try another point",
            };
            std.log.warn("map teleport: {s}", .{@errorName(err)});
            return;
        };
        const player = if (game.player) |*player| player else return;
        player.teleport(position);
        player.applyCamera(game.engine.active_scene.?.camera);
        game.resetAfterMapTeleport();
    }

    fn resetAfterMapTeleport(game: *Game) void {
        game.block_interaction.loseFocus();
        game.tool_commands.clearRetainingCapacity();
        game.jump_requested = false;
        game.clearBlockFocus();
        game.held_motion.reset();
        game.last_missing_collision = null;
        game.recovery_warning = false;
        game.setOverlay(.none);
    }

    fn handleMenuAction(game: *Game, action: menu.Action) void {
        if (game.overlay != .menu) return;
        switch (action) {
            .resume_game => game.setOverlay(.none),
            .exit_game => game.engine.requestExit(),
        }
    }

    fn heldMaterial(game: *const Game) ?voxel_chunk_module.BlockType {
        if (game.control_mode == .player) return game.block_interaction.inventory;
        return if (game.block_mode == .putting) game.selected_material else null;
    }

    fn blockMode(game: *const Game) block_targeting.Mode {
        if (game.control_mode == .spectator) return game.block_mode;
        return if (game.block_interaction.inventory == null) .removing else .putting;
    }

    fn updateHeldMotion(game: *Game) void {
        const scene = game.engine.active_scene orelse return;
        const input = game.engine.input_controller;
        const spectator = game.control_mode == .spectator;
        const player = if (game.player) |*player| player else null;
        game.held_motion.update(.{
            .position = scene.camera.position,
            .view_from_world = scene.camera.view_from_camera,
            .look_angles = if (spectator) .{ scene.spectator_camera.yaw, scene.spectator_camera.pitch } else if (player) |p| .{ p.yaw, p.pitch } else .{ 0, 0 },
            .grounded = !spectator and if (player) |p| p.grounded else false,
            .gait_enabled = spectator or if (player) |p| p.grounded and p.climb == null else false,
            .active = input.focused and !input.focus_changed and !game.engine.gameplay_input_blocked and !game.exit_requested,
        }, game.engine.frame_delta);
    }

    fn layout(game: *const Game) *const WorldLayout {
        return game.world.?.layout;
    }

    pub fn init(allocator: std.mem.Allocator) !*Game {
        const game = try allocator.create(Game);
        game.* = .{
            .allocator = allocator,
            .engine = undefined,
        };
        return game;
    }

    fn stopWorkers(game: *Game) void {
        if (game.simulation) |simulation| simulation.destroy();
        game.simulation = null;
        if (game.world_data) |world_data| {
            // Setup can fail before both world and client have been initialized.
            if (game.world != null and game.world_client != null) game.flushBlockOperations();
            // The floor callback borrows the service's immutable prepared generator.
            if (game.world) |*world| world.immutable_floor = null;
            world_data.destroy();
        }
        game.world_data = null;
        game.world_client = null;
    }

    pub fn deinit(game: *Game) void {
        game.stopWorkers();
        game.map_state.deinit(game.engine.gctx);
        game.tool_commands.deinit(game.allocator);
        if (game.player) |*player| player.deinit();
        game.chunk_subscriptions.deinit(game.allocator);
        game.block_snapshot_tokens.deinit(game.allocator);
        for (game.chunk_packages.items) |*package| package.deinit(game.allocator);
        game.chunk_packages.deinit(game.allocator);
        game.chunk_modes.deinit(game.allocator);
        game.mesh_versions.deinit(game.allocator);
        game.boundary_snapshots.deinit(game.allocator);
        game.pinned_chunks.deinit(game.allocator);
        game.loaded_chunk_ids.deinit(game.allocator);
        game.dirty_chunk_ids.deinit(game.allocator);

        game.saved_game_objects.deinit(game.allocator);
        game.saved_game_object_groups.deinit(game.allocator);
        if (game.world) |*world| {
            world.deinit();
        }
        if (game.held_block_renderer) |renderer| renderer.deinit(game.engine.gctx);
        if (game.empty_hands_renderer) |renderer| renderer.deinit(game.engine.gctx);
        if (game.player_skin) |skin| skin.deinit(game.engine.gctx);
        game.engine.deinit();
        game.allocator.destroy(game);
    }

    pub fn updateWorld(game: *Game) void {
        if (game.world == null) {
            return;
        }

        game.advanceWorldClock();

        game.flushBlockOperations();
        game.updateMapTeleport();
        game.updateChunksAroundCamera(false);
        const has_new_chunks = game.receiveChunks();
        // Synchronize blocks first, then resolve local movement against that cache.
        // Player input remains independent of mesh work and GPU upload capacity.
        game.updateGameplay(has_new_chunks);
        game.flushBlockOperations();
        game.updatePersistence();
        game.updateChunksAroundCamera(has_new_chunks);
        if (!game.engine.gameplay_input_blocked) game.updateBlockFocus();
        game.rebuildDirtyChunks();
        const grid = game.engine.active_scene.?.voxel_grid;
        if (!grid.hasUploadCapacity() and game.render_radius > 2) {
            std.debug.print("voxel buffer capacity reached; reducing the visible box to 5x5x5\n", .{});
            game.render_radius = 2;
            game.updateChunksAroundCamera(false);
        }
        if (!grid.hasUploadCapacity()) {
            if (!game.gpu_capacity_warning) std.debug.print("voxel uploads exceed buffer capacity even at 5x5x5; retaining pending uploads\n", .{});
            game.gpu_capacity_warning = true;
            return;
        }
        game.gpu_capacity_warning = false;
        grid.uploadToGPU(game.engine.gctx);
    }

    fn advanceWorldClock(game: *Game) void {
        if (!game.exit_requested and !game.engine.paused and std.math.isFinite(game.engine.frame_delta) and game.engine.frame_delta > 0) {
            game.fractional_ticks += game.engine.frame_delta * @as(f64, @floatFromInt(transformations.ticks_per_second));
            const ticks: transformations.Tick = @intFromFloat(@floor(game.fractional_ticks));
            game.fractional_ticks -= @as(f64, @floatFromInt(ticks));
            game.world.?.simulation_tick +|= ticks;
            if (ticks != 0) if (game.world_data) |service| service.advanceTo(game.world.?.simulation_tick);
        }
    }

    fn checkpoint(game: *Game) void {
        // Position may depend on optimistic terrain. Do not publish it ahead of
        // an edit that has not entered the authority's command prefix yet.
        for (game.world.?.pending_operations.items) |pending| {
            if (pending.request_id == null) return;
        }
        const player = if (game.player) |player| player else return;
        game.world_client.?.publishCheckpoint(.{
            .id = game.player_id,
            .feet = .{ player.position[0], player.position[1], player.position[2] },
            .yaw = player.yaw,
            .pitch = player.pitch,
        });
    }

    fn updatePersistence(game: *Game) void {
        // Register/update player movement even in ephemeral worlds. Inventory is
        // changed only by authoritative transfers, never by these checkpoints.
        if (!game.exit_requested) game.checkpoint();
        if (game.persistence_store == null) return;
        const service = game.world_data.?;
        if (game.exit_requested and game.exit_intent == null) {
            // Admission can be bounded while a prior capture is in flight. Keep
            // pumping completions until every existing optimistic intent is sent.
            for (game.world.?.pending_operations.items) |pending| {
                if (pending.request_id == null) return;
            }
            game.checkpoint();
            game.exit_intent = service.requestSave(true);
        }
        if (game.exit_intent) |intent| {
            const status = service.persistenceStatus();
            if (status.intent_id != intent) return;
            if (status.progress_generation != game.exit_progress) {
                game.exit_progress = status.progress_generation;
                game.exit_progress_at = game.engine.real_time;
            }
            const saved_but_finalization_failed = status.phase == .failed and !status.active and
                status.target_sequence != 0 and status.durable_sequence >= status.target_sequence;
            if (status.phase == .complete or saved_but_finalization_failed) {
                if (saved_but_finalization_failed) std.debug.print("Final snapshot is durable; base finalization failed ({s}). WAL retained for recovery.\n", .{status.error_name orelse "unknown"});
                game.close_ready = true;
                game.engine.window_context.window.setShouldClose(true);
            }
            return;
        }
        if (game.engine.real_time >= game.next_autosave_at) {
            _ = service.requestSave(false);
            game.next_autosave_at = game.engine.real_time + 60;
        }
        if (game.engine.real_time >= game.next_compaction_at) {
            service.requestCompaction();
            game.next_compaction_at = game.engine.real_time + 600;
        }
    }

    fn beginExit(game: *Game) void {
        if (game.exit_requested) return;
        game.exit_requested = true;
        game.overlay = .none;
        game.cancelMapTeleport();
        game.engine.setPaused(true);
        game.engine.setGameplayInputBlocked(true);
        game.block_interaction.cancelHold();
        // Quiesce NPC admission before the final save can enter the service queue.
        // Already admitted NPC commands precede that save; later ones await resume.
        if (game.simulation) |simulation| simulation.pauseDispatch();
        game.flushBlockOperations();
        // updatePersistence publishes the final checkpoint after all local intents
        // have entered the authority's ordered queue.
        game.updatePersistence();
        game.exit_progress = 0;
        game.exit_progress_at = game.engine.real_time;
        game.engine.active_scene.?.spectator_enabled = false;
        game.jump_requested = false;
        if (game.player) |*player| player.resetJumpInput();
    }

    fn cancelExit(game: *Game) void {
        if (game.exit_intent) |intent| game.world_data.?.cancelSaveIntent(intent);
        game.exit_intent = null;
        game.exit_requested = false;
        game.close_ready = false;
        game.engine.setPaused(false);
        game.engine.setGameplayInputBlocked(false);
        game.engine.active_scene.?.spectator_enabled = game.control_mode == .spectator;
        if (game.simulation) |simulation| simulation.resumeDispatch();
    }

    fn updateGameplay(game: *Game, terrain_changed: bool) void {
        if (game.exit_requested or game.engine.paused) return;
        if (game.player != null) game.updatePlayer(terrain_changed);
        if (!game.engine.gameplay_input_blocked) game.updateBlockTool();
    }

    fn updatePlayer(game: *Game, terrain_changed: bool) void {
        const player = &game.player.?;
        const engine = game.engine;
        if (terrain_changed) player.terrainChanged();
        player.expireHistory(engine.time);
        if (game.control_mode == .spectator) return;
        const input = engine.input_controller;
        if (!input.focused) {
            game.jump_requested = false;
            player.resetJumpInput();
            return;
        }
        const elapsed = if (input.focus_changed) 0 else engine.frame_delta;
        if (input.focus_changed) game.jump_requested = false;
        // UI captures controls without suspending gravity or terrain collisions.
        var player_input: player_module.Input = .{};
        if (!engine.gameplay_input_blocked) {
            player.look(input.cursor_position_delta);
            const forward = @as(i8, @intFromBool(input.isKeyPressed(.w))) - @as(i8, @intFromBool(input.isKeyPressed(.s)));
            const right = @as(i8, @intFromBool(input.isKeyPressed(.d))) - @as(i8, @intFromBool(input.isKeyPressed(.a)));
            player_input = .{
                .forward = @floatFromInt(forward),
                .right = @floatFromInt(right),
                .jump_pressed = game.jump_requested,
                .jump_down = input.isKeyPressed(.space),
            };
        }
        const result = player.update(&game.world.?, player_input, elapsed, engine.time) catch |err| {
            std.debug.print("player update failed: {}\n", .{err});
            game.jump_requested = false;
            player.applyCamera(engine.active_scene.?.camera);
            return;
        };
        game.jump_requested = false;
        if (result.missing_chunk) |chunk| {
            if (game.last_missing_collision == null or !@reduce(.And, game.last_missing_collision.? == chunk)) {
                std.debug.print("warning: player collision with missing chunk {d}; treating it as fully solid\n", .{chunk});
            }
        }
        game.last_missing_collision = result.missing_chunk;
        if (result.recovery_failed and !game.recovery_warning) {
            std.debug.print("warning: player embedded in terrain; no clear history or space within {d}m; movement frozen (see TODO.md)\n", .{player_module.recovery_radius});
        }
        game.recovery_warning = result.recovery_failed;
        if (result.recovered) {
            game.held_motion.reset();
            std.debug.print("player recovered to {d}\n", .{player.position});
        }
        player.applyCamera(engine.active_scene.?.camera);
    }

    fn toggleControlMode(game: *Game) void {
        const player = if (game.player) |*player| player else return;
        const scene = game.engine.active_scene.?;
        game.held_motion.reset();
        game.block_interaction.cancelHold();
        game.clearBlockFocus();
        game.jump_requested = false;
        player.resetJumpInput();
        if (game.control_mode == .player) {
            // Every excursion starts at the player's current eyes and orientation.
            player.applyCamera(scene.camera);
            scene.spectator_camera.yaw = player.yaw;
            scene.spectator_camera.pitch = player.pitch;
            game.control_mode = .spectator;
            scene.spectator_enabled = true;
            game.engine.input_controller.cursor_capture = .always;
        } else {
            if (game.world) |*world| {
                var query: terrain_collision.Query = .{ .world = world, .body = player.body };
                switch (query.overlap(player.position, false)) {
                    .clear => {},
                    .solid => if (!player.recover(&query, game.engine.time)) return,
                    .missing => return,
                }
            }
            game.control_mode = .player;
            scene.spectator_enabled = false;
            game.engine.input_controller.cursor_capture = .always;
            player.terrainChanged();
            player.applyCamera(scene.camera);
        }
        std.debug.print("control mode: {s}\n", .{@tagName(game.control_mode)});
    }

    /// Submit commands in optimistic edit order; no chunk data crosses in this direction.
    fn flushBlockOperations(game: *Game) void {
        const world = &game.world.?;
        for (world.pending_operations.items) |*pending| {
            if (pending.request_id == null) {
                pending.request_id = game.world_client.?.trySubmitOperation(pending.operation) catch {
                    // Preserve the original optimistic order and retry admission
                    // after completions free capacity. No identity was assigned.
                    break;
                };
                if (pending.operation.player != null) {
                    game.block_interaction.markSubmitted(pending.request_id.?);
                }
            }
        }
    }

    /// A package is consumed in full before any mesh rebuild or GPU upload. Retire all
    /// acknowledgments first, then replay only commands not represented by these snapshots.
    fn receiveChunks(game: *Game) bool {
        game.world_client.?.takePackages(&game.chunk_packages);
        defer game.chunk_packages.clearRetainingCapacity();
        var changed = false;
        for (game.chunk_packages.items) |*package| {
            game.applyPackage(package);
            package.responses.deinit(game.allocator);
            changed = true;
        }
        return changed;
    }

    fn applyPackage(game: *Game, package: *world_data_service.ResponsePackage) void {
        const world = &game.world.?;
        for (package.responses.items) |response| {
            if (response.operation) |result| {
                // Rejection now restores material before snapshots are installed.
                // Invalidate its face dependencies before the old boundary is lost.
                if (result.status != .success) {
                    for (world.pending_operations.items) |pending| if (pending.request_id == result.request_id) {
                        game.markChunksAroundBlockDirty(pending.operation.block);
                        break;
                    };
                }
                world.acknowledgeOperationResult(result.request_id, result.status);
                if (game.block_interaction.acknowledge(game.player_id, result)) {
                    game.block_interaction.finishReconciliation(world.pending_operations.items);
                    game.clearBlockFocus();
                }
                world.last_edit_result = .{ .status = result.status, .failure = result.failure, .mined_type = result.mined_type };
                game.showBlockEditError(world.last_edit_result.?);
            }
        }
        for (package.responses.items) |response| {
            const id = game.layout().encodeChunkCoords(response.coords);
            const token = game.chunk_subscriptions.get(id);
            if (token == null or token != response.subscription_id) {
                response.deinit(game.allocator);
                continue;
            }
            switch (response.data) {
                .acknowledgement => {},
                .blocks => |snapshot| {
                    if ((game.chunk_modes.get(id) orelse .blocks) != .blocks) {
                        response.deinit(game.allocator);
                        continue;
                    }
                    // Re-promotion can retain blocks while neighbors were meshed with
                    // fallback planes. Its first accepted snapshot reloads that dependency.
                    const previous_boundaries: ?world_engine.BoundaryMasks = if (game.block_snapshot_tokens.get(id) == token)
                        (if (world.getChunk(response.coords)) |chunk| chunk.boundaries else null)
                    else
                        null;
                    world.insertChunk(response.coords, snapshot.chunk) catch |err| {
                        if (err == error.OutOfMemory) {
                            // Keep the subscription identity for normal eviction, but
                            // invalidate its mode so the next streaming pass requests
                            // a fresh authoritative snapshot. No payload or extra queue
                            // survives the failed rebase, and acknowledgments stay retired.
                            _ = game.chunk_modes.remove(id);
                            _ = game.block_snapshot_tokens.remove(id);
                        }
                        response.deinit(game.allocator);
                        continue;
                    };
                    game.block_snapshot_tokens.put(game.allocator, id, token.?) catch @panic("OOM");
                    game.loadChunkIfNeeded(response.coords[0], response.coords[1], response.coords[2]);
                    if (snapshot.neighbors) |masks| game.installBoundaries(response.coords, masks, response.mesh_revision);
                    game.markChunkSnapshotDirty(response.coords, previous_boundaries);
                },
                .boundaries => |masks| {
                    if (game.chunk_modes.get(id) != .blocks) continue;
                    game.installBoundaries(response.coords, masks, response.mesh_revision);
                },
                .mesh, .unreachable_chunk => {
                    if (game.chunk_modes.get(id) != .mesh) {
                        response.deinit(game.allocator);
                        continue;
                    }
                    if (game.mesh_versions.get(id)) |old| {
                        if (response.mesh_revision < old.mesh_revision) {
                            response.deinit(game.allocator);
                            continue;
                        }
                    }
                    game.engine.active_scene.?.voxel_grid.removeChunk(response.coords);
                    if (response.data == .mesh) {
                        game.engine.active_scene.?.voxel_grid.appendChunk(.{ .chunk_coords = response.coords, .chunk_side_data = response.data.mesh });
                    }
                    game.loaded_chunk_ids.put(game.allocator, id, {}) catch @panic("OOM");
                    game.mesh_versions.put(game.allocator, id, .{ .chunk_revision = response.chunk_revision, .mesh_revision = response.mesh_revision }) catch @panic("OOM");
                    _ = game.dirty_chunk_ids.remove(id);
                    _ = game.block_snapshot_tokens.remove(id);
                    if (world.hasChunk(response.coords)) {
                        world.removeChunk(response.coords);
                        game.markChunkAndNeighborsDirty(response.coords);
                        _ = game.dirty_chunk_ids.remove(id);
                    }
                    _ = game.boundary_snapshots.remove(id);
                },
            }
        }
        // Reuse only an authoritative mesh certified by the final block snapshot and with
        // no outstanding local edit in any of its face dependencies.
        for (package.responses.items) |response| {
            if (response.data != .blocks) continue;
            const id = game.layout().encodeChunkCoords(response.coords);
            const token = game.chunk_subscriptions.get(id);
            if (token == null or token != response.subscription_id or (game.chunk_modes.get(id) orelse .blocks) != .blocks) continue;
            const chunk = world.getChunk(response.coords) orelse continue;
            const installed = game.mesh_versions.get(id) orelse continue;
            if (game.boundary_snapshots.get(id)) |boundary| {
                if (boundary.mesh_revision != response.mesh_revision) continue;
            }
            if (chunk.chunk_revision == response.chunk_revision and
                installed.chunk_revision == response.chunk_revision and installed.mesh_revision == response.mesh_revision and
                !world.hasPendingMeshDependency(response.coords))
                _ = game.dirty_chunk_ids.remove(id);
        }
    }

    fn installBoundaries(game: *Game, coords: ChunkCoords, masks: world_engine.BoundaryMasks, revision: u64) void {
        const id = game.layout().encodeChunkCoords(coords);
        if (game.boundary_snapshots.getPtr(id)) |old| {
            if (revision < old.mesh_revision) return;
            old.mesh_revision = revision;
            if (std.meta.eql(old.masks, masks)) return;
            const previous = old.masks;
            old.masks = masks;
            // Keep every accepted plane for future edits and handoffs, even when no
            // currently rendered boundary face depends on the changed occupancy.
            if (!game.boundaryVisibilityChanged(coords, previous, masks)) return;
        } else {
            game.boundary_snapshots.put(game.allocator, id, .{ .masks = masks, .mesh_revision = revision }) catch @panic("OOM");
        }
        game.markChunkDirtyIfLoaded(coords);
    }

    fn boundaryVisibilityChanged(game: *const Game, coords: ChunkCoords, previous: world_engine.BoundaryMasks, updated: world_engine.BoundaryMasks) bool {
        // A promotion can retain a service mesh before its blocks arrive. Without
        // those blocks, keep invalidation conservative until the snapshot certifies it.
        const chunk = game.world.?.chunks.getPtr(game.layout().encodeChunkCoords(coords)) orelse return true;
        if (chunk.flags.is_unreachable) return false;
        for (std.enums.values(Side)) |side| {
            if (game.localMeshNeighbor(coords, side) != null) continue;
            const i = @intFromEnum(side);
            for (chunk.boundaries[i].rows, previous[i].rows, updated[i].rows) |own, before, after| {
                if (own & (before ^ after) != 0) return true;
            }
        }
        return false;
    }

    fn requestChunkMode(game: *Game, coords: ChunkCoords, mode: world_data_service.Representation) void {
        const id = game.layout().encodeChunkCoords(coords);
        if (game.chunk_subscriptions.contains(id) and game.chunk_modes.get(id) == mode) return;
        const token = game.world_client.?.tryRequestChunksInMode(.{ coords[0], coords[1] }, coords[2], coords[2] + 1, mode) catch return;
        game.chunk_subscriptions.put(game.allocator, id, token) catch @panic("OOM");
        game.chunk_modes.put(game.allocator, id, mode) catch @panic("OOM");
    }

    fn wantsBlocks(game: *const Game, coords: ChunkCoords) bool {
        const id = game.layout().encodeChunkCoords(coords);
        return game.pinned_chunks.contains(id) or if (game.last_camera_chunk_coords) |camera| getChunkDistance(game.layout(), id, camera) <= BLOCK_LOAD_RADIUS else true;
    }

    fn refreshPinnedChunks(game: *Game) void {
        game.pinned_chunks.clearRetainingCapacity();
        // A detached debug camera must not evict the frozen player's collision data.
        if (game.player) |*player| {
            const centre = game.layout().getChunkCoords(player.position);
            var dz: i32 = -BLOCK_LOAD_RADIUS;
            while (dz <= BLOCK_LOAD_RADIUS) : (dz += 1) {
                var dy: i32 = -BLOCK_LOAD_RADIUS;
                while (dy <= BLOCK_LOAD_RADIUS) : (dy += 1) {
                    var dx: i32 = -BLOCK_LOAD_RADIUS;
                    while (dx <= BLOCK_LOAD_RADIUS) : (dx += 1) {
                        const coords = game.layout().normalizeChunkCoords(centre +| ChunkCoords{ dx, dy, dz }) orelse continue;
                        game.pinned_chunks.put(game.allocator, game.layout().encodeChunkCoords(coords), {}) catch @panic("OOM");
                    }
                }
            }
        }
        for (game.world.?.pending_operations.items) |pending| {
            for (pending.road_undo.items) |entry| {
                const road_coords, _ = world_module.splitBlockCoords(entry.block);
                game.pinned_chunks.put(game.allocator, game.layout().encodeChunkCoords(road_coords), {}) catch @panic("OOM");
            }
            const coords, const local = world_module.splitBlockCoords(pending.operation.block);
            game.pinned_chunks.put(game.allocator, game.layout().encodeChunkCoords(coords), {}) catch @panic("OOM");
            for (std.enums.values(Side)) |side| {
                const i = @intFromEnum(side);
                if (local[i / 2] != (if (i % 2 == 0) @as(u5, 0) else consts.CHUNK_SIZE - 1)) continue;
                const neighbor = world_module.adjacentChunk(game.layout(), coords, side) orelse continue;
                game.pinned_chunks.put(game.allocator, game.layout().encodeChunkCoords(neighbor), {}) catch @panic("OOM");
            }
        }
    }

    pub fn updateChunksAroundCamera(game: *Game, _: bool) void {
        const camera = game.layout().getChunkCoords(game.engine.active_scene.?.camera.position);
        game.last_camera_chunk_coords = camera;
        game.refreshPinnedChunks();

        // Retain pending commands and their affected face neighbors even after movement.
        var pins = game.pinned_chunks.keyIterator();
        while (pins.next()) |id| game.requestChunkMode(game.layout().decodeChunkId(id.*), .blocks);
        // Closest shells first: all block requests precede new distant mesh requests.
        var radius: i32 = 0;
        while (radius <= game.render_radius) : (radius += 1) {
            var dz = -radius;
            while (dz <= radius) : (dz += 1) {
                var dy = -radius;
                while (dy <= radius) : (dy += 1) {
                    var dx = -radius;
                    while (dx <= radius) : (dx += 1) {
                        if (@max(@abs(dx), @abs(dy), @abs(dz)) != radius) continue;
                        const coords = game.layout().normalizeChunkCoords(camera +| @as(ChunkCoords, .{ dx, dy, dz })) orelse continue;
                        game.requestChunkMode(coords, if (game.wantsBlocks(coords)) .blocks else .mesh);
                    }
                }
            }
        }
        var evicted: std.ArrayList(u32) = .empty;
        defer evicted.deinit(game.allocator);
        var subscriptions = game.chunk_subscriptions.keyIterator();
        while (subscriptions.next()) |id| {
            if (getChunkDistance(game.layout(), id.*, camera) > game.render_radius and !game.pinned_chunks.contains(id.*))
                evicted.append(game.allocator, id.*) catch @panic("OOM");
        }
        for (evicted.items) |id| {
            const token = game.chunk_subscriptions.fetchRemove(id).?.value;
            game.world_client.?.evictChunk(id, token);
            _ = game.chunk_modes.remove(id);
            game.removeChunkByIdIfNeeded(id);
            const coords = game.layout().decodeChunkId(id);
            if (game.world.?.hasChunk(coords)) game.world.?.removeChunk(coords);
            game.markChunkAndNeighborsDirty(coords);
        }
    }

    fn loadChunkIfNeeded(game: *Game, chunk_x: i32, chunk_y: i32, chunk_z: i32) void {
        const world = &game.world.?;

        const chunk_coords = game.layout().normalizeChunkCoords(.{ chunk_x, chunk_y, chunk_z }) orelse return;
        const chunk_id = game.layout().encodeChunkCoords(chunk_coords);

        if (game.loaded_chunk_ids.contains(chunk_id)) {
            return;
        }

        if (!world.hasChunk(chunk_coords)) return;

        game.loaded_chunk_ids.put(game.allocator, chunk_id, {}) catch @panic("OOM");
        game.markChunkDirtyIfLoaded(chunk_coords);
    }

    fn removeChunkIfNeeded(game: *Game, chunk_coords: ChunkCoords) void {
        game.removeChunkByIdIfNeeded(game.layout().encodeChunkCoords(chunk_coords));
    }

    fn removeChunkByIdIfNeeded(game: *Game, chunk_id: u32) void {
        _ = game.block_snapshot_tokens.remove(chunk_id);
        _ = game.dirty_chunk_ids.remove(chunk_id);
        _ = game.mesh_versions.remove(chunk_id);
        _ = game.boundary_snapshots.remove(chunk_id);
        if (game.loaded_chunk_ids.contains(chunk_id)) {
            _ = game.loaded_chunk_ids.remove(chunk_id);
            game.engine.active_scene.?.voxel_grid.removeChunk(game.layout().decodeChunkId(chunk_id));
        }
    }

    fn updateBlockTool(game: *Game) void {
        const input = game.engine.input_controller;
        defer game.tool_commands.clearRetainingCapacity();
        if (!input.focused or input.focus_changed) {
            game.block_interaction.loseFocus();
            return;
        }
        if (game.control_mode == .player) {
            game.updatePlayerBlockTool();
            return;
        }
        for (game.tool_commands.items) |command| game.editBlockInView(command);
    }

    fn updatePlayerBlockTool(game: *Game) void {
        const interaction = &game.block_interaction;
        const world = if (game.world) |*world| world else return;
        interaction.finishReconciliation(world.pending_operations.items);
        const camera = game.engine.active_scene.?.camera;
        const mode = game.blockMode();
        const target = (block_targeting.findTarget(world, camera.position, camera.forwardDirection(), mode) catch null);
        if (interaction.requested) |source| {
            interaction.requested = null;
            // Observer edits may still be reconciling when returning to the player.
            if (interaction.pending != null or world.pending_operations.items.len != 0) return;
            const block = target orelse return;
            const coords, const local = world_module.splitBlockCoords(block);
            const chunk = world.getChunk(coords) orelse return;
            interaction.holding = .{
                .source = source,
                .operation = .{
                    .block = block,
                    .action = if (interaction.inventory) |material| .{ .put = material } else .remove,
                    .player = .{ .id = game.player_id, .expected_sequence = chunk.cell_changes.sequence },
                },
                .material = chunk.content.getBlock(local),
            };
            // The press happened during this frame; its preceding delta is not work.
            return;
        }
        const hold = if (interaction.holding) |*hold| hold else return;
        if (target == null or !std.meta.eql(target.?, hold.operation.block)) {
            interaction.cancelHold();
            return;
        }
        const coords, const local = world_module.splitBlockCoords(hold.operation.block);
        const chunk = world.getChunk(coords) orelse {
            interaction.cancelHold();
            return;
        };
        if (!chunk.cell_changes.unchangedSince(transformations.index(local), hold.operation.player.?.expected_sequence) or chunk.content.getBlock(local) != hold.material) {
            interaction.cancelHold();
            return;
        }
        if (hold.operation.action == .put) if (game.player) |*player| {
            if (terrain_collision.overlapsBlock(player.body, player.position, game.layout(), hold.operation.block)) {
                interaction.cancelHold();
                return;
            }
        };
        const elapsed = game.engine.frame_delta;
        if (std.math.isFinite(elapsed) and elapsed > 0) hold.elapsed += elapsed;
        if (hold.elapsed < hold.duration()) return;

        const operation = hold.operation;
        const result = world.tryOperation(operation);
        interaction.completePrediction(result);
        if (result.status != .success) {
            game.showBlockEditError(result);
            return;
        }
        if (game.player) |*player| player.terrainChanged();
        game.clearBlockFocus();
        game.markChunksAroundBlockDirty(operation.block);
    }

    fn toggleBlockMode(game: *Game) void {
        game.block_mode = if (game.block_mode == .removing) .putting else .removing;
        game.clearBlockFocus();
        std.debug.print("block mode: {s}\n", .{@tagName(game.block_mode)});
    }

    fn clearBlockFocus(game: *Game) void {
        game.placement_validation = null;
        game.current_placement_preview = null;
        if (game.engine.active_scene) |scene| {
            scene.highlighted_block = null;
            scene.block_overlays = .{};
        }
    }

    fn updateBlockFocus(game: *Game) void {
        const scene = game.engine.active_scene orelse return;
        scene.highlighted_block = null;
        scene.block_overlays = .{};
        var preview: ?placement_preview.Preview = null;
        defer {
            if (preview) |current| {
                scene.block_overlays = current.overlays(&game.world.?);
            } else {
                game.placement_validation = null;
            }
            game.current_placement_preview = preview;
        }
        const input = game.engine.input_controller;
        if (!input.focused or input.focus_changed) return;
        const world = if (game.world) |*world| world else return;
        const camera = scene.camera;
        const mode = game.blockMode();
        const material = game.heldMaterial() orelse game.selected_material;
        const block = (block_targeting.findTarget(world, camera.position, camera.forwardDirection(), mode) catch return) orelse return;
        if (mode == .removing) {
            scene.highlighted_block = block;
            return;
        }
        if (game.placement_validation == null or
            !std.meta.eql(game.placement_validation.?.block, block) or
            game.placement_validation.?.material != material or
            !game.placement_validation.?.window.isCurrent(world))
        {
            game.placement_validation = .{
                .block = block,
                .material = material,
                .window = world.validationWindow(block),
                .result = world.previewOperation(.{ .block = block, .action = .{ .put = material } }),
            };
        }
        preview = .{ .block = block, .material = material, .result = game.placement_validation.?.result };
        if (game.player) |*player| preview.?.overlaps_player = terrain_collision.overlapsBlock(player.body, player.position, game.layout(), block);
    }

    fn queueBlockAction(game: *Game, action: BlockAction) void {
        if (game.control_mode != .spectator) return;
        // Commands capture the active mode at press time, like their material.
        if ((action == .place) != (game.block_mode == .putting)) return;
        if (game.tool_commands.items.len >= 64) {
            game.block_action_error.show("Too many pending edits. Try again shortly.", game.engine.time);
            return;
        }
        game.tool_commands.append(game.allocator, action) catch |err| {
            std.debug.print("can't queue block edit: {s}\n", .{@errorName(err)});
        };
    }

    fn editBlockInView(game: *Game, action: BlockAction) void {
        const world = if (game.world) |*world| world else return;
        world.last_edit_result = null;
        const camera = game.engine.active_scene.?.camera;
        const edited_block = (block_targeting.findTarget(world, camera.position, camera.forwardDirection(), switch (action) {
            .remove => .removing,
            .place => .putting,
        }) catch {
            if (DEBUG) std.debug.print("can't target block: chunks aren't received yet\n", .{});
            return;
        }) orelse return;
        if (action == .place) if (game.player) |*player| {
            if (terrain_collision.overlapsBlock(player.body, player.position, game.layout(), edited_block)) {
                game.block_action_error.show(block_diagnostics.player_overlap_message, game.engine.time);
                return;
            }
        };
        const result = world.tryOperation(.{ .block = edited_block, .action = switch (action) {
            .remove => .remove,
            .place => |material| .{ .put = material },
        } });
        if (result.status != .success) {
            game.showBlockEditError(result);
            return;
        }
        if (game.player) |*player| player.terrainChanged();

        if (DEBUG) {
            std.debug.print("{s} block {any}\n", .{ @tagName(action), edited_block });
        }

        game.markChunksAroundBlockDirty(edited_block);
    }

    fn showBlockEditError(game: *Game, result: world_module.EditResult) void {
        var buffer: [block_diagnostics.message_capacity]u8 = undefined;
        if (block_diagnostics.errorMessageForResult(result, &buffer)) |message| {
            game.block_action_error.show(message, game.engine.time);
        }
    }

    /// Invalidates the edited chunk and face neighbors touched by a boundary edit.
    fn markChunksAroundBlockDirty(game: *Game, block: [3]u32) void {
        const chunk_coords, const local = world_module.splitBlockCoords(block);

        game.markChunkDirtyIfLoaded(chunk_coords);

        for (std.enums.values(Side)) |side| {
            const i = @intFromEnum(side);
            if (local[i / 2] != (if (i % 2 == 0) @as(u5, 0) else consts.CHUNK_SIZE - 1)) continue;
            const neighbor = world_module.adjacentChunk(game.layout(), chunk_coords, side) orelse continue;
            game.markChunkDirtyIfLoaded(neighbor);
        }
    }

    /// Compare the reconciled occupancy, including pending local edits. A snapshot
    /// without changed boundary planes cannot change a neighboring chunk's faces.
    fn markChunkSnapshotDirty(game: *Game, chunk_coords: ChunkCoords, previous: ?world_engine.BoundaryMasks) void {
        game.markChunkDirtyIfLoaded(chunk_coords);
        const updated = game.world.?.getChunk(chunk_coords).?.boundaries;
        for (std.enums.values(Side)) |side| {
            const i = @intFromEnum(side);
            if (previous) |masks| {
                if (std.meta.eql(masks[i], updated[i])) continue;
            }
            if (world_module.adjacentChunk(game.layout(), chunk_coords, side)) |coords| game.markChunkDirtyIfLoaded(coords);
        }
    }

    /// Loading or dropping a local meshing dependency can affect every face neighbor.
    fn markChunkAndNeighborsDirty(game: *Game, chunk_coords: ChunkCoords) void {
        game.markChunkDirtyIfLoaded(chunk_coords);
        for (std.enums.values(Side)) |side| {
            if (world_module.adjacentChunk(game.layout(), chunk_coords, side)) |coords| game.markChunkDirtyIfLoaded(coords);
        }
    }

    fn markChunkDirtyIfLoaded(game: *Game, chunk_coords: ChunkCoords) void {
        const chunk_id = game.layout().encodeChunkCoords(chunk_coords);
        if (game.loaded_chunk_ids.contains(chunk_id)) {
            game.dirty_chunk_ids.put(game.allocator, chunk_id, {}) catch @panic("OOM");
        }
    }

    /// Run once after edits, responses, and camera loading, before the frame's GPU upload.
    fn rebuildDirtyChunks(game: *Game) void {
        for (game.world.?.changed_road_chunks.items) |id| game.markChunkDirtyIfLoaded(game.layout().decodeChunkId(id));
        game.world.?.changed_road_chunks.clearRetainingCapacity();
        const voxel_grid = game.engine.active_scene.?.voxel_grid;
        const world = &game.world.?;
        defer game.dirty_chunk_ids.clearRetainingCapacity();

        var iterator = game.dirty_chunk_ids.keyIterator();
        while (iterator.next()) |chunk_id| {
            const coords = game.layout().decodeChunkId(chunk_id.*);
            const chunk = world.getChunk(coords) orelse continue;
            // Retained blocks may still receive neighbor changes during a handoff.
            _ = game.mesh_versions.remove(chunk_id.*);
            voxel_grid.removeChunk(coords);
            if (chunk.content == .blocks and !chunk.flags.is_unreachable) {
                var climate: world_engine.ClimateMap = @splat(@splat(.temperate));
                if (game.world_data) |service| service.preparedGenerator().fillClimateMap(.{ coords[0], coords[1] }, &climate);
                voxel_grid.appendChunk(.{
                    .chunk_coords = coords,
                    .chunk_side_data = world_engine.extractChunkGeometryWithClimate(game.allocator, chunk, game.meshNeighbors(coords), &climate),
                });
            }
        }
    }
    fn meshNeighbors(game: *const Game, coords: ChunkCoords) world_engine.BoundaryMasks {
        const cached = game.boundary_snapshots.get(game.layout().encodeChunkCoords(coords));
        // A missing dependency is temporarily air. Service snapshots normally supply
        // every plane with the blocks, including neighbors beyond the local core.
        var neighbors: world_engine.BoundaryMasks = if (cached) |snapshot| snapshot.masks else @splat(.{});
        for (std.enums.values(Side)) |side| {
            if (game.localMeshNeighbor(coords, side)) |neighbor| {
                neighbors[@intFromEnum(side)] = neighbor.boundaries[@intFromEnum(side.getOpposite())];
            }
        }
        return neighbors;
    }

    fn localMeshNeighbor(game: *const Game, coords: ChunkCoords, side: Side) ?*const WorldChunk {
        const adjacent = world_module.adjacentChunk(game.layout(), coords, side) orelse return null;
        const adjacent_id = game.layout().encodeChunkCoords(adjacent);
        // A demoted neighbor may retain blocks for its display, but those blocks
        // no longer receive updates. Its authoritative fallback plane is newer.
        if (game.chunk_modes.get(adjacent_id) == .mesh) return null;
        return game.world.?.chunks.getPtr(adjacent_id);
    }
};

/// Consumes the response, including stale and evicted snapshots. Acknowledgements are
/// independent of subscription lifetime so pending edits can always be retired.
fn applyChunkResponse(world: *World, subscriptions: *const std.AutoHashMapUnmanaged(u32, u64), response: ChunkResponse) bool {
    if (response.operation) |result| world.acknowledgeOperationResult(result.request_id, result.status);
    const token = subscriptions.get(world.layout.encodeChunkCoords(response.coords));
    if (token == null or token != response.subscription_id) {
        response.deinit(world.allocator);
        return false;
    }
    if (response.data != .blocks) return false;
    world.insertChunk(response.coords, response.data.blocks.chunk) catch {
        response.deinit(world.allocator);
        return false;
    };
    return true;
}

const BlockAction = union(enum) {
    remove,
    place: voxel_chunk_module.BlockType,
};

fn initWorld(game: *Game) !void {
    const generator = if (game.persistence_store) |store| try savedGenerator(store.descriptor) else world_generator.WorldGenerator{ .natural = .{ .seed = 12345 } };
    game.world_data = if (game.persistence_store) |store|
        try WorldDataService.createPersistent(game.engine.io, game.allocator, game.engine.active_scene.?.layout, generator, store, .{})
    else
        try WorldDataService.create(game.engine.io, game.allocator, game.engine.active_scene.?.layout, generator);
    game.world = try World.init(game.allocator, game.engine.active_scene.?.layout);
    game.world.?.playable_y_inset = game.world_data.?.preparedGenerator().playableYInset();
    game.world.?.immutable_floor = .{ .context = game.world_data.?.preparedGenerator(), .immutable_at = canonicalFloorAt };
    game.world.?.pending_operation_limit = 256;
    game.world.?.simulation_tick = game.world_data.?.restoredTick();
    game.world_client = try game.world_data.?.createClient();
}

fn canonicalFloorAt(context: *const anyopaque, block: [3]u32) bool {
    const generator: *const world_generator.PreparedWorldGenerator = @ptrCast(@alignCast(context));
    return block[2] < generator.deeprockThickness(block[0], block[1]);
}

fn savedGenerator(bytes: []const u8) !world_generator.WorldGenerator {
    const descriptor = try persistence_format.decodeDescriptor(bytes);
    return switch (descriptor.generator_id) {
        persistence_format.generator_id => switch (descriptor.generator_version) {
            persistence_format.generator_version => switch (try persistence_format.decodeGeneratorSettings(descriptor.settings)) {
                .flat => .{ .flat_seeded = descriptor.seed },
                .natural => |settings| .{ .natural = .{ .seed = descriptor.seed, .settings = settings } },
            },
            else => error.UnsupportedVersion,
        },
        else => error.UnsupportedGenerator,
    };
}

fn openSelectedWorld(init: std.process.Init, options: persistence_launch.Options, path: [:0]const u8) !persistence_storage.Store {
    if (options.mode == .open) return persistence_storage.Store.open(init.gpa, path, .{});
    var uuid: [16]u8 = undefined;
    try init.io.randomSecure(&uuid);
    const settings = persistence_format.encodeNaturalSettings(.{});
    const descriptor = try persistence_format.encodeDescriptor(init.gpa, .{
        .dimensions = consts.WORLD_SETTINGS.size_in_chunks,
        .generator_id = persistence_format.generator_id,
        .generator_version = persistence_format.generator_version,
        .seed = 12345,
        .settings = &settings,
    });
    defer init.gpa.free(descriptor);
    const global = persistence_format.encodeGlobal(0);
    return persistence_storage.Store.create(init.gpa, path, .{
        .world_uuid = uuid,
        .descriptor = descriptor,
        .global = &global,
        .players = &.{},
        .player_count = 0,
    }, .{});
}

/// Chebyshev distance between the chunk and the camera chunk, in chunks. The x axis wraps.
fn getChunkDistance(layout: *const WorldLayout, chunk_id: u32, camera_chunk_coords: ChunkCoords) u64 {
    const delta = layout.getChunkDelta(layout.decodeChunkId(chunk_id), camera_chunk_coords);
    return @reduce(.Max, @abs(delta));
}

/// Returns neighbors indexed by Side; null items are outside the stored world.
/// Returns null if a neighbor has not been received from the world-data thread yet.
fn getSurroundingChunks(world: *const World, coords: ChunkCoords) ?[6]?WorldChunk {
    var result: [6]?WorldChunk = @splat(null);
    for (std.enums.values(Side)) |side| {
        const neighbor = world_module.adjacentChunk(world.layout, coords, side) orelse continue;
        result[@intFromEnum(side)] = world.getChunk(neighbor) orelse return null;
    }
    return result;
}

const ChunkBox = struct {
    start: ChunkCoords,
    end: ChunkCoords, // end is inclusive

    pub fn isContainingChunk(self: *const ChunkBox, chunk: ChunkCoords) bool {
        return @reduce(.And, chunk >= self.start) and
            @reduce(.And, chunk <= self.end);
    }
};

fn getBoxAroundChunk(chunk_coords: ChunkCoords, radius: i32) ChunkBox {
    std.debug.assert(radius >= 0);
    const delta: ChunkCoords = @splat(radius);
    // Query only representable coordinates when the camera reaches a signed limit.
    return .{
        .start = chunk_coords -| delta,
        .end = chunk_coords +| delta,
    };
}

fn fitBoxIntoWorld(layout: *const WorldLayout, box: ChunkBox) ChunkBox {
    // X wraps, so only y/z are clipped to the stored world.
    return .{
        .start = @max(box.start, ChunkCoords{ std.math.minInt(i32), 0, 0 }),
        .end = @min(box.end, ChunkCoords{ std.math.maxInt(i32), layout.size_in_chunks[1] - 1, layout.size_in_chunks[2] - 1 }),
    };
}

pub fn main(init: std.process.Init) !void {
    const allocator = init.gpa;
    const args = try init.minimal.args.toSlice(init.arena.allocator());
    const options = persistence_launch.parse(args[1..]) catch |err| {
        std.debug.print("Invalid arguments: {s}\n{s}\n", .{ @errorName(err), persistence_launch.usage });
        return err;
    };
    if (options.help) {
        std.debug.print("{s}\n", .{persistence_launch.usage});
        return;
    }
    // Resolve before asset startup changes cwd; opening and creation remain distinct.
    const original_cwd = try std.process.currentPathAlloc(init.io, allocator);
    defer allocator.free(original_cwd);
    const resolved_path = try std.fs.path.resolve(allocator, &.{ original_cwd, options.path });
    defer allocator.free(resolved_path);
    const save_path = try allocator.dupeZ(u8, resolved_path);
    defer allocator.free(save_path);
    var store: ?persistence_storage.Store = if (options.mode == .ephemeral) null else openSelectedWorld(init, options, save_path) catch |err| {
        std.debug.print("Cannot {s} world at {s}: {s}. Existing save files are retained.\nUse --create-world PATH only to create a new world.\n", .{ if (options.mode == .create) "create" else "open", save_path, @errorName(err) });
        return err;
    };
    defer if (store) |*saved| saved.deinit();
    if (options.mode == .ephemeral) std.debug.print("Ephemeral world: changes will not be saved.\n", .{});

    // Change current working directory to where the executable is located.
    {
        const path = std.process.executableDirPathAlloc(init.io, allocator) catch ".";
        defer allocator.free(path);
        const pathz = try allocator.dupeZ(u8, path);
        defer allocator.free(pathz);
        const result = std.posix.system.chdir(pathz);
        if (result != 0) {
            std.debug.print("Failed to change directory to {s}: {}\n", .{ pathz, result });
            // ignoring error and trying to continue work in the current directory
        }
    }

    var window_context = try WindowContext.init(allocator);
    defer window_context.deinit();

    const game: *Game = try .init(allocator);
    defer game.deinit();
    game.player_id = options.player_id;
    game.persistence_store = if (store) |*saved| saved else null;

    const engine = Engine.init(
        init.io,
        allocator,
        .{
            .window_context = window_context,
            .content_dir = content_dir,
            .zgui = true,
        },
        .{
            .argument = game,
            .onUpdate = onUpdate,
            .onRender = onRender,
            .onRenderOverlay3D = onRenderOverlay3D,
            .onUIKeyPress = onUIKeyPress,
            .onKeyPress = onKeyPress,
            .onKeyRelease = onKeyRelease,
            .onMouseButtonPress = onMouseButtonPress,
            .onMouseButtonRelease = onMouseButtonRelease,
            .onCloseRequest = onCloseRequest,
            .onPauseChanged = onPauseChanged,
            .onGameplayInputChanged = onGameplayInputChanged,
        },
    );
    game.engine = engine;
    game.held_block_renderer = held_block.Renderer.init(
        engine.gctx,
        engine.bind_group_layouts.regular.bind_group_layout_handle,
        engine.gctx.swapchain_descriptor.format,
    );
    game.player_skin = try engine.loadTexture(content_dir ++ "/default-skin.png", .{});
    game.empty_hands_renderer = empty_hands.Renderer.init(
        engine.gctx,
        engine.bind_group_layouts.regular,
        game.player_skin.?,
        engine.texture_sampler,
        engine.gctx.swapchain_descriptor.format,
    );

    const man_model_id = id: {
        const loader = try engine.initLoader("man/man.gltf");
        defer loader.deinit();

        const object = loader.findFirstObjectWithMesh().?;
        break :id try engine.loadModel(&loader, object, .{
            .mesh_y_up = true,
            .animations = &.{"walkLikeMan"},
        });
    };

    const settings: @import("engine").WorldSettings = if (store) |*saved|
        .{ .size_in_chunks = (try persistence_format.decodeDescriptor(saved.descriptor)).dimensions }
    else
        consts.WORLD_SETTINGS;
    const scene = try engine.createScene(settings);
    defer scene.deinit();
    defer game.stopWorkers();

    try initWorld(game);
    const body: terrain_collision.Body = .{};
    const saved_player = game.world_data.?.restoredPlayer(game.player_id);
    const initial_xy: [2]f64 = if (game.world_data.?.preparedGenerator().firstStart()) |start| .{
        @as(f64, @floatFromInt(start[0])) - @as(f64, @floatFromInt(scene.layout.origin_chunk[0])) * consts.CHUNK_SIZE + 0.5,
        @as(f64, @floatFromInt(start[1])) - @as(f64, @floatFromInt(scene.layout.origin_chunk[1])) * consts.CHUNK_SIZE + 0.5,
    } else .{ -2.06, -2.96 };
    const spawn = if (saved_player) |saved|
        try game.world_client.?.resolveRestoredPosition(saved.feet, body)
    else
        try game.world_client.?.findStandingSpace(.{
            .preferred_xy = initial_xy,
            .clearance_size = .{ 2, 2, 3 },
            .support_size = .{ 2 * body.half_width, 2 * body.half_width },
            .search_radius = 8,
        });
    game.player = PlayerController.init(allocator, spawn);
    if (saved_player) |saved| {
        game.player.?.yaw = saved.yaw;
        game.player.?.pitch = saved.pitch;
        game.block_interaction.inventory = if (saved.inventory) |raw| @enumFromInt(raw) else null;
        // Fresh controller state discards velocity, climbing, and transient history.
    } else game.player.?.grounded = true;
    game.checkpoint();
    game.simulation = try SimulationWorker.create(game.world_data.?);
    scene.spectator_enabled = false;
    engine.input_controller.cursor_capture = .always;
    game.player.?.applyCamera(scene.camera);
    // edge of the world:
    // scene.camera.updatePosition(.{ -8192.0, -4096.0, 0 });

    // -- Skybox (old) --

    // const skybox_model = try engine.loadSkyBoxModel("skybox/cubemaps_skybox.png");

    // _ = try scene.addSkyBoxObject(.{
    //     .model = skybox_model,
    // });

    // -- Skybox (cubemap) --

    const skybox_cubemap_model = try engine.loadSkyBoxCubemapModel(.{
        "skybox/skybox/right.jpg",
        "skybox/skybox/left.jpg",
        "skybox/skybox/top.jpg",
        "skybox/skybox/bottom.jpg",
        "skybox/skybox/front.jpg",
        "skybox/skybox/back.jpg",
    });

    _ = try scene.setSkyBoxCubemapObject(.{
        .model = skybox_cubemap_model,
    });

    // ---

    const window_block_model = try engine.loadWindowBoxModel("window-block/wb-texture.png");
    _ = window_block_model; // The window-box placement example below is disabled.

    // _ = man_model_id;
    try game.saved_game_objects.put(allocator, "man_1", try scene.addObject(.{
        .model_id = man_model_id,
        .position = .{ -2, 0, 6 },
        .parent = null,
        .animation_name = "walkLikeMan",
    }));

    try game.saved_game_objects.put(allocator, "man_2", try scene.addObject(.{
        .model_id = man_model_id,
        .position = .{ 4, 0, 8 },
        .parent = null,
        .animation_name = "walkLikeMan",
    }));

    // -- Tube data for coordinates --

    var tube_data = try tube.initUnitTube(allocator);
    defer tube_data.deinit(allocator);
    const tube_model = try engine.loadPrimitive(tube_data);

    // -- Coordinates --

    {
        const group = try scene.addGroup();

        try game.saved_game_object_groups.put(allocator, "coordinates", group);

        group.setPosition(.{ 0, 0, 0 });

        const tube_x = try scene.addPrimitiveObject(.{
            .model = tube_model,
            .position = .{ 0.5 + tube.M, 0, 0 },
        });
        tube_x.debug.color = .{ 1, 0, 0, 1 };

        const tube_y = try scene.addPrimitiveObject(.{
            .model = tube_model,
            .position = .{ 0, 0.5 + tube.M, 0 },
        });
        tube_y.setRotation(zmath.quatFromAxisAngle(.{ 0, 0, 1, 0 }, math.pi / 2.0));
        tube_y.debug.color = .{ 0, 1, 0, 1 };

        const tube_z = try scene.addPrimitiveObject(.{
            .model = tube_model,
            .position = .{ 0, 0, 0.5 + tube.M },
        });
        tube_z.setRotation(zmath.quatFromAxisAngle(.{ 0, 1, 0, 0 }, math.pi / 2.0));
        tube_z.debug.color = .{ 0, 0, 1, 1 };

        try group.addObject(tube_x);
        try group.addObject(tube_y);
        try group.addObject(tube_z);
    }

    // -- Light --

    try scene.addDirectionalLight(.{
        .direction = zmath.normalize3(zmath.Vec{ 0.2, 0.3, -1, 1 }),
        .color = .{ 1, 1, 1, 1 },
        .intensity = 1.0,
    });

    // -- ZGui --

    zgui_utils.zguiInit(allocator, window_context.window, engine.gctx.device, content_dir);
    defer zgui_utils.zguiDeinit();

    // -- Game loop --

    try engine.runLoop();
}

fn onCloseRequest(_: *Engine, game_opaque: *anyopaque) bool {
    const game: *Game = @ptrCast(@alignCast(game_opaque));
    if (game.persistence_store == null or game.close_ready) return true;
    game.beginExit();
    return false;
}

fn onGameplayInputChanged(engine: *Engine, game_opaque: *anyopaque) void {
    const game: *Game = @ptrCast(@alignCast(game_opaque));
    game.block_interaction.loseFocus();
    game.tool_commands.clearRetainingCapacity();
    game.jump_requested = false;
    if (game.player) |*player| {
        player.resetJumpInput();
        if (!engine.gameplay_input_blocked) player.terrainChanged();
    }
    game.clearBlockFocus();
}

fn onPauseChanged(engine: *Engine, game_opaque: *anyopaque) void {
    const game: *Game = @ptrCast(@alignCast(game_opaque));
    if (game.simulation) |simulation| {
        if (engine.paused or game.exit_requested) simulation.pauseDispatch() else simulation.resumeDispatch();
    }
}

fn onUpdate(engine: *Engine, game_opaque: *anyopaque) void {
    const game: *Game = @ptrCast(@alignCast(game_opaque));

    if (game.saved_game_objects.get("man_1")) |obj| {
        obj.setRotation(zmath.quatFromRollPitchYaw(0, 0, @floatCast(engine.time)));
    }
    if (game.saved_game_objects.get("man_2")) |obj| {
        obj.setRotation(zmath.quatFromRollPitchYaw(0, 0, @floatCast(-engine.time)));
    }
    // if (game.saved_game_object_groups.get("coordinates")) |group| {
    //     group.setPosition(.{ 0, 0, math.sin(engine.time) * 10 });
    // }

    game.updateWorld();
    game.updateHeldMotion();
}

fn onKeyPress(engine: *Engine, key_params: KeyParams, game_opaque: *anyopaque) void {
    const game: *Game = @ptrCast(@alignCast(game_opaque));
    if (!engine.window_context.window.getAttribute(.focused)) return;

    handleKeyPress(game, key_params);
}

fn onUIKeyPress(engine: *Engine, key_params: KeyParams, game_opaque: *anyopaque) bool {
    if (!engine.input_controller.focused) return false;
    const game: *Game = @ptrCast(@alignCast(game_opaque));
    return handleUIKeyPress(game, key_params);
}

fn handleUIKeyPress(game: *Game, key_params: KeyParams) bool {
    switch (key_params.key) {
        .escape => {
            game.setOverlay(if (game.overlay == .none) .menu else .none);
            return true;
        },
        .m => {
            if (game.overlay != .menu) game.setOverlay(if (game.overlay == .world_map) .none else .world_map);
            return true;
        },
        else => return false,
    }
}

fn handleKeyPress(game: *Game, key_params: KeyParams) void {
    if (game.exit_requested or game.engine.gameplay_input_blocked) return;
    switch (key_params.key) {
        .x => if (game.control_mode == .spectator) game.queueBlockAction(.remove),
        .e => if (!key_params.mods.control) {
            if (game.control_mode == .player) game.block_interaction.press(.key) else game.queueBlockAction(.{ .place = game.selected_material });
        },
        .one, .two, .three, .four, .five, .six, .seven, .eight => {
            if (game.control_mode != .spectator) return;
            game.selected_material = switch (key_params.key) {
                .one => .dirt,
                .two => .crushed_stone,
                .three => .tree_trunk,
                .four => .planks,
                .five => .rebar,
                .six => .reinforced_concrete,
                .seven => .country_road_solid,
                .eight => .country_road_adaptive,
                else => unreachable,
            };
            std.debug.print("selected material: {s}\n", .{@tagName(game.selected_material)});
        },
        .q => game.toggleControlMode(),
        .tab => if (game.control_mode == .spectator) game.toggleBlockMode(),
        // A press/release occurring between frames must still produce one jump.
        .space => if (game.control_mode == .player) {
            game.jump_requested = true;
        },
        else => {},
    }
}

fn onKeyRelease(_: *Engine, params: KeyParams, game_opaque: *anyopaque) void {
    const game: *Game = @ptrCast(@alignCast(game_opaque));
    handleKeyRelease(game, params);
}

fn handleKeyRelease(game: *Game, params: KeyParams) void {
    if (params.key == .e) game.block_interaction.release(.key);
}

fn onMouseButtonRelease(_: *Engine, params: MouseButtonParams, game_opaque: *anyopaque) void {
    const game: *Game = @ptrCast(@alignCast(game_opaque));
    handleMouseButtonRelease(game, params);
}

fn handleMouseButtonRelease(game: *Game, params: MouseButtonParams) void {
    if (params.button == .left) game.block_interaction.release(.mouse);
}

fn onMouseButtonPress(engine: *Engine, params: MouseButtonParams, game_opaque: *anyopaque) void {
    const game: *Game = @ptrCast(@alignCast(game_opaque));
    if (!engine.window_context.window.getAttribute(.focused)) return;
    handleMouseButtonPress(game, params);
}

fn handleMouseButtonPress(game: *Game, params: MouseButtonParams) void {
    if (game.exit_requested or game.engine.gameplay_input_blocked) return;
    if (game.control_mode == .player) {
        if (params.button == .left) game.block_interaction.press(.mouse);
        return;
    }
    if (params.button == .left) game.queueBlockAction(switch (game.block_mode) {
        .putting => .{ .place = game.selected_material },
        .removing => .remove,
    });
}

fn onRenderOverlay3D(engine: *Engine, pass: wgpu.RenderPassEncoder, game_opaque: *anyopaque) void {
    const game: *Game = @ptrCast(@alignCast(game_opaque));
    if (game.heldMaterial()) |material| {
        if (game.held_block_renderer) |*renderer| {
            if (engine.active_scene) |scene| renderer.draw(
                engine.gctx,
                pass,
                engine.bind_group_minecraft_texture.wgpu_bind_group,
                scene.camera.clip_from_view,
                material,
                held_block_pose.withMotion(game.held_motion.offset),
            );
        }
    } else if (game.control_mode == .player) {
        if (game.empty_hands_renderer) |*renderer| {
            if (engine.active_scene) |scene| renderer.draw(engine.gctx, pass, scene.camera.clip_from_view, game.held_motion.offset);
        }
    }
}

fn onRender(engine: *Engine, _: wgpu.RenderPassEncoder, game_opaque: *anyopaque) void {
    const game: *Game = @ptrCast(@alignCast(game_opaque));
    if (game.overlay == .none) {
        block_messages.draw(game.current_placement_preview, &game.block_action_error, engine.time);
        drawCrosshair();
    }
    if (game.overlay == .world_map) if (game.world_data) |service| if (engine.active_scene) |scene| {
        game.handleMapAction(game.map_state.draw(game.allocator, engine.gctx, service.preparedGenerator(), game.mapView(scene)));
    };
    drawPersistence(game);
    if (game.overlay == .menu) if (menu.draw(engine.paused)) |action| game.handleMenuAction(action);
}

fn drawPersistence(game: *Game) void {
    if (game.persistence_store == null) return;
    const status = game.world_data.?.persistenceStatus();
    if (!game.exit_requested and !status.overdue and status.phase != .failed) return;
    const screen = zgui.io.getDisplaySize();
    zgui.setNextWindowPos(.{ .x = screen[0] / 2, .y = screen[1] / 2, .pivot_x = 0.5, .pivot_y = 0.5 });
    _ = zgui.begin("World saving", .{ .flags = .{ .always_auto_resize = true, .no_collapse = true, .no_saved_settings = true } });
    defer zgui.end();
    if (game.exit_requested) {
        zgui.textUnformatted(if (game.exit_intent == null or status.pending_commands != 0) "Finishing pending actions..." else if (status.phase == .compacting) "Finalizing save..." else "Saving...");
        const delayed = game.engine.real_time - game.exit_progress_at >= 5;
        if (status.phase == .failed or delayed) {
            if (status.error_name) |name| zgui.text("Save failed: {s}", .{name}) else zgui.textUnformatted("Still waiting for storage or pending actions...");
            if (game.exit_intent != null and status.phase == .failed and !status.active) {
                if (zgui.button("Retry", .{})) {
                    game.exit_intent = game.world_data.?.requestSave(true);
                    game.exit_progress_at = game.engine.real_time;
                }
            } else if (zgui.button("Keep waiting", .{})) game.exit_progress_at = game.engine.real_time;
            zgui.sameLine(.{});
            if (zgui.button("Cancel exit", .{})) game.cancelExit();
            zgui.textUnformatted("Quitting now may lose changes since the last durable save.");
            if (zgui.button("Quit without saving", .{})) {
                // Explicit user choice: do not join a potentially stalled disk worker
                // or recycle memory it owns. Recovery uses the crash-safe WAL contract.
                std.process.exit(0);
            }
        }
    } else if (status.error_name) |name| {
        zgui.text("Saving failed: {s}", .{name});
        zgui.textUnformatted("Unsaved changes remain in memory.");
    } else {
        zgui.textUnformatted("Saving is behind. World-changing actions may wait while saving catches up.");
    }
}

test "menu cancels pending controls and pauses world time and background simulation" {
    var fixture: StreamingTest = .{};
    fixture.init();
    defer fixture.deinit();
    const game = &fixture.game;
    try fixture.preparePlayerToolTest();
    const service = try WorldDataService.create(std.testing.io, std.testing.allocator, &test_layout, .flat);
    defer service.destroy();
    // Use the real admission gate without starting the NPC's startup/cadence loop.
    var simulation: SimulationWorker = .{ .client = try service.createClient(), .worker = undefined };
    game.simulation = &simulation;
    game.player = PlayerController.init(std.testing.allocator, .{ 0, 0, 0 });
    handleKeyPress(game, .{ .key = .e, .mods = .{} });
    game.updateBlockTool();
    try std.testing.expect(game.block_interaction.holding != null);
    // Pausing alone gates simulation without opening UI or canceling controls.
    fixture.engine.setPaused(true);
    try std.testing.expect(simulation.paused.load(.acquire));
    try std.testing.expectEqual(.none, game.overlay);
    try std.testing.expect(!fixture.engine.gameplay_input_blocked);
    try std.testing.expect(game.block_interaction.holding != null);
    fixture.engine.setPaused(false);
    try std.testing.expect(!simulation.paused.load(.acquire));
    game.jump_requested = true;
    fixture.engine.frame_delta = 0.125;
    game.advanceWorldClock();
    const tick = game.world.?.simulation_tick;
    const fraction = game.fractional_ticks;
    try std.testing.expect(handleUIKeyPress(game, .{ .key = .escape, .mods = .{} }));
    try std.testing.expectEqual(.menu, game.overlay);
    try std.testing.expect(fixture.engine.paused);
    try std.testing.expect(fixture.engine.gameplay_input_blocked);
    try std.testing.expect(simulation.paused.load(.acquire));
    try std.testing.expectEqual(null, game.block_interaction.holding);
    try std.testing.expect(!game.jump_requested);
    handleKeyPress(game, .{ .key = .space, .mods = .{} });
    handleKeyPress(game, .{ .key = .q, .mods = .{} });
    handleMouseButtonPress(game, .{ .button = .left, .mods = .{} });
    try std.testing.expect(!game.jump_requested);
    try std.testing.expectEqual(.player, game.control_mode);
    try std.testing.expectEqual(null, game.block_interaction.requested);
    // Even an elapsed sample provided by a caller cannot advance paused timers.
    fixture.engine.frame_delta = 120;
    game.advanceWorldClock();
    try std.testing.expectEqual(tick, game.world.?.simulation_tick);
    try std.testing.expectEqual(fraction, game.fractional_ticks);
    game.handleMenuAction(.resume_game);
    try std.testing.expect(!simulation.paused.load(.acquire));
    game.advanceWorldClock();
    try std.testing.expectEqual(tick, game.world.?.simulation_tick);
    fixture.engine.frame_delta = 0.125;
    game.advanceWorldClock();
    try std.testing.expect(game.world.?.simulation_tick > tick);
    // Future multiplayer sessions continue world timers and NPC admission.
    game.menu_pauses_game = false;
    handleKeyPress(game, .{ .key = .e, .mods = .{} });
    game.jump_requested = true;
    try game.tool_commands.append(game.allocator, .remove);
    const frame_delta = fixture.engine.frame_delta;
    game.setOverlay(.menu);
    try std.testing.expect(!fixture.engine.paused);
    try std.testing.expect(fixture.engine.gameplay_input_blocked);
    try std.testing.expectEqual(null, game.block_interaction.requested);
    try std.testing.expect(!game.jump_requested);
    try std.testing.expectEqual(0, game.tool_commands.items.len);
    try std.testing.expectEqual(frame_delta, fixture.engine.frame_delta);
    try std.testing.expect(!simulation.paused.load(.acquire));
    fixture.engine.frame_delta = 1;
    game.advanceWorldClock();
    try std.testing.expect(game.world.?.simulation_tick > tick + transformations.ticks_per_second / 2);
    try std.testing.expect(handleUIKeyPress(game, .{ .key = .escape, .mods = .{} }));
    try std.testing.expectEqual(.none, game.overlay);
    try std.testing.expect(!fixture.engine.gameplay_input_blocked);
    try std.testing.expectEqual(1, fixture.engine.frame_delta);
}

test "world map captures gameplay and pending controls while simulation keeps running" {
    var fixture: StreamingTest = .{};
    fixture.init();
    defer fixture.deinit();
    const game = &fixture.game;
    try fixture.preparePlayerToolTest();
    const service = try WorldDataService.create(std.testing.io, std.testing.allocator, &test_layout, .flat);
    defer service.destroy();
    var simulation: SimulationWorker = .{ .client = try service.createClient(), .worker = undefined };
    game.simulation = &simulation;
    game.player = PlayerController.init(std.testing.allocator, .{ 0, 0, 0 });
    handleMouseButtonPress(game, .{ .button = .left, .mods = .{} });
    game.updateBlockTool();
    try std.testing.expect(game.block_interaction.holding != null);
    game.jump_requested = true;
    try game.tool_commands.append(game.allocator, .remove);
    fixture.input.cursor_position_delta = .{ 20, -10 };
    fixture.engine.frame_delta = 0.125;
    const tick = game.world.?.simulation_tick;

    try std.testing.expect(handleUIKeyPress(game, .{ .key = .m, .mods = .{} }));
    try std.testing.expectEqual(.world_map, game.overlay);
    try std.testing.expect(!fixture.engine.paused);
    try std.testing.expect(!simulation.paused.load(.acquire));
    try std.testing.expect(fixture.engine.gameplay_input_blocked);
    try std.testing.expectEqual(.never, fixture.input.cursor_capture);
    try std.testing.expectEqualDeep([2]f32{ 0, 0 }, fixture.input.cursor_position_delta);
    try std.testing.expectEqual(null, game.block_interaction.holding);
    try std.testing.expect(!game.jump_requested);
    try std.testing.expectEqual(0, game.tool_commands.items.len);

    handleKeyPress(game, .{ .key = .space, .mods = .{} });
    handleKeyPress(game, .{ .key = .q, .mods = .{} });
    handleKeyPress(game, .{ .key = .e, .mods = .{} });
    handleMouseButtonPress(game, .{ .button = .left, .mods = .{} });
    try std.testing.expect(!game.jump_requested);
    try std.testing.expectEqual(.player, game.control_mode);
    try std.testing.expectEqual(null, game.block_interaction.requested);
    game.advanceWorldClock();
    try std.testing.expect(game.world.?.simulation_tick > tick);

    // The click that closes the map can remain physically held without starting a tool.
    fixture.input.cursor_left_button_pressed = true;
    try std.testing.expect(handleUIKeyPress(game, .{ .key = .m, .mods = .{} }));
    try std.testing.expectEqual(.none, game.overlay);
    try std.testing.expect(!fixture.engine.gameplay_input_blocked);
    try std.testing.expectEqual(.always, fixture.input.cursor_capture);
    try std.testing.expectEqual(0.125, fixture.engine.frame_delta);
    game.updateBlockTool();
    try std.testing.expectEqual(null, game.block_interaction.holding);
    try std.testing.expectEqual(null, game.block_interaction.requested);
    handleMouseButtonRelease(game, .{ .button = .left, .mods = .{} });
    handleMouseButtonPress(game, .{ .button = .left, .mods = .{} });
    game.updateBlockTool();
    try std.testing.expect(game.block_interaction.holding != null);
}

test "world map keeps jump physics and terrain collisions running while capturing controls" {
    const coordinates = @import("block_coordinates.zig");
    for ([_]f64{ 0.1, 0.6 }) |jump_elapsed| {
        var fixture: StreamingTest = .{};
        fixture.init();
        defer fixture.deinit();
        const game = &fixture.game;
        try game.world.?.insertChunk(test_layout.origin_chunk, WorldChunk.initEmpty());
        try game.world.?.insertChunk(test_layout.origin_chunk - ChunkCoords{ 0, 0, 1 }, WorldChunk.initEmpty());
        const floor = coordinates.fromWorld(&test_layout, .{ 0, 0, -1 }).?;
        game.world.?.setBlockUnchecked(floor, .stone);
        game.control_mode = .player;
        game.player = PlayerController.init(std.testing.allocator, .{ 0.5, 0.5, 0 });
        try fixture.input.pressed_keys.put(.space, {});
        handleKeyPress(game, .{ .key = .space, .mods = .{} });
        fixture.engine.frame_delta = jump_elapsed;
        fixture.engine.time = jump_elapsed;
        game.updateGameplay(false);
        const position = game.player.?.position;
        const velocity = game.player.?.vertical_velocity;
        try std.testing.expect(position[2] > 0);
        try std.testing.expect(!game.player.?.grounded);
        try std.testing.expect(if (jump_elapsed < 0.5) velocity > 0 else velocity < 0);

        try std.testing.expect(handleUIKeyPress(game, .{ .key = .m, .mods = .{} }));
        // Held controls and mouse motion must not alter the jump or view.
        try fixture.input.pressed_keys.put(.w, {});
        try fixture.input.pressed_keys.put(.d, {});
        fixture.input.cursor_position_delta = .{ 20, -10 };
        handleKeyPress(game, .{ .key = .space, .mods = .{} });
        fixture.engine.frame_delta = 0.1;
        fixture.engine.time += fixture.engine.frame_delta;
        game.updateGameplay(false);
        try std.testing.expectApproxEqAbs(position[2] + velocity * 0.1 - 0.5 * player_module.gravity * 0.1 * 0.1, game.player.?.position[2], 0.000001);
        try std.testing.expectApproxEqAbs(velocity - player_module.gravity * 0.1, game.player.?.vertical_velocity, 0.000001);
        try std.testing.expectEqual(position[0], game.player.?.position[0]);
        try std.testing.expectEqual(position[1], game.player.?.position[1]);
        try std.testing.expectEqual(@as(f32, 0), game.player.?.yaw);
        try std.testing.expectEqual(@as(f32, 0), game.player.?.pitch);
        try std.testing.expectEqualDeep(game.player.?.position + Position{ 0, 0, game.player.?.body.eye_height }, fixture.camera.position);
        try std.testing.expectEqualDeep(game.player.?.position, game.mapView(&fixture.scene).player.?.position);

        // Land while the map is still open, without jumping again from held Space.
        for (0..20) |_| {
            fixture.engine.time += fixture.engine.frame_delta;
            game.updateGameplay(false);
        }
        try std.testing.expectEqual(.world_map, game.overlay);
        try std.testing.expect(game.player.?.grounded);
        try std.testing.expectApproxEqAbs(@as(f64, 0), game.player.?.position[2], 0.000001);
        try std.testing.expectEqual(@as(f64, 0), game.player.?.vertical_velocity);
        try std.testing.expect(!game.player.?.auto_climb);

        // Terrain changes under the player also take effect behind the map.
        game.world.?.setBlockUnchecked(floor, .none);
        fixture.engine.time += fixture.engine.frame_delta;
        game.updateGameplay(true);
        try std.testing.expect(game.player.?.position[2] < 0);
        try std.testing.expect(game.player.?.vertical_velocity < 0);

        // The game menu retains its actual pause, even with an elapsed sample.
        game.setOverlay(.menu);
        const paused_position = game.player.?.position;
        const paused_velocity = game.player.?.vertical_velocity;
        fixture.engine.frame_delta = 0.1;
        game.updateGameplay(false);
        try std.testing.expectEqualDeep(paused_position, game.player.?.position);
        try std.testing.expectEqual(paused_velocity, game.player.?.vertical_velocity);
    }
}

fn finishMapTeleport(game: *Game) !void {
    for (0..5000) |_| {
        game.updateMapTeleport();
        if (game.map_teleport == null) return;
        try std.Io.sleep(std.testing.io, .fromMilliseconds(1), .awake);
    }
    return error.TeleportTimedOut;
}

test "debug map teleport resolves current edited surface and keeps player view and inventory" {
    if (comptime !world_map.debug_teleport_enabled) return error.SkipZigTest;
    const layout = try WorldLayout.init(.{ .size_in_chunks = .{ 8, 8, 2 } });
    const service = try WorldDataService.create(std.testing.io, std.testing.allocator, &layout, .flat);
    defer service.destroy();
    var fixture: StreamingTest = .{};
    fixture.initWithLayout(&layout);
    defer fixture.deinit();
    const game = &fixture.game;
    game.world_data = service;
    game.world_client = try service.createClient();
    game.player = PlayerController.init(std.testing.allocator, .{ 0.5, 0.5, -16 });
    game.player.?.yaw = 0.7;
    game.player.?.pitch = -0.2;
    game.player.?.vertical_velocity = -30;
    game.block_interaction.inventory = .planks;
    const edit = try StreamingTest.serviceOperation(game.world_client.?, .{ .block = .{ 234, 42, 16 }, .action = .{ .put = .dirt } });
    try std.testing.expectEqual(.success, edit.status);
    game.setOverlay(.world_map);
    game.handleMapAction(.{ .teleport_xy = .{ 106.5, -85.5 } });
    // A submitted edit may still await persistence admission/acknowledgment.
    try game.world.?.pending_operations.append(game.allocator, .{
        .operation = .{ .block = .{ 234, 42, 16 }, .action = .remove },
        .request_id = 999,
    });
    game.updateMapTeleport();
    try std.testing.expectEqual(null, game.map_teleport.?.request_id);
    game.world.?.pending_operations.clearRetainingCapacity();
    game.updateMapTeleport();
    const request_id = game.map_teleport.?.request_id.?;
    // Repeated presses cannot enqueue an unbounded series of terrain searches.
    game.handleMapAction(.{ .teleport_xy = .{ -96.5, 96.5 } });
    try std.testing.expectEqual(request_id, game.map_teleport.?.request_id.?);
    try std.testing.expectEqualDeep([2]f64{ 106.5, -85.5 }, game.map_teleport.?.xy);
    try finishMapTeleport(game);
    try std.testing.expectEqual(Position{ 106.5, -85.5, -15 }, game.player.?.position);
    try std.testing.expectEqual(Position{ 106.5, -85.5, -13.4 }, fixture.camera.position);
    try std.testing.expectEqual(@as(f32, 0.7), game.player.?.yaw);
    try std.testing.expectEqual(@as(f32, -0.2), game.player.?.pitch);
    try std.testing.expectEqual(@as(f64, 0), game.player.?.vertical_velocity);
    try std.testing.expectEqual(voxel_chunk_module.BlockType.planks, game.block_interaction.inventory.?);
    try std.testing.expect(game.overlay == .none and !fixture.engine.gameplay_input_blocked);
    try std.testing.expectEqual(.always, fixture.input.cursor_capture);
    try std.testing.expectEqual(null, game.map_teleport_error);
    try std.testing.expectEqual(0, game.tool_commands.items.len);
    try std.testing.expectEqual(null, game.block_interaction.holding);
    game.refreshPinnedChunks();
    try std.testing.expect(game.pinned_chunks.contains(layout.encodeChunkCoords(layout.getChunkCoords(game.player.?.position))));
}

test "debug map teleport failure leaves the player at the original position" {
    if (comptime !world_map.debug_teleport_enabled) return error.SkipZigTest;
    const layout = try WorldLayout.init(.{ .size_in_chunks = .{ 2, 2, 2 } });
    const service = try WorldDataService.create(std.testing.io, std.testing.allocator, &layout, .{
        .terrain = .{ .seed = 12345, .params = .{ .base_height = 64, .height_amplitude = 0 } },
    });
    defer service.destroy();
    var fixture: StreamingTest = .{};
    fixture.initWithLayout(&layout);
    defer fixture.deinit();
    const game = &fixture.game;
    game.world_data = service;
    game.world_client = try service.createClient();
    const original: Position = .{ 0.5, 0.5, -16 };
    game.player = PlayerController.init(std.testing.allocator, original);
    game.setOverlay(.world_map);
    game.handleMapAction(.{ .teleport_xy = .{ 10.5, 10.5 } });
    try finishMapTeleport(game);
    try std.testing.expectEqual(original, game.player.?.position);
    try std.testing.expectEqualStrings("No safe surface at this point", game.map_teleport_error.?);
    try std.testing.expect(game.overlay == .world_map and fixture.engine.gameplay_input_blocked);
    game.handleMapAction(.{ .close = true });
    try std.testing.expect(game.overlay == .none and !fixture.engine.gameplay_input_blocked);
}

test "pending map teleport blocks all close controls and replacement clicks until completion" {
    if (comptime !world_map.debug_teleport_enabled) return error.SkipZigTest;
    const layout = try WorldLayout.init(.{ .size_in_chunks = .{ 2, 2, 2 } });
    const service = try WorldDataService.create(std.testing.io, std.testing.allocator, &layout, .flat);
    defer service.destroy();
    var fixture: StreamingTest = .{};
    fixture.initWithLayout(&layout);
    defer fixture.deinit();
    const game = &fixture.game;
    game.world_data = service;
    game.world_client = try service.createClient();
    const original: Position = .{ 0.5, 0.5, -16 };
    game.player = PlayerController.init(std.testing.allocator, original);
    game.setOverlay(.world_map);
    game.handleMapAction(.{ .teleport_xy = .{ -10.5, -10.5 } });
    for (0..2) |phase| {
        if (phase == 1) {
            game.updateMapTeleport();
            try std.testing.expect(game.map_teleport.?.request_id != null);
        }
        const pending = game.map_teleport.?;
        for ([_]zglfw.Key{ .m, .escape }) |key| {
            try std.testing.expect(handleUIKeyPress(game, .{ .key = key, .mods = .{} }));
            try std.testing.expectEqual(.world_map, game.overlay);
        }
        game.handleMapAction(.{ .close = true });
        game.setOverlay(.menu);
        try std.testing.expectEqual(.world_map, game.overlay);
        try std.testing.expect(fixture.engine.gameplay_input_blocked);
        try std.testing.expectEqual(.never, fixture.input.cursor_capture);
        game.handleMapAction(.{ .teleport_xy = .{ 10.5, 10.5 } });
        try std.testing.expectEqualDeep(pending, game.map_teleport.?);
        const view = game.mapView(&fixture.scene);
        try std.testing.expect(view.teleport_pending);
        try std.testing.expectEqualStrings("Finding a safe surface...", view.teleport_status.?);
    }
    try finishMapTeleport(game);
    try std.testing.expectEqual(Position{ -10.5, -10.5, -16 }, game.player.?.position);
    try std.testing.expect(game.overlay == .none and !fixture.engine.gameplay_input_blocked);
    try std.testing.expectEqual(null, game.map_teleport_error);
}

test "canceling exit allows a new teleport without applying an abandoned search reply" {
    if (comptime !world_map.debug_teleport_enabled) return error.SkipZigTest;
    const layout = try WorldLayout.init(.{ .size_in_chunks = .{ 2, 2, 2 } });
    const service = try WorldDataService.create(std.testing.io, std.testing.allocator, &layout, .flat);
    defer service.destroy();
    var fixture: StreamingTest = .{};
    fixture.initWithLayout(&layout);
    defer fixture.deinit();
    const game = &fixture.game;
    game.world_data = service;
    game.world_client = try service.createClient();
    const original: Position = .{ 0.5, 0.5, -16 };
    game.player = PlayerController.init(std.testing.allocator, original);
    game.setOverlay(.world_map);
    game.handleMapAction(.{ .teleport_xy = .{ -10.5, -10.5 } });
    game.updateMapTeleport();
    const old_id = game.map_teleport.?.request_id.?;
    game.beginExit();
    try std.testing.expect(game.exit_requested);
    try std.testing.expectEqual(.none, game.overlay);
    try std.testing.expectEqual(null, game.map_teleport);
    game.cancelExit();
    game.setOverlay(.world_map);
    game.handleMapAction(.{ .teleport_xy = .{ 10.5, 10.5 } });
    game.updateMapTeleport();
    try std.testing.expect(game.map_teleport.?.request_id.? != old_id);
    try finishMapTeleport(game);
    try std.testing.expectEqual(Position{ 10.5, 10.5, -16 }, game.player.?.position);
    try std.testing.expectEqual(.none, game.overlay);
}

test "debug map spectator teleport preserves the original player and spectator orientation" {
    if (comptime !world_map.debug_teleport_enabled) return error.SkipZigTest;
    const layout = try WorldLayout.init(.{ .size_in_chunks = .{ 2, 2, 2 } });
    const service = try WorldDataService.create(std.testing.io, std.testing.allocator, &layout, .flat);
    defer service.destroy();
    var fixture: StreamingTest = .{};
    fixture.initWithLayout(&layout);
    defer fixture.deinit();
    const game = &fixture.game;
    game.world_data = service;
    game.control_mode = .spectator;
    var spectator: std.meta.Child(@TypeOf(fixture.scene.spectator_camera)) = .{
        .camera = &fixture.camera,
        .input_controller = @ptrCast(&fixture.input),
        .yaw = 1.2,
        .pitch = -0.3,
    };
    fixture.scene.spectator_camera = &spectator;
    const original: Position = .{ 0.5, 0.5, -16 };
    game.player = PlayerController.init(std.testing.allocator, original);
    game.setOverlay(.world_map);
    game.handleMapAction(.{ .teleport_xy = .{ -31.5, 31.5 } });
    try std.testing.expectEqual(Position{ -31.5, 31.5, -12 }, fixture.camera.position);
    try std.testing.expectEqual(original, game.player.?.position);
    try std.testing.expectEqual(@as(f32, 1.2), spectator.yaw);
    try std.testing.expectEqual(@as(f32, -0.3), spectator.pitch);
    try std.testing.expectEqual(null, game.map_teleport);
    try std.testing.expect(game.overlay == .none and !fixture.engine.gameplay_input_blocked);
    try std.testing.expectEqual(.always, fixture.input.cursor_capture);
}

test "map teleport dispatch rejects closed maps and release builds" {
    var fixture: StreamingTest = .{};
    fixture.init();
    defer fixture.deinit();
    fixture.game.player = PlayerController.init(std.testing.allocator, .{ 0, 0, 0 });
    fixture.game.handleMapAction(.{ .teleport_xy = .{ 1.5, 1.5 } });
    try std.testing.expectEqual(null, fixture.game.map_teleport);
    if (comptime !world_map.debug_teleport_enabled) {
        fixture.game.setOverlay(.world_map);
        // No service is wired: release dispatch must stop before any lookup.
        fixture.game.handleMapAction(.{ .teleport_xy = .{ 1.5, 1.5 } });
        try std.testing.expectEqual(null, fixture.game.map_teleport);
        try std.testing.expectEqual(Position{ 0, 0, 0 }, fixture.game.player.?.position);
    }
}

test "map Escape, menu, and exit transitions preserve modal input capture" {
    var fixture: StreamingTest = .{};
    fixture.init();
    defer fixture.deinit();
    const game = &fixture.game;
    try std.testing.expect(handleUIKeyPress(game, .{ .key = .m, .mods = .{} }));
    try std.testing.expect(handleUIKeyPress(game, .{ .key = .escape, .mods = .{} }));
    try std.testing.expectEqual(.none, game.overlay);
    try std.testing.expect(!fixture.engine.paused);
    try std.testing.expect(!fixture.engine.gameplay_input_blocked);

    try std.testing.expect(handleUIKeyPress(game, .{ .key = .escape, .mods = .{} }));
    try std.testing.expectEqual(.menu, game.overlay);
    try std.testing.expect(fixture.engine.paused);
    try std.testing.expect(handleUIKeyPress(game, .{ .key = .m, .mods = .{} }));
    try std.testing.expectEqual(.menu, game.overlay);
    try std.testing.expect(fixture.engine.gameplay_input_blocked);
    try std.testing.expectEqual(.never, fixture.input.cursor_capture);
    try std.testing.expect(handleUIKeyPress(game, .{ .key = .escape, .mods = .{} }));

    game.setOverlay(.world_map);
    game.setOverlay(.menu);
    try std.testing.expectEqual(.menu, game.overlay);
    try std.testing.expect(fixture.engine.paused);
    try std.testing.expect(fixture.engine.gameplay_input_blocked);
    try std.testing.expectEqual(.never, fixture.input.cursor_capture);
    game.handleMenuAction(.resume_game);
    try std.testing.expectEqual(.none, game.overlay);
    try std.testing.expect(!fixture.engine.paused);
    try std.testing.expect(!fixture.engine.gameplay_input_blocked);
    try std.testing.expectEqual(.always, fixture.input.cursor_capture);

    game.setOverlay(.world_map);
    game.beginExit();
    try std.testing.expectEqual(.none, game.overlay);
    try std.testing.expect(fixture.engine.paused);
    try std.testing.expect(fixture.engine.gameplay_input_blocked);
    try std.testing.expect(handleUIKeyPress(game, .{ .key = .m, .mods = .{} }));
    try std.testing.expect(handleUIKeyPress(game, .{ .key = .escape, .mods = .{} }));
    try std.testing.expectEqual(.none, game.overlay);
    game.cancelExit();
    try std.testing.expectEqual(.none, game.overlay);
    try std.testing.expect(!fixture.engine.paused);
    try std.testing.expect(!fixture.engine.gameplay_input_blocked);
    try std.testing.expectEqual(.always, fixture.input.cursor_capture);
}

test "world map freezes spectator movement and look without replaying mouse deltas" {
    var fixture: StreamingTest = .{};
    fixture.init();
    defer fixture.deinit();
    var spectator: std.meta.Child(@TypeOf(fixture.scene.spectator_camera)) = .{
        .camera = &fixture.camera,
        .input_controller = @ptrCast(&fixture.input),
        .yaw = 0.7,
        .pitch = -0.2,
    };
    fixture.scene.spectator_camera = &spectator;
    fixture.scene.spectator_enabled = true;
    fixture.scene.engine = &fixture.engine;
    fixture.scene.previous_frame_time = 1;
    fixture.game.control_mode = .spectator;
    try fixture.input.pressed_keys.put(.w, {});
    const position = fixture.camera.position;
    fixture.game.setOverlay(.world_map);
    fixture.input.cursor_position_delta = .{ 10, 20 };
    fixture.scene.update(2);
    try std.testing.expectEqualDeep(position, fixture.camera.position);
    try std.testing.expectEqual(@as(f32, 0.7), spectator.yaw);
    try std.testing.expectEqual(@as(f32, -0.2), spectator.pitch);
    fixture.game.setOverlay(.none);
    fixture.scene.update(2.1);
    try std.testing.expect(!std.meta.eql(position, fixture.camera.position));
    try std.testing.expectEqual(@as(f32, 0.7), spectator.yaw);
    try std.testing.expectEqual(@as(f32, -0.2), spectator.pitch);
}

test "map view retains the original player pose during spectator excursions" {
    var fixture: StreamingTest = .{};
    fixture.init();
    defer fixture.deinit();
    fixture.game.player = PlayerController.init(std.testing.allocator, .{ 1.5, 2.5, 3 });
    fixture.game.player.?.yaw = 0.5;
    fixture.camera.updatePosition(.{ 100, 101, 102 });
    var spectator: std.meta.Child(@TypeOf(fixture.scene.spectator_camera)) = .{
        .camera = &fixture.camera,
        .input_controller = @ptrCast(&fixture.input),
        .yaw = 2,
    };
    fixture.scene.spectator_camera = &spectator;
    const player_view = fixture.game.mapView(&fixture.scene);
    try std.testing.expectEqualDeep(Position{ 1.5, 2.5, 3 }, player_view.player.?.position);
    try std.testing.expectEqual(@as(f32, 0.5), player_view.player.?.yaw);
    try std.testing.expectEqual(null, player_view.spectator);
    fixture.game.control_mode = .spectator;
    const spectator_view = fixture.game.mapView(&fixture.scene);
    try std.testing.expectEqualDeep(player_view.player, spectator_view.player);
    try std.testing.expectEqualDeep(fixture.camera.position, spectator_view.spectator.?.position);
    try std.testing.expectEqual(@as(f32, 2), spectator_view.spectator.?.yaw);
}

test "held motion sampling uses actual active-camera movement and material selection preserves motion" {
    var fixture: StreamingTest = .{};
    fixture.init();
    defer fixture.deinit();
    const game = &fixture.game;
    fixture.engine.frame_delta = 1.0 / 60.0;
    game.player = PlayerController.init(std.testing.allocator, .{ 0, 0, 0 });
    game.player.?.grounded = true;
    fixture.camera.updatePosition(.{ 0, 0, 1.6 });
    game.updateHeldMotion();
    // Pushing into an obstacle must not animate a walk in place.
    try fixture.input.pressed_keys.put(.w, {});
    for (0..60) |_| game.updateHeldMotion();
    try std.testing.expectEqualDeep(held_item_motion.Offset{}, game.held_motion.offset);
    for (0..10) |_| {
        fixture.camera.translate(.{ 0, 5.0 / 60.0, 0 });
        game.updateHeldMotion();
    }
    try std.testing.expect(@abs(game.held_motion.offset.translation[1]) + @abs(game.held_motion.offset.translation[2]) > 0.001);
    const previous = game.held_motion.previous;
    game.control_mode = .spectator;
    handleKeyPress(game, .{ .key = .three, .mods = .{} });
    try std.testing.expectEqual(previous, game.held_motion.previous);
    try std.testing.expectEqual(voxel_chunk_module.BlockType.tree_trunk, game.selected_material);
    // Spectator samples its camera, not the frozen player's feet.
    var spectator: std.meta.Child(@TypeOf(@as(Scene, undefined).spectator_camera)) = .{
        .camera = &fixture.camera,
        .input_controller = @ptrCast(&fixture.input),
    };
    fixture.scene.spectator_camera = &spectator;
    game.control_mode = .spectator;
    game.held_motion.reset();
    game.updateHeldMotion();
    for (0..30) |_| {
        fixture.camera.translate(.{ 5.0 / 60.0, 0, 0 });
        game.updateHeldMotion();
    }
    try std.testing.expect(@abs(game.held_motion.offset.translation[0]) > 0.001);
    fixture.input.focused = false;
    game.updateHeldMotion();
    try std.testing.expectEqualDeep(held_item_motion.Offset{}, game.held_motion.offset);
}

test "held pitch shift follows the active controller even when the item is hidden" {
    var fixture: StreamingTest = .{};
    fixture.init();
    defer fixture.deinit();
    const game = &fixture.game;
    fixture.engine.frame_delta = 1.0 / 60.0;
    game.player = PlayerController.init(std.testing.allocator, .{ 0, 0, 0 });
    game.player.?.grounded = true;
    var spectator: std.meta.Child(@TypeOf(@as(Scene, undefined).spectator_camera)) = .{
        .camera = &fixture.camera,
        .input_controller = @ptrCast(&fixture.input),
    };
    fixture.scene.spectator_camera = &spectator;
    for ([_]@TypeOf(game.control_mode){ .player, .spectator }) |mode| {
        game.control_mode = mode;
        game.player.?.pitch = 0;
        spectator.pitch = 0;
        game.held_motion.reset();
        game.updateHeldMotion();
        for ([_]f32{ -0.6, 0.6 }) |pitch| {
            // The inactive controller deliberately looks in the opposite direction.
            game.player.?.pitch = if (mode == .player) pitch else -pitch;
            spectator.pitch = if (mode == .spectator) pitch else -pitch;
            for (0..300) |_| game.updateHeldMotion();
            const expected = -@sin(pitch) * game.held_motion.tuning.pitch_shift;
            try std.testing.expectApproxEqAbs(expected, game.held_motion.offset.translation[1], 0.000001);
            try std.testing.expectEqualDeep(@as(held_item_motion.Vec3, @splat(0)), game.held_motion.offset.rotation_degrees);
            fixture.input.focus_changed = true;
            game.updateHeldMotion();
            try std.testing.expectApproxEqAbs(expected, game.held_motion.offset.translation[1], 0.000001);
            fixture.input.focus_changed = false;
            fixture.input.focused = false;
            game.updateHeldMotion();
            try std.testing.expectApproxEqAbs(expected, game.held_motion.offset.translation[1], 0.000001);
            fixture.input.focused = true;
            fixture.engine.frame_delta = 0.3;
            game.updateHeldMotion();
            try std.testing.expectApproxEqAbs(expected, game.held_motion.offset.translation[1], 0.000001);
            fixture.engine.frame_delta = 1.0 / 60.0;
            game.updateHeldMotion();
            try std.testing.expectApproxEqAbs(expected, game.held_motion.offset.translation[1], 0.000001);
        }
    }
}

test "held material follows player inventory and observer selection without a target" {
    var game: Game = .{ .allocator = std.testing.allocator, .engine = undefined };
    for ([_]block_targeting.Mode{ .removing, .putting }) |mode| {
        game.block_mode = mode;
        game.block_interaction.inventory = null;
        try std.testing.expectEqual(null, game.heldMaterial());
        game.block_interaction.inventory = .crushed_stone;
        game.selected_material = .tree_trunk;
        try std.testing.expectEqual(voxel_chunk_module.BlockType.crushed_stone, game.heldMaterial().?);
    }
    game.control_mode = .spectator;
    game.block_mode = .putting;
    for ([_]voxel_chunk_module.BlockType{ .dirt, .crushed_stone, .tree_trunk, .planks, .rebar, .reinforced_concrete }) |material| {
        game.selected_material = material;
        try std.testing.expectEqual(material, game.heldMaterial().?);
    }
    game.block_mode = .removing;
    try std.testing.expectEqual(null, game.heldMaterial());
}

fn drawCrosshair() void {
    const screen = zgui.io.getDisplaySize();
    if (screen[0] <= 0 or screen[1] <= 0) return;
    const center: [2]f32 = .{ screen[0] / 2, screen[1] / 2 };
    const scale = zgui.getStyle().font_scale_dpi;
    const list = zgui.getForegroundDrawList();
    list.addCircleFilled(.{
        .p = center,
        .r = 5 * scale,
        .col = zgui.colorConvertFloat4ToU32(.{ 0, 0, 0, 1 }),
        .num_segments = 32,
    });
    list.addCircleFilled(.{
        .p = center,
        .r = 4 * scale,
        .col = zgui.colorConvertFloat4ToU32(.{ 1, 1, 1, 1 }),
        .num_segments = 32,
    });
}

test "crosshair and fonts follow DPI changes without accumulating style rounding" {
    zgui.init(std.testing.allocator);
    defer zgui.deinit();
    zgui.io.setIniFilename(null);
    zgui.io.setBackendFlags(.{ .renderer_has_textures = true });
    _ = zgui.io.addFontFromFile("content/Roboto-Medium.ttf", 16);
    const base_style = zgui.getStyle().*;
    var dpi = zgui_utils.DpiScaling.init();
    for ([_][2]f32{ .{ 1, 1 }, .{ 1, 2 }, .{ 1.25, 1.25 }, .{ 2, 2 }, .{ 1, 1 } }) |content_scale| {
        dpi.update(content_scale);
        const scale = @max(content_scale[0], content_scale[1]);
        const screen: [2]f32 = .{ 1280 * scale, 720 * scale };
        zgui.io.setDisplaySize(screen[0], screen[1]);
        zgui.newFrame();
        try std.testing.expectEqual(16 * scale, zgui.getFontSize());
        // These are the unscaled sizes used by preview hints and action errors.
        for ([_]f32{ 14, 20 }) |size| {
            zgui.pushFont(null, size);
            try std.testing.expectApproxEqAbs(@floor(size * scale + 0.5), zgui.getFontSize(), 0.01);
            zgui.popFont();
        }
        drawCrosshair();
        zgui.render();
        const data = zgui.getDrawData();
        try std.testing.expectEqual(1, data.cmd_lists_count);
        const vertices = data.cmd_lists.items[0].getVertexBuffer();
        for ([_]struct { color: [4]f32, radius: f32 }{
            .{ .color = .{ 0, 0, 0, 1 }, .radius = 5 },
            .{ .color = .{ 1, 1, 1, 1 }, .radius = 4 },
        }) |circle| {
            const color = zgui.colorConvertFloat4ToU32(circle.color);
            var min: [2]f32 = .{ math.inf(f32), math.inf(f32) };
            var max: [2]f32 = .{ -math.inf(f32), -math.inf(f32) };
            for (vertices) |vertex| {
                if (vertex.color != color) continue;
                for (0..2) |axis| {
                    min[axis] = @min(min[axis], vertex.pos[axis]);
                    max[axis] = @max(max[axis], vertex.pos[axis]);
                }
            }
            for (0..2) |axis| {
                try std.testing.expectApproxEqAbs(screen[axis] / 2, (min[axis] + max[axis]) / 2, 0.01);
                // Opaque vertices exclude a half-pixel antialiasing fringe at each edge.
                try std.testing.expectApproxEqAbs(2 * circle.radius * scale - 1, max[axis] - min[axis], 0.1);
            }
        }
        if (scale == 1) {
            try std.testing.expectEqual(base_style.window_padding, zgui.getStyle().window_padding);
            try std.testing.expectEqual(base_style.item_spacing, zgui.getStyle().item_spacing);
        }
    }
}

test {
    _ = menu;
    _ = world_map;
    _ = world_module;
    _ = world_generator;
    _ = world_data_service;
    _ = SimulationWorker;
    _ = player_module;
    _ = @import("standing_space.zig");
}

test "Q excursions start at player eyes and return to the frozen player position and view" {
    var camera = std.meta.Child(@TypeOf(@as(Scene, undefined).camera)).init(&test_layout, 1);
    var engine: Engine = undefined;
    const InputController = std.meta.Child(@TypeOf(engine.input_controller));
    var input: InputController = .{
        .allocator = std.testing.allocator,
        .window = undefined,
        .callbacks = .{ .context = &engine },
        .pressed_keys = std.AutoHashMap(zglfw.Key, void).init(std.testing.allocator),
        .release_queue = std.AutoHashMap(zglfw.Key, void).init(std.testing.allocator),
        .cursor_position = .{ 0, 0 },
        .cursor_capture = .always,
    };
    defer input.pressed_keys.deinit();
    defer input.release_queue.deinit();
    var spectator: std.meta.Child(@TypeOf(@as(Scene, undefined).spectator_camera)) = .{
        .camera = &camera,
        .input_controller = @ptrCast(&input),
    };
    var scene: Scene = undefined;
    scene.camera = &camera;
    scene.spectator_camera = &spectator;
    scene.spectator_enabled = false;
    engine.active_scene = &scene;
    engine.input_controller = &input;
    var game: Game = .{
        .allocator = std.testing.allocator,
        .engine = &engine,
        .player = PlayerController.init(std.testing.allocator, .{ 1.5, 2.5, 3 }),
    };
    defer game.player.?.deinit();
    try std.testing.expectEqual(.removing, game.block_mode);
    game.player.?.yaw = 0.5;
    game.player.?.pitch = 0.2;
    game.player.?.auto_climb = true;
    game.block_interaction.inventory = .sand;
    game.block_interaction.holding = .{ .source = .key, .operation = .{ .block = .{ 0, 0, 0 }, .action = .{ .put = .sand } }, .material = .none, .elapsed = 0.5 };
    game.toggleControlMode();
    try std.testing.expectEqual(null, game.block_interaction.holding);
    try std.testing.expectEqual(voxel_chunk_module.BlockType.sand, game.block_interaction.inventory.?);
    try std.testing.expectEqual(.removing, game.block_mode);
    const eyes = camera.position;
    try std.testing.expectEqualDeep(Position{ 1.5, 2.5, 4.6 }, eyes);
    try std.testing.expect(scene.spectator_enabled);
    try std.testing.expectEqual(@as(@TypeOf(input.cursor_capture), .always), input.cursor_capture);
    try std.testing.expectEqual(@as(f32, 0.5), spectator.yaw);
    try std.testing.expectEqual(@as(f32, 0.2), spectator.pitch);
    try std.testing.expect(!game.player.?.auto_climb);
    camera.updatePosition(.{ 100, 100, 100 });
    spectator.yaw = 2;
    game.block_mode = .putting;
    game.toggleControlMode();
    try std.testing.expectEqual(.putting, game.block_mode);
    try std.testing.expectEqual(voxel_chunk_module.BlockType.sand, game.block_interaction.inventory.?);
    try std.testing.expectEqualDeep(eyes, camera.position);
    try std.testing.expectEqualDeep(Position{ 1.5, 2.5, 3 }, game.player.?.position);
    try std.testing.expect(!scene.spectator_enabled);
    try std.testing.expectEqual(@as(f32, 0.5), game.player.?.yaw);
    try std.testing.expectEqual(@as(@TypeOf(input.cursor_capture), .always), input.cursor_capture);
    game.toggleControlMode();
    try std.testing.expectEqual(.putting, game.block_mode);
    try std.testing.expectEqual(voxel_chunk_module.BlockType.sand, game.block_interaction.inventory.?);
    try std.testing.expectEqualDeep(eyes, camera.position);
}

test "spectator streaming pins the frozen player's nearby block chunks" {
    var fixture: StreamingTest = undefined;
    fixture.init();
    defer fixture.deinit();
    fixture.game.player = PlayerController.init(std.testing.allocator, .{ 0.5, 0.5, 0 });
    fixture.game.control_mode = .spectator;
    fixture.camera.position = .{ 500, 500, 0 };
    fixture.game.refreshPinnedChunks();
    const player_chunk = test_layout.getChunkCoords(fixture.game.player.?.position);
    try std.testing.expectEqual(@as(u32, 27), fixture.game.pinned_chunks.count());
    try std.testing.expect(fixture.game.pinned_chunks.contains(test_layout.encodeChunkCoords(player_chunk)));
    try std.testing.expect(fixture.game.wantsBlocks(player_chunk));
    try std.testing.expect(!fixture.game.pinned_chunks.contains(test_layout.encodeChunkCoords(test_layout.getChunkCoords(fixture.camera.position))));
}

test "camera placement rejects the player's body before changing the optimistic cache" {
    var fixture: StreamingTest = undefined;
    fixture.init();
    defer fixture.deinit();
    fixture.game.player = PlayerController.init(std.testing.allocator, .{ 0.5, 0.5, 0 });
    fixture.camera.updatePosition(.{ 0.5, 0.5, 1.6 });
    fixture.camera.updateView(zmath.rotationX(math.pi / 2.0));
    const centre = test_layout.getChunkCoords(.{ 0.5, 0.5, 0 });
    try fixture.game.world.?.insertChunk(centre, WorldChunk.initEmpty());
    try fixture.game.world.?.insertChunk(centre - ChunkCoords{ 0, 0, 1 }, WorldChunk.initEmpty());
    const ground: [3]u32 = .{ 8192, 4096, 127 };
    fixture.game.world.?.setBlockUnchecked(ground, .stone);
    fixture.game.world.?.pending_operations.clearRetainingCapacity();
    fixture.game.editBlockInView(.{ .place = fixture.game.selected_material });
    try std.testing.expectEqualStrings(block_diagnostics.player_overlap_message, fixture.game.block_action_error.message(0).?);
    try std.testing.expect(!try fixture.game.world.?.isBlockSolid(.{ 8192, 4096, 128 }));
    try std.testing.expectEqual(@as(usize, 0), fixture.game.world.?.pending_operations.items.len);
    // The same protection applies while the player is frozen in spectator mode.
    fixture.game.control_mode = .spectator;
    fixture.game.editBlockInView(.{ .place = fixture.game.selected_material });
    try std.testing.expectEqual(@as(usize, 0), fixture.game.world.?.pending_operations.items.len);
}

test "tool shortcuts respect Tab mode, edit once and preserve material selection and focus handling" {
    var fixture: StreamingTest = .{};
    fixture.init();
    defer fixture.deinit();
    fixture.game.control_mode = .spectator;
    const input = &fixture.input;
    fixture.camera.updatePosition(.{ 0.5, 0.5, 0.5 });
    const origin = test_layout.origin_chunk;
    try fixture.game.world.?.insertChunk(origin, WorldChunk.initEmpty());
    const target: [3]u32 = .{
        @intCast(origin[0] * consts.CHUNK_SIZE),
        @intCast(origin[1] * consts.CHUNK_SIZE + 3),
        @intCast(origin[2] * consts.CHUNK_SIZE),
    };
    fixture.game.world.?.setBlockUnchecked(target, .stone);
    try fixture.supportSandPlacement(.{ target[0], target[1] - 1, target[2] });
    fixture.game.world.?.pending_operations.clearRetainingCapacity();

    const materials = [_]voxel_chunk_module.BlockType{ .dirt, .crushed_stone, .tree_trunk, .planks, .rebar, .reinforced_concrete, .country_road_solid, .country_road_adaptive };
    for ([_]zglfw.Key{ .one, .two, .three, .four, .five, .six, .seven, .eight }, materials) |key, material| {
        handleKeyPress(&fixture.game, .{ .key = key, .mods = .{} });
        try std.testing.expectEqual(material, fixture.game.selected_material);
    }
    fixture.game.selected_material = .sand;
    try std.testing.expectEqual(.removing, fixture.game.block_mode);
    handleKeyPress(&fixture.game, .{ .key = .e, .mods = .{} });
    try std.testing.expectEqual(0, fixture.game.tool_commands.items.len);
    handleKeyPress(&fixture.game, .{ .key = .tab, .mods = .{} });
    try std.testing.expectEqual(.putting, fixture.game.block_mode);
    try std.testing.expectEqual(voxel_chunk_module.BlockType.sand, fixture.game.selected_material);
    handleKeyPress(&fixture.game, .{ .key = .e, .mods = .{ .control = true } });
    handleKeyPress(&fixture.game, .{ .key = .z, .mods = .{} });
    fixture.game.updateBlockTool();
    try std.testing.expectEqual(0, fixture.game.world.?.pending_operations.items.len);
    handleKeyPress(&fixture.game, .{ .key = .e, .mods = .{} });
    fixture.game.updateBlockTool();
    try std.testing.expectEqual(1, fixture.game.world.?.pending_operations.items.len);
    fixture.game.updateBlockTool();
    try std.testing.expectEqual(1, fixture.game.world.?.pending_operations.items.len);
    handleKeyPress(&fixture.game, .{ .key = .x, .mods = .{} });
    try std.testing.expectEqual(0, fixture.game.tool_commands.items.len);
    handleKeyPress(&fixture.game, .{ .key = .tab, .mods = .{} });
    handleKeyPress(&fixture.game, .{ .key = .x, .mods = .{} });
    fixture.game.updateBlockTool();
    try std.testing.expectEqual(2, fixture.game.world.?.pending_operations.items.len);
    try std.testing.expect(fixture.game.world.?.pending_operations.items[1].operation.action == .remove);

    handleKeyPress(&fixture.game, .{ .key = .tab, .mods = .{} });
    handleMouseButtonPress(&fixture.game, .{ .button = .left, .mods = .{} });
    input.cursor_left_button_pressed = true;
    fixture.game.updateBlockTool();
    try std.testing.expectEqual(3, fixture.game.world.?.pending_operations.items.len);
    input.flushQueue();
    fixture.game.updateBlockTool();
    try std.testing.expectEqual(3, fixture.game.world.?.pending_operations.items.len);
    // Focus loss or regain must discard queued edits and mouse presses.
    input.focused = false;
    handleMouseButtonPress(&fixture.game, .{ .button = .left, .mods = .{} });
    fixture.game.updateBlockTool();
    input.focused = true;
    fixture.game.updateBlockTool();
    try std.testing.expectEqual(3, fixture.game.world.?.pending_operations.items.len);
    input.focus_changed = true;
    handleMouseButtonPress(&fixture.game, .{ .button = .left, .mods = .{} });
    handleKeyPress(&fixture.game, .{ .key = .e, .mods = .{} });
    fixture.game.updateBlockTool();
    input.flushQueue();
    input.focus_changed = false;
    fixture.game.updateBlockTool();
    try std.testing.expectEqual(3, fixture.game.world.?.pending_operations.items.len);
}

test "tool presses across a Tab switch retain the action captured at each press" {
    var fixture: StreamingTest = .{};
    fixture.init();
    defer fixture.deinit();
    try fixture.prepareSupportedToolTest();
    handleKeyPress(&fixture.game, .{ .key = .tab, .mods = .{} });
    handleKeyPress(&fixture.game, .{ .key = .e, .mods = .{} });
    handleKeyPress(&fixture.game, .{ .key = .tab, .mods = .{} });
    handleKeyPress(&fixture.game, .{ .key = .x, .mods = .{} });
    fixture.game.updateBlockTool();
    const operations = fixture.game.world.?.pending_operations.items;
    try std.testing.expectEqual(2, operations.len);
    try std.testing.expect(operations[0].operation.action == .put);
    try std.testing.expect(operations[1].operation.action == .remove);
    try std.testing.expectEqual(operations[0].operation.block, operations[1].operation.block);
    try std.testing.expect(try fixture.game.world.?.isBlockSolid(StreamingTest.toolTarget()));
}

test "two keyboard or mouse placement presses before an update both edit the world" {
    for ([_]bool{ false, true }) |mouse| {
        var fixture: StreamingTest = .{};
        fixture.init();
        defer fixture.deinit();
        try fixture.prepareSupportedToolTest();
        handleKeyPress(&fixture.game, .{ .key = .tab, .mods = .{} });
        for (0..2) |_| {
            if (mouse) {
                handleMouseButtonPress(&fixture.game, .{ .button = .left, .mods = .{} });
            } else {
                handleKeyPress(&fixture.game, .{ .key = .e, .mods = .{} });
            }
        }
        fixture.game.updateBlockTool();
        const operations = fixture.game.world.?.pending_operations.items;
        try std.testing.expectEqual(2, operations.len);
        try std.testing.expectEqual(operations[0].operation.block[1] - 1, operations[1].operation.block[1]);
    }
}

test "a placement press captures its material before the next selection" {
    var fixture: StreamingTest = .{};
    fixture.init();
    defer fixture.deinit();
    try fixture.prepareSupportedToolTest();
    handleKeyPress(&fixture.game, .{ .key = .tab, .mods = .{} });
    handleKeyPress(&fixture.game, .{ .key = .e, .mods = .{} });
    fixture.game.selected_material = .snow;
    fixture.game.updateBlockTool();
    try std.testing.expectEqual(voxel_chunk_module.BlockType.sand, fixture.game.world.?.pending_operations.items[0].operation.action.put);
}

test "mixed keyboard and mouse commands execute in order with each press's material" {
    var fixture: StreamingTest = .{};
    fixture.init();
    defer fixture.deinit();
    try fixture.prepareSupportedToolTest();
    handleKeyPress(&fixture.game, .{ .key = .tab, .mods = .{} });
    handleKeyPress(&fixture.game, .{ .key = .e, .mods = .{} });
    fixture.game.selected_material = .snow;
    handleMouseButtonPress(&fixture.game, .{ .button = .left, .mods = .{} });
    handleKeyPress(&fixture.game, .{ .key = .tab, .mods = .{} });
    handleKeyPress(&fixture.game, .{ .key = .x, .mods = .{} });
    handleMouseButtonPress(&fixture.game, .{ .button = .right, .mods = .{} });
    fixture.game.updateBlockTool();
    const operations = fixture.game.world.?.pending_operations.items;
    try std.testing.expectEqual(3, operations.len);
    try std.testing.expectEqual(voxel_chunk_module.BlockType.sand, operations[0].operation.action.put);
    try std.testing.expectEqual(voxel_chunk_module.BlockType.snow, operations[1].operation.action.put);
    try std.testing.expectEqual(operations[0].operation.block[1] - 1, operations[1].operation.block[1]);
    try std.testing.expect(operations[2].operation.action == .remove);
    try std.testing.expectEqual(operations[1].operation.block, operations[2].operation.block);
    try std.testing.expect(try fixture.game.world.?.isBlockSolid(operations[0].operation.block));
    try std.testing.expect(!try fixture.game.world.?.isBlockSolid(operations[1].operation.block));
    try std.testing.expectEqual(0, fixture.game.tool_commands.items.len);
}

test "queued edits use the camera view updated after the press" {
    var fixture: StreamingTest = .{};
    fixture.init();
    defer fixture.deinit();
    try fixture.prepareSupportedToolTest();
    handleKeyPress(&fixture.game, .{ .key = .tab, .mods = .{} });
    const origin = test_layout.origin_chunk;
    try fixture.game.world.?.insertChunk(origin - ChunkCoords{ 0, 0, 1 }, WorldChunk.initEmpty());
    const target = StreamingTest.toolTarget();
    const placement: [3]u32 = .{ target[0], target[1] - 3, target[2] };
    try fixture.supportSandPlacement(placement);
    fixture.game.world.?.pending_operations.clearRetainingCapacity();
    handleKeyPress(&fixture.game, .{ .key = .e, .mods = .{} });
    try std.testing.expectEqual(0, fixture.game.world.?.pending_operations.items.len);
    fixture.camera.updateView(zmath.rotationX(math.pi / 2.0));
    fixture.game.updateBlockTool();
    try std.testing.expectEqual(placement, fixture.game.world.?.pending_operations.items[0].operation.block);
    try std.testing.expect(try fixture.game.world.?.isBlockSolid(target));
}

test "mouse look without holding a button and removal in the same frame use the new player and spectator aim" {
    for ([_]bool{ false, true }) |spectating| {
        var fixture: StreamingTest = .{};
        fixture.init();
        defer fixture.deinit();
        fixture.engine.time = 1;
        fixture.engine.frame_delta = 0.016;
        fixture.game.player = PlayerController.init(std.testing.allocator, .{ 0.5, 0.5, 0 });
        fixture.game.player.?.applyCamera(&fixture.camera);
        try fixture.game.world.?.insertChunk(test_layout.origin_chunk, WorldChunk.initEmpty());
        try fixture.game.world.?.insertChunk(test_layout.origin_chunk - ChunkCoords{ 0, 0, 1 }, WorldChunk.initEmpty());
        const coordinates = @import("block_coordinates.zig");
        const old_target = coordinates.fromWorld(&test_layout, .{ 0, 3, 1 }).?;
        const new_target = coordinates.fromWorld(&test_layout, .{ 3, 0, 1 }).?;
        fixture.game.world.?.setBlockUnchecked(coordinates.fromWorld(&test_layout, .{ 0, 0, -1 }).?, .stone);
        fixture.game.world.?.setBlockUnchecked(old_target, .stone);
        fixture.game.world.?.setBlockUnchecked(new_target, .stone);
        fixture.game.world.?.pending_operations.clearRetainingCapacity();

        var spectator: std.meta.Child(@TypeOf(fixture.scene.spectator_camera)) = .{
            .camera = &fixture.camera,
            .input_controller = @ptrCast(&fixture.input),
        };
        if (spectating) fixture.game.control_mode = .spectator;
        // Event polling queues X while the view still points along +y. The mouse
        // delta turns it toward +x during the current frame's camera update.
        handleKeyPress(&fixture.game, .{ .key = if (spectating) .x else .e, .mods = .{} });
        try std.testing.expectEqual(0, fixture.game.world.?.pending_operations.items.len);
        fixture.input.cursor_position_delta = .{ math.pi / 0.01, 0 };
        fixture.input.cursor_left_button_pressed = false;
        if (spectating) spectator.update(0.016);
        fixture.game.updatePlayer(false);
        fixture.game.updateBlockTool();
        if (!spectating) {
            fixture.engine.frame_delta = player_interaction.extraction_seconds;
            fixture.game.updateBlockTool();
        }

        const operations = fixture.game.world.?.pending_operations.items;
        try std.testing.expectEqual(1, operations.len);
        try std.testing.expectEqual(new_target, operations[0].operation.block);
        try std.testing.expect(operations[0].operation.action == .remove);
        try std.testing.expect(try fixture.game.world.?.isBlockSolid(old_target));
        try std.testing.expect(!try fixture.game.world.?.isBlockSolid(new_target));
    }
}

test "block focus tracks the editable target after camera changes and optimistic edits" {
    var fixture: StreamingTest = .{};
    fixture.init();
    defer fixture.deinit();
    try fixture.prepareToolTest();
    const target = StreamingTest.toolTarget();
    fixture.game.updateBlockFocus();
    try std.testing.expectEqual(target, fixture.scene.highlighted_block.?);
    handleKeyPress(&fixture.game, .{ .key = .x, .mods = .{} });
    fixture.game.updateBlockTool();
    fixture.game.updateBlockFocus();
    try std.testing.expectEqual([3]u32{ target[0], target[1] + 1, target[2] }, fixture.scene.highlighted_block.?);
    fixture.camera.updateView(zmath.rotationY(math.pi / 2.0));
    fixture.game.updateBlockFocus();
    try std.testing.expectEqual(null, fixture.scene.highlighted_block);
    fixture.camera.updateView(zmath.identity());
    fixture.game.updateBlockFocus();
    try std.testing.expect(fixture.scene.highlighted_block != null);
    // The further block remains solid, but moving back puts it beyond reach.
    try fixture.game.world.?.insertChunk(test_layout.origin_chunk - ChunkCoords{ 0, 1, 0 }, WorldChunk.initEmpty());
    fixture.camera.updatePosition(.{ 0.5, -0.5, 0.5 });
    fixture.game.updateBlockFocus();
    try std.testing.expectEqual(null, fixture.scene.highlighted_block);
}

test "block focus clears on focus transitions or missing terrain" {
    var fixture: StreamingTest = .{};
    fixture.init();
    defer fixture.deinit();
    try fixture.prepareToolTest();
    fixture.game.updateBlockFocus();
    try std.testing.expect(fixture.scene.highlighted_block != null);
    fixture.input.focused = false;
    fixture.game.updateBlockFocus();
    try std.testing.expectEqual(null, fixture.scene.highlighted_block);
    try std.testing.expectEqual(0, fixture.scene.block_overlays.count);
    try std.testing.expectEqual(null, fixture.game.current_placement_preview);
    fixture.input.focused = true;
    fixture.input.focus_changed = true;
    fixture.game.updateBlockFocus();
    try std.testing.expectEqual(null, fixture.scene.highlighted_block);
    try std.testing.expectEqual(0, fixture.scene.block_overlays.count);
    fixture.input.focus_changed = false;
    fixture.game.updateBlockFocus();
    try std.testing.expect(fixture.scene.highlighted_block != null);
    fixture.game.world.?.removeChunk(test_layout.origin_chunk);
    fixture.game.updateBlockFocus();
    try std.testing.expectEqual(null, fixture.scene.highlighted_block);
    try std.testing.expectEqual(0, fixture.scene.block_overlays.count);
}

test "nearest-vertex previews and actions agree in both block and control modes and ignore R" {
    const coordinates = @import("block_coordinates.zig");
    for ([_]block_targeting.Mode{ .removing, .putting }) |mode| {
        for ([_]bool{ false, true }) |spectating| {
            var fixture: StreamingTest = .{};
            fixture.init();
            defer fixture.deinit();
            fixture.game.control_mode = if (spectating) .spectator else .player;
            fixture.game.block_mode = mode;
            if (!spectating and mode == .putting) fixture.game.block_interaction.inventory = .sand;
            fixture.game.selected_material = .sand;
            fixture.camera.updatePosition(.{ 0.5, 0.25, 0.5 });
            try fixture.game.world.?.insertChunk(test_layout.origin_chunk, WorldChunk.initEmpty());
            const candidate = coordinates.fromWorld(&test_layout, .{ 0, 4, 0 }).?;
            const backing = coordinates.fromWorld(&test_layout, .{ 0, 5, 0 }).?;
            fixture.game.world.?.setBlockUnchecked(if (mode == .removing) candidate else backing, .stone);
            if (mode == .putting) try fixture.supportSandPlacement(candidate);
            fixture.game.world.?.pending_operations.clearRetainingCapacity();
            fixture.game.updateBlockFocus();
            // Plain R has no block-tool action; Ctrl+R belongs to the engine's SSAO debug view.
            handleKeyPress(&fixture.game, .{ .key = .r, .mods = .{} });
            handleKeyPress(&fixture.game, .{ .key = .r, .mods = .{ .control = true } });
            try std.testing.expectEqual(0, fixture.game.tool_commands.items.len);
            if (mode == .removing) {
                try std.testing.expectEqual(candidate, fixture.scene.highlighted_block.?);
            } else {
                try std.testing.expectEqual(candidate, fixture.game.current_placement_preview.?.block);
                try std.testing.expectEqual(world_module.OperationStatus.success, fixture.game.current_placement_preview.?.result.status);
            }
            fixture.camera.updatePosition(.{ 0.5, 0, 0.5 });
            fixture.game.updateBlockFocus();
            try std.testing.expectEqual(null, fixture.scene.highlighted_block);
            try std.testing.expectEqual(null, fixture.game.current_placement_preview);
            try std.testing.expectEqual(null, fixture.game.placement_validation);
            try std.testing.expectEqual(0, fixture.scene.block_overlays.count);
            handleMouseButtonPress(&fixture.game, .{ .button = .left, .mods = .{} });
            fixture.game.updateBlockTool();
            try std.testing.expectEqual(0, fixture.game.world.?.pending_operations.items.len);
            handleMouseButtonRelease(&fixture.game, .{ .button = .left, .mods = .{} });
            fixture.camera.updatePosition(.{ 0.5, 0.25, 0.5 });
            fixture.game.updateBlockFocus();
            handleMouseButtonPress(&fixture.game, .{ .button = .left, .mods = .{} });
            fixture.game.updateBlockTool();
            if (!spectating) {
                fixture.engine.frame_delta = if (mode == .putting) player_interaction.placement_seconds else player_interaction.extraction_seconds;
                fixture.game.updateBlockTool();
            }
            try std.testing.expectEqual(1, fixture.game.world.?.pending_operations.items.len);
            try std.testing.expectEqual(candidate, fixture.game.world.?.pending_operations.items[0].operation.block);
            try std.testing.expectEqual(mode == .putting, try fixture.game.world.?.isBlockSolid(candidate));
        }
    }
}

test "observer removes and replaces the same slot without camera movement" {
    const coordinates = @import("block_coordinates.zig");
    var fixture: StreamingTest = .{};
    fixture.init();
    defer fixture.deinit();
    fixture.game.control_mode = .spectator;
    fixture.game.selected_material = .sand;
    fixture.camera.updatePosition(.{ 0.5, 0.5, 0.5 });
    try fixture.game.world.?.insertChunk(test_layout.origin_chunk, WorldChunk.initEmpty());
    const candidate = coordinates.fromWorld(&test_layout, .{ 0, 4, 0 }).?;
    const backing = coordinates.fromWorld(&test_layout, .{ 0, 5, 0 }).?;
    fixture.game.world.?.setBlockUnchecked(candidate, .stone);
    fixture.game.world.?.setBlockUnchecked(backing, .stone);
    try fixture.supportSandPlacement(candidate);
    fixture.game.world.?.pending_operations.clearRetainingCapacity();
    fixture.game.updateBlockFocus();
    try std.testing.expectEqual(candidate, fixture.scene.highlighted_block.?);
    handleKeyPress(&fixture.game, .{ .key = .x, .mods = .{} });
    fixture.game.updateBlockTool();
    fixture.game.updateBlockFocus();
    // The backing face is 4.5 m away and its cube is not removable.
    try std.testing.expectEqual(null, fixture.scene.highlighted_block);
    handleKeyPress(&fixture.game, .{ .key = .tab, .mods = .{} });
    fixture.game.updateBlockFocus();
    try std.testing.expectEqual(candidate, fixture.game.current_placement_preview.?.block);
    try std.testing.expectEqual(world_module.OperationStatus.success, fixture.game.current_placement_preview.?.result.status);
    try std.testing.expectEqualDeep(placement_preview.allowed_color, fixture.scene.block_overlays.cells[0].color);
    handleKeyPress(&fixture.game, .{ .key = .e, .mods = .{} });
    fixture.game.updateBlockTool();
    try std.testing.expectEqual(2, fixture.game.world.?.pending_operations.items.len);
    for (fixture.game.world.?.pending_operations.items) |pending| try std.testing.expectEqual(candidate, pending.operation.block);
    try std.testing.expect(try fixture.game.world.?.isBlockSolid(candidate));
    try std.testing.expect(try fixture.game.world.?.isBlockSolid(backing));
}

test "observer Tab separates focus and placement previews and skips removal validation" {
    var fixture: StreamingTest = .{};
    fixture.init();
    defer fixture.deinit();
    try fixture.prepareToolTest();
    fixture.game.control_mode = .spectator;
    fixture.game.selected_material = .tree_trunk;
    const target = StreamingTest.toolTarget();
    const below_chunk = test_layout.origin_chunk - ChunkCoords{ 0, 0, 1 };
    try fixture.game.world.?.insertChunk(below_chunk, WorldChunk.initEmpty());
    fixture.game.world.?.setBlockUnchecked(.{ target[0], target[1] - 1, target[2] - 1 }, .stone);
    fixture.game.world.?.pending_operations.clearRetainingCapacity();

    var validation_calls: usize = 0;
    fixture.game.world.?.preview_call_counter = &validation_calls;
    fixture.game.updateBlockFocus();
    try std.testing.expectEqual(target, fixture.scene.highlighted_block.?);
    try std.testing.expectEqual(0, fixture.scene.block_overlays.count);
    try std.testing.expectEqual(null, fixture.game.placement_validation);
    try std.testing.expectEqual(null, fixture.game.current_placement_preview);
    try std.testing.expectEqual(0, validation_calls);

    handleKeyPress(&fixture.game, .{ .key = .tab, .mods = .{} });
    fixture.game.updateBlockFocus();
    try std.testing.expectEqual(null, fixture.scene.highlighted_block);
    try std.testing.expectEqual(1, fixture.scene.block_overlays.count);
    try std.testing.expectEqual(world_module.OperationStatus.success, fixture.game.current_placement_preview.?.result.status);
    try std.testing.expectEqual(1, validation_calls);

    handleKeyPress(&fixture.game, .{ .key = .tab, .mods = .{} });
    try std.testing.expectEqual(0, fixture.scene.block_overlays.count);
    try std.testing.expectEqual(null, fixture.game.placement_validation);
    try std.testing.expectEqual(null, fixture.game.current_placement_preview);
    fixture.game.world.?.removeChunk(below_chunk);
    fixture.game.updateBlockFocus();
    try std.testing.expectEqual(target, fixture.scene.highlighted_block.?);
    try std.testing.expectEqual(1, validation_calls);

    handleKeyPress(&fixture.game, .{ .key = .tab, .mods = .{} });
    fixture.game.updateBlockFocus();
    try std.testing.expectEqual(null, fixture.scene.highlighted_block);
    try std.testing.expectEqual(world_module.OperationStatus.missing_data, fixture.game.current_placement_preview.?.result.status);
    try std.testing.expectEqual(2, validation_calls);
    fixture.input.focused = false;
    fixture.game.updateBlockFocus();
    try std.testing.expectEqual(null, fixture.scene.highlighted_block);
    try std.testing.expectEqual(0, fixture.scene.block_overlays.count);
    try std.testing.expectEqual(null, fixture.game.placement_validation);
    try std.testing.expectEqual(null, fixture.game.current_placement_preview);
}

test "observer left click removes instantly once per press" {
    var fixture: StreamingTest = .{};
    fixture.init();
    defer fixture.deinit();
    try fixture.prepareToolTest();
    fixture.game.control_mode = .spectator;
    handleKeyPress(&fixture.game, .{ .key = .e, .mods = .{} });
    handleMouseButtonPress(&fixture.game, .{ .button = .right, .mods = .{} });
    try std.testing.expectEqual(0, fixture.game.tool_commands.items.len);
    for (0..2) |_| handleMouseButtonPress(&fixture.game, .{ .button = .left, .mods = .{} });
    fixture.game.updateBlockTool();
    const operations = fixture.game.world.?.pending_operations.items;
    try std.testing.expectEqual(2, operations.len);
    try std.testing.expect(operations[0].operation.action == .remove);
    try std.testing.expect(operations[1].operation.action == .remove);
    try std.testing.expectEqual(StreamingTest.toolTarget(), operations[0].operation.block);
    try std.testing.expectEqual(operations[0].operation.block[1] + 1, operations[1].operation.block[1]);
    fixture.game.updateBlockTool();
    try std.testing.expectEqual(2, fixture.game.world.?.pending_operations.items.len);
}

test "placement preview shows missing footprint cells and refreshes after edits, snapshots and material selection" {
    var fixture: StreamingTest = .{};
    fixture.init();
    defer fixture.deinit();
    try fixture.prepareToolTest();
    handleKeyPress(&fixture.game, .{ .key = .tab, .mods = .{} });
    const origin = test_layout.origin_chunk;
    for ([_]ChunkCoords{ origin - ChunkCoords{ 1, 0, 0 }, origin - ChunkCoords{ 0, 0, 1 }, origin - ChunkCoords{ 1, 0, 1 } }) |chunk|
        try fixture.game.world.?.insertChunk(chunk, WorldChunk.initEmpty());
    fixture.game.selected_material = .dirt;
    var validation_calls: usize = 0;
    fixture.game.world.?.preview_call_counter = &validation_calls;
    fixture.game.updateBlockFocus();
    try std.testing.expectEqual(1, validation_calls);
    const preview = fixture.game.current_placement_preview.?;
    try std.testing.expectEqual(@import("block_rules.zig").Reason.earth_footprint, preview.result.failure.?.reason);
    try std.testing.expectEqual(10, fixture.scene.block_overlays.count);
    try std.testing.expectEqualDeep(placement_preview.rejected_color, fixture.scene.block_overlays.cells[0].color);
    try std.testing.expectEqual(0, fixture.game.world.?.pending_operations.items.len);
    try std.testing.expectEqual(null, fixture.game.world.?.last_edit_result);
    try std.testing.expect(!try fixture.game.world.?.isBlockSolid(preview.block));
    for (fixture.scene.block_overlays.cells[1..10]) |hint| {
        try std.testing.expectEqualDeep(placement_preview.problem_color, hint.color);
        try std.testing.expectEqual(@as(i64, preview.block[2]) - 1, hint.cell[2]);
        fixture.game.world.?.setBlockUnchecked(.{ @intCast(hint.cell[0]), @intCast(hint.cell[1]), @intCast(hint.cell[2]) }, .stone);
    }
    fixture.game.world.?.pending_operations.clearRetainingCapacity();
    fixture.game.updateBlockFocus();
    try std.testing.expectEqual(world_module.OperationStatus.success, fixture.game.current_placement_preview.?.result.status);
    try std.testing.expectEqual(1, fixture.scene.block_overlays.count);
    try std.testing.expectEqualDeep(placement_preview.allowed_color, fixture.scene.block_overlays.cells[0].color);
    try std.testing.expectEqual(2, validation_calls);
    fixture.game.updateBlockFocus();
    try std.testing.expectEqual(2, validation_calls);

    // A received replacement can remove support without a local tool command.
    const below_chunk = origin - ChunkCoords{ 0, 0, 1 };
    var replacement = WorldChunk.initEmpty();
    replacement.chunk_revision = fixture.game.world.?.getChunk(below_chunk).?.chunk_revision + 1;
    try fixture.game.world.?.insertChunk(below_chunk, replacement);
    fixture.game.updateBlockFocus();
    try std.testing.expectEqual(3, validation_calls);
    try std.testing.expectEqual(@import("block_rules.zig").Reason.earth_footprint, fixture.game.current_placement_preview.?.result.failure.?.reason);
    try std.testing.expect(fixture.scene.block_overlays.count > 1);
    fixture.game.selected_material = .snow;
    fixture.game.updateBlockFocus();
    try std.testing.expectEqual(4, validation_calls);
    try std.testing.expectEqual(world_module.OperationStatus.success, fixture.game.current_placement_preview.?.result.status);
    try std.testing.expectEqual(1, fixture.scene.block_overlays.count);
    fixture.game.selected_material = .dirt;
    fixture.game.world.?.removeChunk(below_chunk);
    fixture.game.updateBlockFocus();
    try std.testing.expectEqual(5, validation_calls);
    try std.testing.expectEqual(world_module.OperationStatus.missing_data, fixture.game.current_placement_preview.?.result.status);
    try std.testing.expect(fixture.scene.block_overlays.count > 1);
    try std.testing.expectEqual(0, fixture.game.world.?.pending_operations.items.len);
}

test "preview errors and timed edit feedback coexist and clear independently" {
    var fixture: StreamingTest = .{};
    fixture.init();
    defer fixture.deinit();
    try fixture.prepareToolTest();
    const origin = test_layout.origin_chunk;
    for ([_]ChunkCoords{ origin - ChunkCoords{ 1, 0, 0 }, origin - ChunkCoords{ 0, 0, 1 }, origin - ChunkCoords{ 1, 0, 1 } }) |chunk|
        try fixture.game.world.?.insertChunk(chunk, WorldChunk.initEmpty());
    fixture.game.toggleBlockMode();
    fixture.game.selected_material = .dirt;
    fixture.game.updateBlockFocus();
    var buffer: [block_diagnostics.message_capacity]u8 = undefined;
    try std.testing.expect(fixture.game.current_placement_preview.?.errorMessage(&buffer) != null);
    try std.testing.expectEqual(null, fixture.game.block_action_error.message(0));

    fixture.game.editBlockInView(.{ .place = .dirt });
    fixture.game.updateBlockFocus();
    try std.testing.expectEqualStrings(fixture.game.current_placement_preview.?.errorMessage(&buffer).?, fixture.game.block_action_error.message(0).?);
    try std.testing.expectEqual(null, fixture.game.block_action_error.message(block_messages.action_error_duration));
    try std.testing.expect(fixture.game.current_placement_preview.?.errorMessage(&buffer) != null);

    fixture.engine.time = 5;
    fixture.game.editBlockInView(.{ .place = .dirt });
    // A valid preview immediately removes the hint without erasing action feedback.
    fixture.game.selected_material = .snow;
    fixture.game.updateBlockFocus();
    try std.testing.expectEqual(null, fixture.game.current_placement_preview.?.errorMessage(&buffer));
    try std.testing.expect(fixture.game.block_action_error.message(5) != null);
    fixture.game.editBlockInView(.{ .place = .snow });
    try std.testing.expect(fixture.game.block_action_error.message(5) != null);

    fixture.game.selected_material = .dirt;
    fixture.game.updateBlockFocus();
    fixture.input.focused = false;
    fixture.game.updateBlockFocus();
    try std.testing.expectEqual(null, fixture.game.current_placement_preview);
    try std.testing.expect(fixture.game.block_action_error.message(5) != null);
    fixture.input.focused = true;
    fixture.game.updateBlockFocus();
    fixture.game.toggleBlockMode();
    try std.testing.expectEqual(null, fixture.game.current_placement_preview);
    try std.testing.expect(fixture.game.block_action_error.message(5) != null);
}

test "authoritative rejection shows owned diagnostics even after a subscription expires" {
    var fixture: StreamingTest = .{};
    fixture.init();
    defer fixture.deinit();
    try fixture.prepareToolTest();
    fixture.game.editBlockInView(.remove);
    fixture.game.world.?.pending_operations.items[0].request_id = 42;
    fixture.engine.time = 10;
    try fixture.apply(&.{.{
        .coords = test_layout.origin_chunk,
        .subscription_id = null,
        .operation = .{ .request_id = 42, .status = .constraint_violation, .failure = .{
            .reason = .would_remove_support,
            .cause = .missing_foundation,
            .subject = .{ 0, 0, 0 },
        } },
        .data = .acknowledgement,
    }});
    try std.testing.expectEqual(0, fixture.game.world.?.pending_operations.items.len);
    try std.testing.expectEqualStrings("Removal would leave an existing construction unsupported.\nCause: A suitable foundation is missing.", fixture.game.block_action_error.message(10).?);
    // Success replies do not erase an error before its timeout.
    try fixture.apply(&.{.{
        .coords = test_layout.origin_chunk,
        .subscription_id = null,
        .operation = .{ .request_id = 43, .status = .success },
        .data = .acknowledgement,
    }});
    try std.testing.expect(fixture.game.block_action_error.message(13.9) != null);
    try std.testing.expectEqual(null, fixture.game.block_action_error.message(14));
}

test "placement cache ignores distant streaming and validates each relevant change once" {
    var fixture: StreamingTest = .{};
    fixture.init();
    defer fixture.deinit();
    try fixture.prepareSupportedToolTest();
    const target = StreamingTest.toolTarget();
    fixture.game.world.?.setBlockUnchecked(.{ target[0] + 1, target[1], target[2] }, .stone);
    fixture.game.world.?.pending_operations.clearRetainingCapacity();
    handleKeyPress(&fixture.game, .{ .key = .tab, .mods = .{} });
    var validation_calls: usize = 0;
    const world = &fixture.game.world.?;
    world.preview_call_counter = &validation_calls;
    fixture.game.updateBlockFocus();
    const original_block = fixture.game.current_placement_preview.?.block;
    try std.testing.expectEqual(1, validation_calls);
    fixture.game.updateBlockFocus();
    try std.testing.expectEqual(1, validation_calls);

    const distant = test_layout.origin_chunk + ChunkCoords{ 3, 0, 0 };
    try world.insertChunk(distant, WorldChunk.initEmpty());
    fixture.game.updateBlockFocus();
    try std.testing.expectEqual(1, validation_calls);
    world.setBlockUnchecked(.{ @intCast(distant[0] * consts.CHUNK_SIZE), target[1], target[2] }, .stone);
    fixture.game.updateBlockFocus();
    try std.testing.expectEqual(1, validation_calls);
    try world.insertChunk(distant, WorldChunk.initEmpty());
    fixture.game.updateBlockFocus();
    try std.testing.expectEqual(1, validation_calls);
    world.removeChunk(distant);
    fixture.game.updateBlockFocus();
    try std.testing.expectEqual(1, validation_calls);

    const nearby = test_layout.origin_chunk - ChunkCoords{ 1, 0, 0 };
    try world.insertChunk(nearby, WorldChunk.initEmpty()); // Previously missing.
    fixture.game.updateBlockFocus();
    try std.testing.expectEqual(2, validation_calls);
    fixture.game.updateBlockFocus();
    try std.testing.expectEqual(2, validation_calls);
    const nearby_block = [3]u32{ target[0] - 1, target[1] - 1, target[2] };
    world.setBlockUnchecked(nearby_block, .stone);
    fixture.game.updateBlockFocus();
    try std.testing.expectEqual(3, validation_calls);
    world.setBlockUnchecked(nearby_block, .stone); // Rejected no-op.
    fixture.game.updateBlockFocus();
    try std.testing.expectEqual(3, validation_calls);
    try world.insertChunk(nearby, WorldChunk.initEmpty()); // Same authoritative revision, optimistic replay.
    fixture.game.updateBlockFocus();
    try std.testing.expectEqual(4, validation_calls);
    world.removeChunk(nearby);
    fixture.game.updateBlockFocus();
    try std.testing.expectEqual(5, validation_calls);
    try world.insertChunk(nearby, WorldChunk.initEmpty());
    fixture.game.updateBlockFocus();
    try std.testing.expectEqual(6, validation_calls);
    world.removeChunk(nearby);
    try world.insertChunk(nearby, WorldChunk.initEmpty()); // Eviction/reload between two frames.
    fixture.game.updateBlockFocus();
    try std.testing.expectEqual(7, validation_calls);
    var replacement = WorldChunk.initEmpty();
    replacement.chunk_revision = 10;
    try world.insertChunk(nearby, replacement);
    fixture.game.updateBlockFocus();
    try std.testing.expectEqual(8, validation_calls);
    replacement.chunk_revision = 9;
    try std.testing.expectError(error.StaleChunk, world.insertChunk(nearby, replacement));
    fixture.game.updateBlockFocus();
    try std.testing.expectEqual(8, validation_calls);

    // A new target validates even when its window has the same chunk stamps.
    fixture.camera.updatePosition(.{ 1.5, 0.5, 0.5 });
    fixture.game.updateBlockFocus();
    try std.testing.expect(!std.meta.eql(original_block, fixture.game.current_placement_preview.?.block));
    try std.testing.expectEqual(9, validation_calls);
    fixture.game.selected_material = .dirt;
    fixture.game.updateBlockFocus();
    try std.testing.expectEqual(10, validation_calls);
    fixture.game.updateBlockFocus();
    try std.testing.expectEqual(10, validation_calls);
    fixture.game.selected_material = .sand;
    fixture.game.updateBlockFocus();
    try std.testing.expectEqual(11, validation_calls);
    // Actual edits still evaluate the operation, even with a matching cached preview.
    try std.testing.expectEqual(world_module.OperationStatus.success, world.tryOperation(.{ .block = fixture.game.current_placement_preview.?.block, .action = .{ .put = .sand } }).status);
    try std.testing.expectEqual(12, validation_calls);
}

test "placement preview checks the frozen player each frame independently of structural caching" {
    var fixture: StreamingTest = .{};
    fixture.init();
    defer fixture.deinit();
    try fixture.prepareSupportedToolTest();
    handleKeyPress(&fixture.game, .{ .key = .tab, .mods = .{} });
    var validation_calls: usize = 0;
    fixture.game.world.?.preview_call_counter = &validation_calls;
    fixture.game.updateBlockFocus();
    try std.testing.expectEqual(1, validation_calls);
    fixture.game.player = PlayerController.init(std.testing.allocator, .{ 0.5, 2.5, 0 });
    fixture.game.control_mode = .spectator;
    fixture.game.updateBlockFocus();
    try std.testing.expect(fixture.game.current_placement_preview.?.overlaps_player);
    try std.testing.expectEqualDeep(placement_preview.rejected_color, fixture.scene.block_overlays.cells[0].color);
    try std.testing.expectEqual(1, validation_calls);
    fixture.game.player.?.position = .{ 10.5, 10.5, 0 };
    fixture.game.updateBlockFocus();
    try std.testing.expect(!fixture.game.current_placement_preview.?.overlaps_player);
    try std.testing.expectEqualDeep(placement_preview.allowed_color, fixture.scene.block_overlays.cells[0].color);
    try std.testing.expectEqual(1, validation_calls);
    try std.testing.expectEqual(0, fixture.game.world.?.pending_operations.items.len);
}

test "camera placement keeps structural validation and targets no block in empty air" {
    var fixture: StreamingTest = .{};
    fixture.init();
    defer fixture.deinit();
    fixture.camera.updatePosition(.{ 0.5, 0.5, 0.5 });
    const origin = test_layout.origin_chunk;
    try fixture.game.world.?.insertChunk(origin, WorldChunk.initEmpty());
    try fixture.game.world.?.insertChunk(origin - ChunkCoords{ 1, 0, 0 }, WorldChunk.initEmpty());
    try fixture.game.world.?.insertChunk(origin - ChunkCoords{ 0, 0, 1 }, WorldChunk.initEmpty());
    try fixture.game.world.?.insertChunk(origin - ChunkCoords{ 1, 0, 1 }, WorldChunk.initEmpty());
    const target: [3]u32 = .{
        @intCast(origin[0] * consts.CHUNK_SIZE),
        @intCast(origin[1] * consts.CHUNK_SIZE + 3),
        @intCast(origin[2] * consts.CHUNK_SIZE),
    };
    fixture.game.world.?.setBlockUnchecked(target, .stone);
    fixture.game.world.?.pending_operations.clearRetainingCapacity();
    fixture.game.editBlockInView(.{ .place = fixture.game.selected_material });
    try std.testing.expectEqual(world_module.OperationStatus.constraint_violation, fixture.game.world.?.last_edit_result.?.status);
    try std.testing.expectEqual(@import("block_rules.zig").Reason.earth_footprint, fixture.game.world.?.last_edit_result.?.failure.?.reason);
    try std.testing.expectEqual(0, fixture.game.world.?.pending_operations.items.len);
    // Looking away from the existing block targets empty air.
    fixture.game.selected_material = .sand;
    fixture.camera.updateView(zmath.rotationY(-math.pi / 2.0));
    fixture.game.editBlockInView(.{ .place = fixture.game.selected_material });
    fixture.game.editBlockInView(.remove);
    try std.testing.expectEqual(0, fixture.game.world.?.pending_operations.items.len);
}

test "chunk loads, edits, and snapshots share one rebuild using the final contents" {
    const allocator = std.testing.allocator;
    // Exercise mesh generation and removal without creating a GPU device.
    var grid: @import("engine").VoxelGrid = .{
        .allocator = allocator,
        .gpu_chunk_info_buffer = undefined,
        .gpu_block_buffer = undefined,
    };
    defer {
        grid.clearChunks();
        grid.chunks.deinit(allocator);
        grid.chunks_to_upload.deinit(allocator);
    }
    var scene: Scene = undefined;
    scene.voxel_grid = &grid;
    var engine: Engine = undefined;
    engine.active_scene = &scene;
    var game: Game = .{ .allocator = allocator, .engine = &engine, .world = try World.init(allocator, &test_layout) };
    defer game.world.?.deinit();
    defer game.loaded_chunk_ids.deinit(allocator);
    defer game.dirty_chunk_ids.deinit(allocator);
    defer game.chunk_subscriptions.deinit(allocator);

    const coords = ChunkCoords{ 1, 1, 1 };
    const chunk_id = test_layout.encodeChunkCoords(coords);
    const block = [3]u32{ consts.CHUNK_SIZE + 2, consts.CHUNK_SIZE + 3, consts.CHUNK_SIZE + 4 };
    var initial = WorldChunk.initEmpty();
    _ = initial.apply(allocator, .{ 2, 3, 4 }, .{ .put = .dirt });
    try game.world.?.insertChunk(coords, initial);
    game.loadChunkIfNeeded(1, 1, 1);
    game.loadChunkIfNeeded(1, 1, 1);

    game.world.?.setBlockUnchecked(block, .none);
    game.markChunksAroundBlockDirty(block);
    game.world.?.setBlockUnchecked(block, .grass);
    game.markChunksAroundBlockDirty(block);

    try game.chunk_subscriptions.put(allocator, chunk_id, 1);
    var snapshot = WorldChunk.initEmpty();
    snapshot.chunk_revision = 1;
    try std.testing.expect(applyChunkResponse(&game.world.?, &game.chunk_subscriptions, .{
        .coords = coords,
        .subscription_id = 1,
        .data = .{ .blocks = .{ .chunk = snapshot } },
    }));
    game.markChunkAndNeighborsDirty(coords);

    try std.testing.expectEqual(0, grid.chunks_to_upload.items.len);
    try std.testing.expectEqual(1, game.dirty_chunk_ids.count());
    game.rebuildDirtyChunks();
    try std.testing.expectEqual(0, game.dirty_chunk_ids.count());
    try std.testing.expectEqual(1, grid.chunks_to_upload.items.len);
    const upload = grid.chunks_to_upload.items[0];
    try std.testing.expectEqual(coords, upload.chunk_coords);
    for (upload.chunk_side_data.blocks_grouped_by_side) |side| {
        try std.testing.expectEqual(1, side.items.len);
        try std.testing.expectEqual(voxel_chunk_module.RenderMaterial.grass, side.items[0].block_type);
        try std.testing.expectEqual([3]u8{ 2, 3, 4 }, side.items[0].coords);
    }
    game.rebuildDirtyChunks();
    try std.testing.expectEqual(1, grid.chunks_to_upload.items.len);

    // After the upload, a later frame can dirty the same chunk again. Removing its last
    // block must remove its previous mesh even though there is no replacement to upload.
    grid.clearChunks();
    try grid.chunks.append(allocator, voxel_chunk_module.VoxelChunk.init(coords));
    game.world.?.setBlockUnchecked(block, .none);
    game.markChunksAroundBlockDirty(block);
    try std.testing.expectEqual(1, grid.chunks.items.len);
    game.rebuildDirtyChunks();
    try std.testing.expectEqual(0, grid.chunks.items.len);
    try std.testing.expectEqual(0, grid.chunks_to_upload.items.len);
    try std.testing.expect(game.loaded_chunk_ids.contains(chunk_id));

    // An empty loaded chunk can become visible again in a subsequent frame.
    game.world.?.setBlockUnchecked(block, .stone);
    game.markChunksAroundBlockDirty(block);
    game.rebuildDirtyChunks();
    try std.testing.expectEqual(1, grid.chunks_to_upload.items.len);
    grid.clearChunks();

    // Unloading cancels pending work, and later invalidations don't reload the chunk.
    game.markChunkAndNeighborsDirty(coords);
    game.removeChunkByIdIfNeeded(chunk_id);
    game.markChunksAroundBlockDirty(block);
    game.rebuildDirtyChunks();
    try std.testing.expectEqual(0, game.dirty_chunk_ids.count());
    try std.testing.expectEqual(0, grid.chunks_to_upload.items.len);
    try std.testing.expect(!game.loaded_chunk_ids.contains(chunk_id));
}

test "boundary edits dirty only loaded face neighbors with world wrapping and limits" {
    var game: Game = .{ .allocator = std.testing.allocator, .engine = undefined, .world = try World.init(std.testing.allocator, &test_layout) };
    defer game.world.?.deinit();
    defer game.loaded_chunk_ids.deinit(game.allocator);
    defer game.dirty_chunk_ids.deinit(game.allocator);
    const neighbors = [_]ChunkCoords{
        .{ 0, 0, 0 },
        .{ test_layout.size_in_chunks[0] - 1, 0, 0 },
        .{ 1, 0, 0 },
        .{ 0, 1, 0 },
        .{ 0, 0, 1 },
        .{ 1, 1, 1 }, // A diagonal neighbor never needs rebuilding.
    };
    for (neighbors) |coords| {
        try game.loaded_chunk_ids.put(game.allocator, test_layout.encodeChunkCoords(coords), {});
    }

    game.markChunksAroundBlockDirty(.{ 0, 0, 0 });
    game.markChunksAroundBlockDirty(.{ 0, 0, 0 });
    try std.testing.expectEqual(2, game.dirty_chunk_ids.count());
    try std.testing.expect(game.dirty_chunk_ids.contains(test_layout.encodeChunkId(0, 0, 0)));
    try std.testing.expect(game.dirty_chunk_ids.contains(test_layout.encodeChunkId(test_layout.size_in_chunks[0] - 1, 0, 0)));

    game.dirty_chunk_ids.clearRetainingCapacity();
    const last = consts.CHUNK_SIZE - 1;
    game.markChunksAroundBlockDirty(.{ last, last, last });
    try std.testing.expectEqual(4, game.dirty_chunk_ids.count());
    for ([_]usize{ 0, 2, 3, 4 }) |i| {
        try std.testing.expect(game.dirty_chunk_ids.contains(test_layout.encodeChunkCoords(neighbors[i])));
    }

    // Full snapshots invalidate all loaded face neighbors, sharing the same dirty set.
    game.markChunkAndNeighborsDirty(.{ 0, 0, 0 });
    try std.testing.expectEqual(5, game.dirty_chunk_ids.count());
    try std.testing.expect(!game.dirty_chunk_ids.contains(test_layout.encodeChunkId(1, 1, 1)));
    game.markChunksAroundBlockDirty(.{ 2 * consts.CHUNK_SIZE + 1, 1, 1 });
    try std.testing.expectEqual(5, game.dirty_chunk_ids.count());
}

test "chunk distance is the largest axis distance and wraps around x" {
    const camera = ChunkCoords{ 0, 10, 2 };
    const world_width: i32 = test_layout.size_in_chunks[0];

    try std.testing.expectEqual(0, getChunkDistance(&test_layout, test_layout.encodeChunkId(0, 10, 2), camera));
    try std.testing.expectEqual(3, getChunkDistance(&test_layout, test_layout.encodeChunkId(3, 10, 2), camera));
    try std.testing.expectEqual(1, getChunkDistance(&test_layout, test_layout.encodeChunkId(test_layout.size_in_chunks[0] - 1, 10, 2), camera));
    try std.testing.expectEqual(1, getChunkDistance(&test_layout, test_layout.encodeChunkId(0, 10, 2), .{ world_width - 1, 10, 2 }));
    try std.testing.expectEqual(1, getChunkDistance(&test_layout, test_layout.encodeChunkId(0, 10, 2), .{ -1, 10, 2 }));
    try std.testing.expectEqual(world_width / 2, getChunkDistance(&test_layout, test_layout.encodeChunkId(test_layout.size_in_chunks[0] / 2, 10, 2), camera));

    try std.testing.expectEqual(4, getChunkDistance(&test_layout, test_layout.encodeChunkId(1, 6, 2), camera));
    try std.testing.expectEqual(10, getChunkDistance(&test_layout, test_layout.encodeChunkId(0, 0, 2), camera));
    try std.testing.expectEqual(test_layout.size_in_chunks[1] - 1 - 10, getChunkDistance(&test_layout, test_layout.encodeChunkId(0, test_layout.size_in_chunks[1] - 1, 2), camera));
    try std.testing.expectEqual(2, getChunkDistance(&test_layout, test_layout.encodeChunkId(1, 11, 0), camera));
    try std.testing.expectEqual(test_layout.size_in_chunks[2] - 1 - 2, getChunkDistance(&test_layout, test_layout.encodeChunkId(1, 11, test_layout.size_in_chunks[2] - 1), camera));
    try std.testing.expectEqual(@as(u64, 2147483658), getChunkDistance(&test_layout, test_layout.encodeChunkId(0, 10, 2), .{ 0, std.math.minInt(i32), 2 }));
}

test "chunk coords wrap around x and are out of the world beyond y and z" {
    const width: i32 = test_layout.size_in_chunks[0];
    const depth: i32 = test_layout.size_in_chunks[1];
    const height: i32 = test_layout.size_in_chunks[2];

    try std.testing.expectEqual(ChunkCoords{ 1, 2, 3 }, test_layout.normalizeChunkCoords(.{ 1, 2, 3 }).?);
    try std.testing.expectEqual(ChunkCoords{ test_layout.size_in_chunks[0] - 1, 0, 0 }, test_layout.normalizeChunkCoords(.{ -1, 0, 0 }).?);
    try std.testing.expectEqual(ChunkCoords{ 0, test_layout.size_in_chunks[1] - 1, test_layout.size_in_chunks[2] - 1 }, test_layout.normalizeChunkCoords(.{ width, depth - 1, height - 1 }).?);
    try std.testing.expectEqual(ChunkCoords{ width - 1, 2, 3 }, test_layout.normalizeChunkCoords(.{ -3 * width - 1, 2, 3 }).?);
    try std.testing.expectEqual(ChunkCoords{ 1, 2, 3 }, test_layout.normalizeChunkCoords(.{ 4 * width + 1, 2, 3 }).?);
    try std.testing.expectEqual(null, test_layout.normalizeChunkCoords(.{ 0, -1, 0 }));
    try std.testing.expectEqual(null, test_layout.normalizeChunkCoords(.{ 0, depth, 0 }));
    try std.testing.expectEqual(null, test_layout.normalizeChunkCoords(.{ 0, 0, -1 }));
    try std.testing.expectEqual(null, test_layout.normalizeChunkCoords(.{ 0, 0, height }));
}

test "box around a chunk is clamped to the world along y and z only" {
    const box = fitBoxIntoWorld(&test_layout, getBoxAroundChunk(.{ 0, 1, test_layout.size_in_chunks[2] - 1 }, 2));
    try std.testing.expectEqual(ChunkCoords{ -2, 0, test_layout.size_in_chunks[2] - 3 }, box.start);
    try std.testing.expectEqual(ChunkCoords{ 2, 3, test_layout.size_in_chunks[2] - 1 }, box.end);
    try std.testing.expect(box.isContainingChunk(.{ -2, 0, test_layout.size_in_chunks[2] - 1 }));
    try std.testing.expect(!box.isContainingChunk(.{ 3, 0, test_layout.size_in_chunks[2] - 1 }));
}

test "camera at signed chunk limits requests no terrain and does not overflow" {
    var fixture: StreamingTest = .{};
    fixture.init();
    defer fixture.deinit();
    // No request can be issued: the service pointer is deliberately absent.
    fixture.camera.position = .{ 0, (@as(f64, std.math.minInt(i32)) - test_layout.origin_chunk[1]) * consts.CHUNK_SIZE, 0 };
    fixture.game.updateChunksAroundCamera(true);
    try std.testing.expectEqual(0, fixture.game.chunk_subscriptions.count());
    const box = getBoxAroundChunk(.{ 0, std.math.minInt(i32), std.math.maxInt(i32) }, 3);
    try std.testing.expectEqual(std.math.minInt(i32), box.start[1]);
    try std.testing.expectEqual(std.math.maxInt(i32), box.end[2]);
}

test "voxel upload queue retains negative spatial chunks and removes only matching coordinates" {
    var fixture: StreamingTest = .{};
    fixture.init();
    defer fixture.deinit();
    const coords: ChunkCoords = .{ -1, -2, -3 };
    fixture.grid.appendChunk(.{ .chunk_coords = coords, .chunk_side_data = .{} });
    fixture.grid.appendChunk(.{ .chunk_coords = .{ -1, -2, -4 }, .chunk_side_data = .{} });
    try std.testing.expectEqual(coords, fixture.grid.chunks_to_upload.items[0].chunk_coords);
    fixture.grid.removeChunk(coords);
    try std.testing.expectEqual(1, fixture.grid.chunks_to_upload.items.len);
    try std.testing.expectEqual(ChunkCoords{ -1, -2, -4 }, fixture.grid.chunks_to_upload.items[0].chunk_coords);
}

test "evicted edit replies retire pending work without restoring chunks" {
    var world = try World.init(std.testing.allocator, &test_layout);
    defer world.deinit();
    var subscriptions: std.AutoHashMapUnmanaged(u32, u64) = .empty;
    defer subscriptions.deinit(std.testing.allocator);
    const coords = ChunkCoords{ 0, 0, 0 };
    try world.insertChunk(coords, WorldChunk.initEmpty());
    world.setBlockUnchecked(.{ 0, 0, 0 }, .dirt);
    world.pending_operations.items[0].request_id = 7;
    world.removeChunk(coords);
    try std.testing.expect(!applyChunkResponse(&world, &subscriptions, .{
        .coords = coords,
        .subscription_id = 1,
        .operation = .{ .request_id = 7, .status = .already_exists },
        .data = .{ .blocks = .{ .chunk = WorldChunk.initEmpty() } },
    }));
    try std.testing.expect(!world.hasChunk(coords));
    try std.testing.expectEqual(0, world.pending_operations.items.len);
    // A response without a subscription must never be accepted just because both are null.
    try std.testing.expect(!applyChunkResponse(&world, &subscriptions, .{
        .coords = coords,
        .subscription_id = null,
        .data = .{ .blocks = .{ .chunk = WorldChunk.initEmpty() } },
    }));
}

test "new subscription rejects queued snapshots from an evicted generation" {
    var world = try World.init(std.testing.allocator, &test_layout);
    defer world.deinit();
    var subscriptions: std.AutoHashMapUnmanaged(u32, u64) = .empty;
    defer subscriptions.deinit(std.testing.allocator);
    const coords = ChunkCoords{ 0, 0, 0 };
    try subscriptions.put(std.testing.allocator, test_layout.encodeChunkCoords(coords), 2);
    try std.testing.expect(!applyChunkResponse(&world, &subscriptions, .{
        .coords = coords,
        .subscription_id = 1,
        .data = .{ .blocks = .{ .chunk = WorldChunk.initEmpty() } },
    }));
    try std.testing.expect(applyChunkResponse(&world, &subscriptions, .{
        .coords = coords,
        .subscription_id = 2,
        .data = .{ .blocks = .{ .chunk = WorldChunk.initEmpty() } },
    }));
    var update = WorldChunk.initEmpty();
    _ = update.apply(std.testing.allocator, .{ 1, 2, 3 }, .{ .put = .dirt });
    update.chunk_revision = 1;
    try std.testing.expect(applyChunkResponse(&world, &subscriptions, .{
        .coords = coords,
        .subscription_id = 2,
        .data = .{ .blocks = .{ .chunk = update } },
    }));
    try std.testing.expect(try world.isBlockSolid(.{ 1, 2, 3 }));
    try std.testing.expectEqual(2, subscriptions.get(test_layout.encodeChunkCoords(coords)));
}

test "unreachable chunks keep CPU blocks and queue a mesh immediately after a local reveal" {
    const allocator = std.testing.allocator;
    var grid: @import("engine").VoxelGrid = .{
        .allocator = allocator,
        .gpu_chunk_info_buffer = undefined,
        .gpu_block_buffer = undefined,
    };
    defer {
        grid.clearChunks();
        grid.chunks.deinit(allocator);
        grid.chunks_to_upload.deinit(allocator);
    }
    var scene: Scene = undefined;
    scene.voxel_grid = &grid;
    var engine: Engine = undefined;
    engine.active_scene = &scene;
    var game: Game = .{ .allocator = allocator, .engine = &engine, .world = try World.init(allocator, &test_layout) };
    defer game.world.?.deinit();
    defer game.loaded_chunk_ids.deinit(allocator);
    defer game.dirty_chunk_ids.deinit(allocator);
    defer game.chunk_subscriptions.deinit(allocator);
    const coords = ChunkCoords{ 1, 1, 2 };
    var prepared = try world_generator.WorldGenerator.prepare(.flat, std.testing.allocator, &test_layout);
    defer prepared.deinit(std.testing.allocator);
    const column = world_generator.ColumnGenerator.init(&prepared, .{ 1, 1 });
    try game.world.?.insertChunk(coords, column.generateChunk(allocator, 2));
    try game.world.?.insertChunk(.{ 1, 1, 3 }, column.generateChunk(allocator, 3));
    game.loadChunkIfNeeded(1, 1, 2);
    game.rebuildDirtyChunks();
    try std.testing.expectEqual(0, grid.chunks_to_upload.items.len);
    try std.testing.expect(game.loaded_chunk_ids.contains(test_layout.encodeChunkCoords(coords)));
    try std.testing.expect(game.world.?.getChunk(coords).?.flags.is_unreachable);
    try std.testing.expect(try game.world.?.isBlockSolid(.{ consts.CHUNK_SIZE + 8, consts.CHUNK_SIZE + 8, 2 * consts.CHUNK_SIZE + 31 }));

    // The service has not been contacted. Opening the bottom wall of the surface chunk
    // reveals the chunk below and queues its mesh in this same frame.
    const block = [3]u32{ consts.CHUNK_SIZE + 8, consts.CHUNK_SIZE + 8, 3 * consts.CHUNK_SIZE };
    game.world.?.setBlockUnchecked(block, .none);
    game.markChunksAroundBlockDirty(block);
    try std.testing.expectEqual(1, game.world.?.pending_operations.items.len);
    try std.testing.expectEqual(0, game.world.?.getChunk(coords).?.chunk_revision);
    try std.testing.expect(!game.world.?.getChunk(coords).?.flags.is_unreachable);
    game.rebuildDirtyChunks();
    try std.testing.expectEqual(1, grid.chunks_to_upload.items.len);
    try std.testing.expectEqual(coords, grid.chunks_to_upload.items[0].chunk_coords);
    for (grid.chunks_to_upload.items[0].chunk_side_data.blocks_grouped_by_side, 0..) |side, i| {
        // The neighboring chunk above now exposes only the single removed wall block.
        try std.testing.expectEqual(if (i == @intFromEnum(Side.top)) @as(usize, 1) else consts.CHUNK_SIZE * consts.CHUNK_SIZE, side.items.len);
    }
    grid.clearChunks();

    // An older in-flight load cannot hide the chunk while the wall edit is outstanding.
    try game.chunk_subscriptions.put(allocator, test_layout.encodeChunkCoords(coords), 1);
    try std.testing.expect(applyChunkResponse(&game.world.?, &game.chunk_subscriptions, .{
        .coords = coords,
        .subscription_id = 1,
        .data = .{ .blocks = .{ .chunk = column.generateChunk(allocator, 2) } },
    }));
    game.markChunkAndNeighborsDirty(coords);
    game.rebuildDirtyChunks();
    try std.testing.expectEqual(1, grid.chunks_to_upload.items.len);
    try std.testing.expectEqual(coords, grid.chunks_to_upload.items[0].chunk_coords);
    grid.clearChunks();

    // A service-only metadata change also invalidates a hidden chunk's GPU state.
    const remote_coords = ChunkCoords{ 5, 5, 2 };
    const remote_column = world_generator.ColumnGenerator.init(&prepared, .{ 5, 5 });
    try game.world.?.insertChunk(remote_coords, remote_column.generateChunk(allocator, 2));
    game.loadChunkIfNeeded(5, 5, 2);
    game.rebuildDirtyChunks();
    try std.testing.expectEqual(0, grid.chunks_to_upload.items.len);
    try game.chunk_subscriptions.put(allocator, test_layout.encodeChunkCoords(remote_coords), 2);
    var reveal = remote_column.generateChunk(allocator, 2);
    reveal.flags.is_unreachable = false;
    reveal.chunk_revision = 1;
    try std.testing.expect(applyChunkResponse(&game.world.?, &game.chunk_subscriptions, .{
        .coords = remote_coords,
        .subscription_id = 2,
        .data = .{ .blocks = .{ .chunk = reveal } },
    }));
    game.markChunkAndNeighborsDirty(remote_coords);
    game.rebuildDirtyChunks();
    try std.testing.expectEqual(1, grid.chunks_to_upload.items.len);
    try std.testing.expectEqual(remote_coords, grid.chunks_to_upload.items[0].chunk_coords);
}

/// Exercises the actual subscription and upload paths without a graphics device.
const StreamingTest = struct {
    input: std.meta.Child(@TypeOf(@as(Engine, undefined).input_controller)) = undefined,
    camera: std.meta.Child(@TypeOf(@as(Scene, undefined).camera)) = undefined,
    grid: @import("engine").VoxelGrid = undefined,
    scene: Scene = undefined,
    engine: Engine = undefined,
    game: Game = undefined,

    fn init(self: *StreamingTest) void {
        self.initWithLayout(&test_layout);
    }

    fn toolTarget() [3]u32 {
        const origin = test_layout.origin_chunk;
        return .{
            @intCast(origin[0] * consts.CHUNK_SIZE),
            @intCast(origin[1] * consts.CHUNK_SIZE + 3),
            @intCast(origin[2] * consts.CHUNK_SIZE),
        };
    }

    fn prepareToolTest(self: *StreamingTest) !void {
        self.camera.updatePosition(.{ 0.5, 0.5, 0.5 });
        self.game.control_mode = .spectator;
        self.game.selected_material = .sand;
        try self.game.world.?.insertChunk(test_layout.origin_chunk, WorldChunk.initEmpty());
        const target = toolTarget();
        self.game.world.?.setBlockUnchecked(target, .stone);
        self.game.world.?.setBlockUnchecked(.{ target[0], target[1] + 1, target[2] }, .stone);
        self.game.world.?.pending_operations.clearRetainingCapacity();
    }

    fn preparePlayerToolTest(self: *StreamingTest) !void {
        try self.prepareSupportedToolTest();
        self.game.control_mode = .player;
        self.changeToolMaterial(.sand);
        self.engine.frame_delta = 0;
    }

    fn supportSandPlacement(self: *StreamingTest, block: [3]u32) !void {
        var dy: i32 = -1;
        while (dy <= 1) : (dy += 1) {
            var dx: i32 = -1;
            while (dx <= 1) : (dx += 1) {
                const support: [3]u32 = .{ @intCast(@as(i64, block[0]) + dx), @intCast(@as(i64, block[1]) + dy), block[2] - 1 };
                const coords, _ = world_module.splitBlockCoords(support);
                if (!self.game.world.?.hasChunk(coords)) try self.game.world.?.insertChunk(coords, WorldChunk.initEmpty());
                self.game.world.?.setBlockUnchecked(support, .stone);
            }
        }
    }

    fn prepareSupportedToolTest(self: *StreamingTest) !void {
        try self.prepareToolTest();
        const target = toolTarget();
        for (0..4) |offset| for (0..2) |x|
            try self.supportSandPlacement(.{ target[0] + @as(u32, @intCast(x)), target[1] - @as(u32, @intCast(offset)), target[2] });
        self.game.world.?.pending_operations.clearRetainingCapacity();
    }

    fn changeToolMaterial(self: *StreamingTest, material: voxel_chunk_module.BlockType) void {
        const coords, const local = world_module.splitBlockCoords(toolTarget());
        self.game.world.?.chunks.getPtr(self.game.layout().encodeChunkCoords(coords)).?.changeType(local, material);
    }

    fn acknowledgePlayer(self: *StreamingTest, request_id: u64, status: world_module.OperationStatus, inventory: ?voxel_chunk_module.BlockType) !void {
        const pending = &self.game.world.?.pending_operations.items[0];
        pending.request_id = request_id;
        self.game.block_interaction.markSubmitted(request_id);
        const coords, _ = world_module.splitBlockCoords(pending.operation.block);
        try self.apply(&.{.{
            .coords = coords,
            .subscription_id = null,
            .operation = .{ .request_id = request_id, .status = status, .player_inventory = .{ .player_id = self.game.player_id, .material = inventory } },
            .data = .acknowledgement,
        }});
    }

    fn serviceOperation(client: *world_data_service.Client, operation: world_module.BlockOperation) !world_data_service.OperationResult {
        const request_id = try client.trySubmitOperation(operation);
        var responses: std.ArrayList(ChunkResponse) = .empty;
        defer {
            for (responses.items) |response| response.deinit(std.testing.allocator);
            responses.deinit(std.testing.allocator);
        }
        while (try client.waitResponses(&responses)) {
            for (responses.items) |response| if (response.operation) |result| {
                if (result.request_id == request_id) return result;
            };
            for (responses.items) |response| response.deinit(std.testing.allocator);
            responses.clearRetainingCapacity();
        }
        return error.ServiceStopped;
    }

    fn initWithLayout(self: *StreamingTest, layout: *const WorldLayout) void {
        self.scene.layout = layout;
        self.camera = @TypeOf(self.camera).init(self.scene.layout, 1);
        self.grid = .{ .allocator = std.testing.allocator, .gpu_chunk_info_buffer = undefined, .gpu_block_buffer = undefined };
        self.scene.voxel_grid = &self.grid;
        self.scene.camera = &self.camera;
        self.engine.active_scene = &self.scene;
        self.engine.time = 0;
        self.engine.real_time = 0;
        self.engine.paused = false;
        self.engine.gameplay_input_blocked = false;
        self.engine.callbacks = .{ .argument = &self.game, .onUpdate = null, .onRender = null, .onPauseChanged = onPauseChanged, .onGameplayInputChanged = onGameplayInputChanged };
        self.engine.frame_delta = 0;
        self.input = .{
            .allocator = std.testing.allocator,
            .window = undefined,
            .callbacks = .{ .context = &self.engine },
            .pressed_keys = std.AutoHashMap(zglfw.Key, void).init(std.testing.allocator),
            .release_queue = std.AutoHashMap(zglfw.Key, void).init(std.testing.allocator),
            .cursor_position = .{ 0, 0 },
        };
        self.engine.input_controller = &self.input;
        self.game = .{ .allocator = std.testing.allocator, .engine = &self.engine, .world = World.init(std.testing.allocator, self.scene.layout) catch unreachable };
    }

    fn deinit(self: *StreamingTest) void {
        const allocator = self.game.allocator;
        self.game.tool_commands.deinit(allocator);
        self.input.pressed_keys.deinit();
        self.input.release_queue.deinit();
        self.input.pressed_this_frame.deinit(allocator);
        if (self.game.player) |*player| player.deinit();
        self.game.world.?.deinit();
        self.game.chunk_subscriptions.deinit(allocator);
        self.game.block_snapshot_tokens.deinit(allocator);
        self.game.chunk_modes.deinit(allocator);
        self.game.mesh_versions.deinit(allocator);
        self.game.boundary_snapshots.deinit(allocator);
        self.game.pinned_chunks.deinit(allocator);
        self.game.loaded_chunk_ids.deinit(allocator);
        self.game.dirty_chunk_ids.deinit(allocator);
        for (self.game.chunk_packages.items) |*package| package.deinit(allocator);
        self.game.chunk_packages.deinit(allocator);
        self.grid.clearChunks();
        self.grid.chunks.deinit(allocator);
        self.grid.chunks_to_upload.deinit(allocator);
    }

    fn subscribe(self: *StreamingTest, coords: ChunkCoords, token: u64, mode: world_data_service.Representation) !void {
        try self.game.chunk_subscriptions.put(self.game.allocator, self.game.layout().encodeChunkCoords(coords), token);
        try self.game.chunk_modes.put(self.game.allocator, self.game.layout().encodeChunkCoords(coords), mode);
    }

    fn apply(self: *StreamingTest, responses: []const ChunkResponse) !void {
        var package: world_data_service.ResponsePackage = .{};
        try package.responses.appendSlice(self.game.allocator, responses);
        defer package.responses.deinit(self.game.allocator);
        self.game.applyPackage(&package);
    }

    fn settled(self: *const StreamingTest) bool {
        if (self.game.world.?.pending_operations.items.len != 0) return false;
        var iterator = self.game.chunk_modes.iterator();
        while (iterator.next()) |entry| {
            const coords = self.game.layout().decodeChunkId(entry.key_ptr.*);
            if (!self.game.loaded_chunk_ids.contains(entry.key_ptr.*)) return false;
            if ((entry.value_ptr.* == .blocks) != self.game.world.?.hasChunk(coords)) return false;
        }
        return true;
    }

    fn waitAndApplyPackages(self: *StreamingTest) !void {
        try std.testing.expect(try self.game.world_client.?.waitPackages(&self.game.chunk_packages));
        for (self.game.chunk_packages.items) |*package| {
            self.game.applyPackage(package);
            package.responses.deinit(self.game.allocator);
        }
        self.game.chunk_packages.clearRetainingCapacity();
    }

    fn upload(self: *const StreamingTest, coords: ChunkCoords) *const voxel_chunk_module.VoxelChunkUpload {
        for (self.grid.chunks_to_upload.items) |*chunk| {
            if (@reduce(.And, chunk.chunk_coords == coords)) return chunk;
        }
        @panic("Expected a queued upload for this chunk");
    }

    fn drainUntilSettled(self: *StreamingTest) !void {
        while (!self.settled()) {
            try self.waitAndApplyPackages();
            self.game.updateChunksAroundCamera(true);
            self.game.rebuildDirtyChunks();
        }
    }
};

fn singleTestBlock(local: [3]u5, revision: u64) WorldChunk {
    var chunk = WorldChunk.initEmpty();
    _ = chunk.apply(std.testing.allocator, local, .{ .put = .stone });
    chunk.chunk_revision = revision;
    return chunk;
}

test "block snapshots rebuild only the chunk and changed face neighbors" {
    const cases = [_]struct { local: [3]u5, uploads: usize }{
        .{ .local = .{ 16, 16, 16 }, .uploads = 1 },
        .{ .local = .{ 0, 16, 16 }, .uploads = 2 },
        .{ .local = .{ 31, 16, 16 }, .uploads = 2 },
        .{ .local = .{ 16, 0, 16 }, .uploads = 2 },
        .{ .local = .{ 16, 31, 16 }, .uploads = 2 },
        .{ .local = .{ 16, 16, 0 }, .uploads = 2 },
        .{ .local = .{ 16, 16, 31 }, .uploads = 2 },
        .{ .local = .{ 0, 0, 16 }, .uploads = 3 },
        .{ .local = .{ 31, 31, 31 }, .uploads = 4 },
    };
    for (cases) |case| {
        var fixture: StreamingTest = .{};
        fixture.init();
        defer fixture.deinit();
        const coords = ChunkCoords{ 0, 1, 1 }; // Includes a neighbor across the x wrap.
        try fixture.subscribe(coords, 1, .blocks);
        const initial = singleTestBlock(.{ 8, 8, 8 }, 0);
        defer initial.deinit(std.testing.allocator);
        try fixture.apply(&.{.{ .coords = coords, .subscription_id = 1, .data = .{ .blocks = .{ .chunk = initial.clone(std.testing.allocator) } } }});
        for (std.enums.values(Side)) |side| {
            const neighbor = world_module.adjacentChunk(&test_layout, coords, side).?;
            try fixture.subscribe(neighbor, 2, .blocks);
            try fixture.apply(&.{.{ .coords = neighbor, .subscription_id = 2, .data = .{ .blocks = .{ .chunk = singleTestBlock(.{ 8, 8, 8 }, 0) } } }});
        }
        fixture.game.rebuildDirtyChunks();
        fixture.grid.clearChunks();

        for (0..4) |step| {
            var snapshot = initial.clone(std.testing.allocator);
            if (step % 2 == 0) _ = snapshot.apply(std.testing.allocator, case.local, .{ .put = .dirt });
            snapshot.chunk_revision = @intCast(step + 1);
            try fixture.apply(&.{.{ .coords = coords, .subscription_id = 1, .chunk_revision = snapshot.chunk_revision, .data = .{ .blocks = .{ .chunk = snapshot } } }});
            try std.testing.expectEqual(case.uploads, fixture.game.dirty_chunk_ids.count());
            for (std.enums.values(Side)) |side| {
                const i = @intFromEnum(side);
                const neighbor = world_module.adjacentChunk(&test_layout, coords, side).?;
                const touches = case.local[i / 2] == (if (i % 2 == 0) @as(u5, 0) else consts.CHUNK_SIZE - 1);
                try std.testing.expectEqual(touches, fixture.game.dirty_chunk_ids.contains(test_layout.encodeChunkCoords(neighbor)));
            }
            fixture.game.rebuildDirtyChunks();
            try std.testing.expectEqual(case.uploads, fixture.grid.chunks_to_upload.items.len);
            fixture.grid.clearChunks();
        }
    }
}

test "simulation terrain edits queue one GPU chunk per put and remove" {
    const allocator = std.testing.allocator;
    const generator = world_generator.WorldGenerator{ .terrain = .{ .seed = 12345 } };
    var prepared = try generator.prepare(allocator, &test_layout);
    defer prepared.deinit(allocator);
    const origin = test_layout.origin_chunk;
    const column = world_generator.ColumnGenerator.init(&prepared, .{ origin[0], origin[1] });
    var surface_z: u32 = 0;
    for (0..@as(usize, @intCast(test_layout.size_in_chunks[2]))) |chunk_z| {
        const chunk = column.generateChunk(allocator, @intCast(chunk_z));
        defer chunk.deinit(allocator);
        for (0..consts.CHUNK_SIZE) |z| {
            if (chunk.content.getBlock(.{ 16, 16, @intCast(z) }) != .none)
                surface_z = @intCast(chunk_z * consts.CHUNK_SIZE + z + 1);
        }
    }
    const block = [3]u32{ @as(u32, @intCast(origin[0])) * consts.CHUNK_SIZE + 16, @as(u32, @intCast(origin[1])) * consts.CHUNK_SIZE + 16, surface_z };
    const coords, const local = world_module.splitBlockCoords(block);
    try std.testing.expectEqual([3]u32{ 8208, 4112, 106 }, block);
    try std.testing.expectEqual([3]u5{ 16, 16, 10 }, local);
    for (local) |axis| try std.testing.expect(axis > 0 and axis < consts.CHUNK_SIZE - 1);

    const service = try WorldDataService.create(std.testing.io, allocator, &test_layout, generator);
    defer service.destroy();
    var fixture: StreamingTest = .{};
    fixture.init();
    defer fixture.deinit();
    fixture.game.world_client = try service.createClient();
    const worker = try service.createClient();
    const body: terrain_collision.Body = .{};
    const spawn = try fixture.game.world_client.?.findStandingSpace(.{
        .preferred_xy = .{ -2.06, -2.96 },
        .clearance_size = .{ 2, 2, 3 },
        .support_size = .{ 2 * body.half_width, 2 * body.half_width },
        .search_radius = 8,
    });
    const camera_chunk = test_layout.getChunkCoords(spawn + Position{ 0, 0, body.eye_height });
    try std.testing.expectEqual(ChunkCoords{ 255, 127, 3 }, camera_chunk);
    // Subscribe to the same 3x3x3 block core as the game's initial player camera.
    for (0..3) |dy| {
        for (0..3) |dx| {
            const x = camera_chunk[0] + @as(i32, @intCast(dx)) - 1;
            const y = camera_chunk[1] + @as(i32, @intCast(dy)) - 1;
            const token = fixture.game.world_client.?.requestChunks(.{ x, y }, camera_chunk[2] - 1, camera_chunk[2] + 2);
            for (0..3) |dz| try fixture.subscribe(.{ x, y, camera_chunk[2] + @as(i32, @intCast(dz)) - 1 }, token, .blocks);
        }
    }
    while (!fixture.settled()) {
        try fixture.waitAndApplyPackages();
    }
    fixture.game.rebuildDirtyChunks();
    fixture.grid.clearChunks();

    for (0..4) |step| {
        _ = worker.submitOperation(.{ .block = block, .action = if (step % 2 == 0) .{ .put = .dirt } else .remove });
        try fixture.waitAndApplyPackages();
        fixture.game.rebuildDirtyChunks();
        try std.testing.expectEqual(1, fixture.grid.chunks_to_upload.items.len);
        try std.testing.expectEqual(coords, fixture.grid.chunks_to_upload.items[0].chunk_coords);
        const expected: voxel_chunk_module.BlockType = if (step % 2 == 0) .dirt else .none;
        try std.testing.expectEqual(expected, fixture.game.world.?.getChunk(coords).?.content.getBlock(local));
        fixture.grid.clearChunks();
    }
}

test "material-only boundary snapshots leave neighboring geometry unchanged" {
    var fixture: StreamingTest = .{};
    fixture.init();
    defer fixture.deinit();
    const coords = ChunkCoords{ 1, 1, 1 };
    const neighbor = ChunkCoords{ 2, 1, 1 };
    const neighbor_id = test_layout.encodeChunkCoords(neighbor);
    const local = [3]u5{ 31, 8, 8 };
    try fixture.subscribe(coords, 1, .blocks);
    try fixture.subscribe(neighbor, 2, .blocks);
    try fixture.apply(&.{
        .{ .coords = coords, .subscription_id = 1, .data = .{ .blocks = .{ .chunk = singleTestBlock(local, 0) } } },
        .{ .coords = neighbor, .subscription_id = 2, .data = .{ .blocks = .{ .chunk = singleTestBlock(.{ 0, 8, 8 }, 0) } } },
    });
    fixture.game.rebuildDirtyChunks();
    const neighbor_faces = fixture.upload(neighbor).chunk_side_data.blocks_grouped_by_side[@intFromEnum(Side.bottom)].items.ptr;
    var snapshot = singleTestBlock(local, 1);
    snapshot.changeType(local, .grass);
    try fixture.apply(&.{.{ .coords = coords, .subscription_id = 1, .chunk_revision = 1, .data = .{ .blocks = .{ .chunk = snapshot } } }});
    try std.testing.expectEqual(1, fixture.game.dirty_chunk_ids.count());
    try std.testing.expect(!fixture.game.dirty_chunk_ids.contains(neighbor_id));
    fixture.game.rebuildDirtyChunks();
    try std.testing.expectEqual(neighbor_faces, fixture.upload(neighbor).chunk_side_data.blocks_grouped_by_side[@intFromEnum(Side.bottom)].items.ptr);
    try std.testing.expectEqual(voxel_chunk_module.RenderMaterial.grass, fixture.upload(coords).chunk_side_data.blocks_grouped_by_side[@intFromEnum(Side.bottom)].items[0].block_type);
}

test "snapshot boundary invalidation follows optimistic replay and failed edit rollback" {
    var fixture: StreamingTest = .{};
    fixture.init();
    defer fixture.deinit();
    const coords = ChunkCoords{ 1, 1, 1 };
    const neighbor = ChunkCoords{ 2, 1, 1 };
    const neighbor_id = test_layout.encodeChunkCoords(neighbor);
    const local = [3]u5{ 31, 8, 8 };
    const block = [3]u32{ 63, 40, 40 };
    try fixture.subscribe(coords, 1, .blocks);
    try fixture.subscribe(neighbor, 2, .blocks);
    try fixture.apply(&.{
        .{ .coords = coords, .subscription_id = 1, .data = .{ .blocks = .{ .chunk = singleTestBlock(local, 0) } } },
        .{ .coords = neighbor, .subscription_id = 2, .data = .{ .blocks = .{ .chunk = singleTestBlock(.{ 0, 8, 8 }, 0) } } },
    });
    fixture.game.rebuildDirtyChunks();
    fixture.game.world.?.setBlockUnchecked(block, .none);
    fixture.game.world.?.pending_operations.items[0].request_id = 7;
    fixture.game.markChunksAroundBlockDirty(block);
    fixture.game.rebuildDirtyChunks();
    try std.testing.expectEqual(1, fixture.upload(neighbor).chunk_side_data.blocks_grouped_by_side[@intFromEnum(Side.left)].items.len);

    // An older authority snapshot still contains the block; pending removal is replayed.
    try fixture.apply(&.{.{ .coords = coords, .subscription_id = 1, .data = .{ .blocks = .{ .chunk = singleTestBlock(local, 0) } } }});
    try std.testing.expectEqual(voxel_chunk_module.BlockType.none, fixture.game.world.?.getChunk(coords).?.content.getBlock(local));
    try std.testing.expect(!fixture.game.dirty_chunk_ids.contains(neighbor_id));
    fixture.game.rebuildDirtyChunks();

    // A failed acknowledgment retires the removal and restores boundary occupancy.
    try fixture.apply(&.{.{ .coords = coords, .subscription_id = 1, .operation = .{ .request_id = 7, .status = .constraint_violation }, .data = .{ .blocks = .{ .chunk = singleTestBlock(local, 0) } } }});
    try std.testing.expectEqual(0, fixture.game.world.?.pending_operations.items.len);
    try std.testing.expect(fixture.game.dirty_chunk_ids.contains(neighbor_id));
    fixture.game.rebuildDirtyChunks();
    try std.testing.expectEqual(0, fixture.upload(neighbor).chunk_side_data.blocks_grouped_by_side[@intFromEnum(Side.left)].items.len);
}

test "canceled demotion and re-promotion reload neighboring mesh dependencies" {
    for ([_]bool{ false, true }) |boundaries_first| {
        var fixture: StreamingTest = .{};
        fixture.init();
        defer fixture.deinit();
        const coords = ChunkCoords{ 1, 1, 1 };
        const neighbor = ChunkCoords{ 2, 1, 1 };
        const i = @intFromEnum(Side.right);
        var solid_masks: world_engine.BoundaryMasks = @splat(.{});
        solid_masks[i].set(.right, .{ 31, 8, 8 }, true);
        try fixture.subscribe(coords, 1, .blocks);
        try fixture.subscribe(neighbor, 2, .blocks);
        try fixture.apply(&.{
            .{ .coords = coords, .subscription_id = 1, .data = .{ .blocks = .{ .chunk = singleTestBlock(.{ 31, 8, 8 }, 0), .neighbors = solid_masks } } },
            .{ .coords = neighbor, .subscription_id = 2, .data = .{ .blocks = .{ .chunk = singleTestBlock(.{ 0, 8, 8 }, 0) } } },
        });
        fixture.game.rebuildDirtyChunks();
        try std.testing.expectEqual(0, fixture.upload(coords).chunk_side_data.blocks_grouped_by_side[i].items.len);

        // Reject a remote removal on B's obsolete block subscription, retaining its blocks.
        try fixture.subscribe(neighbor, 3, .mesh);
        try fixture.apply(&.{
            .{ .coords = neighbor, .subscription_id = 2, .chunk_revision = 1, .mesh_revision = 1, .data = .{ .blocks = .{ .chunk = WorldChunk.initEmpty() } } },
            .{ .coords = coords, .subscription_id = 1, .mesh_revision = 1, .data = .{ .boundaries = @splat(.{}) } },
        });
        try std.testing.expectEqual(voxel_chunk_module.BlockType.stone, fixture.game.world.?.getChunk(neighbor).?.content.getBlock(.{ 0, 8, 8 }));
        fixture.game.rebuildDirtyChunks();
        try std.testing.expectEqual(1, fixture.upload(coords).chunk_side_data.blocks_grouped_by_side[i].items.len);

        // Restore B at the authority, then promote before the demotion mesh arrives.
        try fixture.subscribe(neighbor, 4, .blocks);
        const snapshot: ChunkResponse = .{ .coords = neighbor, .subscription_id = 4, .chunk_revision = 2, .mesh_revision = 2, .data = .{ .blocks = .{ .chunk = singleTestBlock(.{ 0, 8, 8 }, 2) } } };
        const boundaries: ChunkResponse = .{ .coords = coords, .subscription_id = 1, .mesh_revision = 2, .data = .{ .boundaries = solid_masks } };
        try fixture.apply(if (boundaries_first) &.{ boundaries, snapshot } else &.{ snapshot, boundaries });
        fixture.game.rebuildDirtyChunks();
        try std.testing.expectEqual(0, fixture.upload(coords).chunk_side_data.blocks_grouped_by_side[i].items.len);
        // A late demotion mesh cannot remove the restored local dependency.
        try fixture.apply(&.{.{ .coords = neighbor, .subscription_id = 3, .chunk_revision = 1, .mesh_revision = 1, .data = .{ .mesh = .{} } }});
        try std.testing.expect(fixture.game.world.?.hasChunk(neighbor));
    }
}

test "promotion reuses matching authoritative mesh but rejects a neighbor-only revision change" {
    var fixture: StreamingTest = .{};
    fixture.init();
    defer fixture.deinit();
    const coords = ChunkCoords{ 1, 1, 1 };
    const id = test_layout.encodeChunkCoords(coords);
    const chunk = singleTestBlock(.{ 31, 8, 8 }, 12);
    defer chunk.deinit(std.testing.allocator);
    try fixture.subscribe(coords, 1, .mesh);
    try fixture.apply(&.{.{ .coords = coords, .subscription_id = 1, .chunk_revision = 12, .mesh_revision = 20, .data = .{ .mesh = world_engine.extractChunkSideData(std.testing.allocator, chunk.content, @splat(.{})) } }});
    try std.testing.expect(!fixture.game.world.?.hasChunk(coords));
    const original_faces = fixture.grid.chunks_to_upload.items[0].chunk_side_data.blocks_grouped_by_side[0].items.ptr;
    try fixture.subscribe(coords, 2, .blocks);
    try fixture.apply(&.{.{ .coords = coords, .subscription_id = 2, .chunk_revision = 12, .mesh_revision = 20, .data = .{ .blocks = .{ .chunk = chunk.clone(std.testing.allocator) } } }});
    fixture.game.rebuildDirtyChunks();
    try std.testing.expect(fixture.game.world.?.hasChunk(coords));
    try std.testing.expect(fixture.game.mesh_versions.contains(id));
    try std.testing.expectEqual(original_faces, fixture.grid.chunks_to_upload.items[0].chunk_side_data.blocks_grouped_by_side[0].items.ptr);

    try fixture.game.world.?.insertChunk(.{ 2, 1, 1 }, singleTestBlock(.{ 0, 8, 8 }, 1));
    try fixture.apply(&.{.{ .coords = coords, .subscription_id = 2, .chunk_revision = 12, .mesh_revision = 21, .data = .{ .blocks = .{ .chunk = chunk.clone(std.testing.allocator) } } }});
    try std.testing.expect(fixture.game.dirty_chunk_ids.contains(id));
    fixture.game.rebuildDirtyChunks();
    try std.testing.expect(!fixture.game.mesh_versions.contains(id));
    try std.testing.expectEqual(1, fixture.grid.chunks_to_upload.items.len);
    try std.testing.expectEqual(0, fixture.grid.chunks_to_upload.items[0].chunk_side_data.blocks_grouped_by_side[@intFromEnum(Side.right)].items.len);
}

test "pending neighboring edit prevents canonical mesh reuse and mode tokens reject late payloads" {
    var fixture: StreamingTest = .{};
    fixture.init();
    defer fixture.deinit();
    const coords = ChunkCoords{ 1, 1, 1 };
    const neighbor = ChunkCoords{ 2, 1, 1 };
    const chunk = singleTestBlock(.{ 31, 8, 8 }, 1);
    defer chunk.deinit(std.testing.allocator);
    try fixture.game.world.?.insertChunk(neighbor, singleTestBlock(.{ 0, 8, 8 }, 1));
    try fixture.subscribe(coords, 1, .mesh);
    try fixture.apply(&.{.{ .coords = coords, .subscription_id = 1, .chunk_revision = 1, .mesh_revision = 4, .data = .{ .mesh = world_engine.extractChunkSideData(std.testing.allocator, chunk.content, fixture.game.meshNeighbors(coords)) } }});
    fixture.game.world.?.setBlockUnchecked(.{ 2 * consts.CHUNK_SIZE, consts.CHUNK_SIZE + 8, consts.CHUNK_SIZE + 8 }, .none);
    try fixture.subscribe(coords, 2, .blocks);
    try fixture.apply(&.{.{ .coords = coords, .subscription_id = 2, .chunk_revision = 1, .mesh_revision = 4, .data = .{ .blocks = .{ .chunk = chunk.clone(std.testing.allocator) } } }});
    fixture.game.rebuildDirtyChunks();
    try std.testing.expectEqual(1, fixture.grid.chunks_to_upload.items[0].chunk_side_data.blocks_grouped_by_side[@intFromEnum(Side.right)].items.len);
    // Even a numerically newer mesh cannot cross an obsolete subscription generation.
    try fixture.apply(&.{.{ .coords = coords, .subscription_id = 1, .chunk_revision = 100, .mesh_revision = 100, .data = .{ .mesh = .{} } }});
    try std.testing.expect(fixture.game.world.?.hasChunk(coords));
    try std.testing.expectEqual(1, fixture.grid.chunks_to_upload.items.len);
    try std.testing.expect(!fixture.game.mesh_versions.contains(test_layout.encodeChunkCoords(coords)));
}

test "outward faces follow remote masks while local optimistic neighbors take precedence" {
    var fixture: StreamingTest = .{};
    fixture.init();
    defer fixture.deinit();
    const coords = ChunkCoords{ 2, 1, 1 };
    fixture.game.last_camera_chunk_coords = .{ 1, 1, 1 };
    var masks: world_engine.BoundaryMasks = @splat(.{});
    masks[@intFromEnum(Side.right)] = .{ .rows = @splat(std.math.maxInt(u32)) };
    try fixture.subscribe(coords, 1, .blocks);
    try fixture.apply(&.{.{ .coords = coords, .subscription_id = 1, .data = .{ .blocks = .{ .chunk = singleTestBlock(.{ 31, 8, 8 }, 0), .neighbors = masks } } }});
    fixture.game.rebuildDirtyChunks();
    try std.testing.expectEqual(0, fixture.grid.chunks_to_upload.items[0].chunk_side_data.blocks_grouped_by_side[@intFromEnum(Side.right)].items.len);
    // A neighbor-only update exposes this outward face without loading distant blocks.
    try fixture.apply(&.{.{ .coords = coords, .subscription_id = 1, .mesh_revision = 1, .data = .{ .boundaries = @splat(.{}) } }});
    fixture.game.rebuildDirtyChunks();
    try std.testing.expectEqual(1, fixture.grid.chunks_to_upload.items[0].chunk_side_data.blocks_grouped_by_side[@intFromEnum(Side.right)].items.len);
    try std.testing.expect(!fixture.game.world.?.hasChunk(.{ 3, 1, 1 }));
    try fixture.game.world.?.insertChunk(.{ 3, 1, 1 }, singleTestBlock(.{ 0, 8, 8 }, 0));
    fixture.game.markChunkAndNeighborsDirty(.{ 3, 1, 1 });
    fixture.game.rebuildDirtyChunks();
    try std.testing.expectEqual(0, fixture.grid.chunks_to_upload.items[0].chunk_side_data.blocks_grouped_by_side[@intFromEnum(Side.right)].items.len);
    const edited = [3]u32{ 3 * consts.CHUNK_SIZE, consts.CHUNK_SIZE + 8, consts.CHUNK_SIZE + 8 };
    fixture.game.world.?.setBlockUnchecked(edited, .none);
    fixture.game.markChunksAroundBlockDirty(edited);
    // The authoritative fallback still contains the block we just removed optimistically.
    try fixture.apply(&.{.{ .coords = coords, .subscription_id = 1, .mesh_revision = 2, .data = .{ .boundaries = masks } }});
    fixture.game.rebuildDirtyChunks();
    try std.testing.expectEqual(1, fixture.grid.chunks_to_upload.items[0].chunk_side_data.blocks_grouped_by_side[@intFromEnum(Side.right)].items.len);
}

test "mixed packages retire all commands and produce one final optimistic mesh" {
    var fixture: StreamingTest = .{};
    fixture.init();
    defer fixture.deinit();
    const coords = ChunkCoords{ 1, 1, 1 };
    const block = [3]u32{ consts.CHUNK_SIZE + 8, consts.CHUNK_SIZE + 8, consts.CHUNK_SIZE + 8 };
    try fixture.subscribe(coords, 1, .blocks);
    try fixture.game.world.?.insertChunk(coords, singleTestBlock(.{ 8, 8, 8 }, 0));
    fixture.game.loadChunkIfNeeded(1, 1, 1);
    fixture.game.world.?.setBlockUnchecked(block, .none);
    fixture.game.world.?.setBlockUnchecked(block, .sand);
    fixture.game.world.?.pending_operations.items[0].request_id = 10;
    fixture.game.world.?.pending_operations.items[1].request_id = 11;
    var removed = WorldChunk.initEmpty();
    removed.chunk_revision = 1;
    try fixture.apply(&.{
        .{ .coords = coords, .subscription_id = 1, .operation = .{ .request_id = 10, .status = .success }, .chunk_revision = 1, .mesh_revision = 1, .data = .{ .blocks = .{ .chunk = removed } } },
        .{ .coords = coords, .subscription_id = 1, .operation = .{ .request_id = 11, .status = .already_exists }, .chunk_revision = 2, .mesh_revision = 2, .data = .{ .blocks = .{ .chunk = singleTestBlock(.{ 8, 8, 8 }, 2) } } },
    });
    try std.testing.expectEqual(0, fixture.game.world.?.pending_operations.items.len);
    try std.testing.expectEqual(0, fixture.grid.chunks_to_upload.items.len);
    fixture.game.rebuildDirtyChunks();
    try std.testing.expectEqual(1, fixture.grid.chunks_to_upload.items.len);
    for (fixture.grid.chunks_to_upload.items[0].chunk_side_data.blocks_grouped_by_side) |side| try std.testing.expectEqual(voxel_chunk_module.RenderMaterial.stone, side.items[0].block_type);
}

test "streaming holds 27 block chunks, pins edits across movement, and completes mesh handoffs" {
    const service = try WorldDataService.create(std.testing.io, std.testing.allocator, &test_layout, .flat);
    defer service.destroy();
    var fixture: StreamingTest = .{};
    fixture.init();
    defer fixture.deinit();
    fixture.game.world_client = try service.createClient();
    fixture.game.updateChunksAroundCamera(false);
    try fixture.drainUntilSettled();
    try std.testing.expectEqual(343, fixture.game.chunk_subscriptions.count());
    try std.testing.expectEqual(27, fixture.game.world.?.chunks.count());
    const origin = test_layout.origin_chunk;
    const block = [3]u32{ origin[0] * consts.CHUNK_SIZE, origin[1] * consts.CHUNK_SIZE + 8, origin[2] * consts.CHUNK_SIZE + 8 };
    fixture.game.world.?.setBlockUnchecked(block, .snow);
    fixture.game.markChunksAroundBlockDirty(block);
    fixture.game.flushBlockOperations();
    fixture.camera.position[0] = 64;
    fixture.game.updateChunksAroundCamera(false);
    try std.testing.expectEqual(2, fixture.game.pinned_chunks.count());
    try std.testing.expectEqual(world_data_service.Representation.blocks, fixture.game.chunk_modes.get(test_layout.encodeChunkCoords(origin)).?);
    try fixture.drainUntilSettled();
    try std.testing.expectEqual(27, fixture.game.world.?.chunks.count());
    try std.testing.expectEqual(343, fixture.game.chunk_subscriptions.count());
    try std.testing.expectEqual(0, fixture.game.pinned_chunks.count());
    try std.testing.expect(!fixture.game.world.?.hasChunk(origin));
    try std.testing.expect(fixture.game.mesh_versions.contains(test_layout.encodeChunkCoords(origin)));
    try std.testing.expect(fixture.grid.hasUploadCapacity());

    // Reverse while mesh and block requests are still in flight; obsolete tokens must drain.
    fixture.camera.position[0] = 96;
    fixture.game.updateChunksAroundCamera(false);
    fixture.camera.position[0] = 0;
    fixture.game.updateChunksAroundCamera(false);
    try fixture.drainUntilSettled();
    try std.testing.expectEqual(27, fixture.game.world.?.chunks.count());
    try std.testing.expect(try fixture.game.world.?.isBlockSolid(block));
}

test "camera tools place on the hit face and enforce four-metre cube reach" {
    var fixture: StreamingTest = .{};
    fixture.init();
    defer fixture.deinit();
    fixture.game.selected_material = .sand;
    fixture.camera.updatePosition(.{ 0.5, 0, 0.5 });
    const origin = test_layout.origin_chunk;
    try fixture.game.world.?.insertChunk(origin, WorldChunk.initEmpty());
    const target: [3]u32 = .{
        @intCast(origin[0] * consts.CHUNK_SIZE),
        @intCast(origin[1] * consts.CHUNK_SIZE + 4),
        @intCast(origin[2] * consts.CHUNK_SIZE),
    };
    const placement: [3]u32 = .{ target[0], target[1] - 1, target[2] };
    fixture.game.world.?.setBlockUnchecked(target, .stone);
    try fixture.supportSandPlacement(placement);
    fixture.game.world.?.pending_operations.clearRetainingCapacity();
    fixture.game.editBlockInView(.{ .place = fixture.game.selected_material });
    try std.testing.expect(try fixture.game.world.?.isBlockSolid(placement));
    try std.testing.expectEqual(voxel_chunk_module.BlockType.sand, fixture.game.world.?.pending_operations.items[0].operation.action.put);
    fixture.game.editBlockInView(.remove);
    try std.testing.expect(!try fixture.game.world.?.isBlockSolid(placement));
    try std.testing.expect(try fixture.game.world.?.isBlockSolid(target));
    try std.testing.expectEqual(2, fixture.game.world.?.pending_operations.items.len);
    fixture.camera.updatePosition(.{ 0.5, -1.01, 0.5 });
    // Load the camera's chunk so failure is caused by reach rather than missing data.
    try fixture.game.world.?.insertChunk(origin - ChunkCoords{ 0, 1, 0 }, WorldChunk.initEmpty());
    fixture.game.editBlockInView(.{ .place = fixture.game.selected_material });
    fixture.game.editBlockInView(.remove);
    try std.testing.expectEqual(2, fixture.game.world.?.pending_operations.items.len);
    fixture.camera.updatePosition(.{ 0.5, 0.5, 0.5 });
    fixture.game.editBlockInView(.remove);
    try std.testing.expect(!try fixture.game.world.?.isBlockSolid(target));
    try std.testing.expectEqual(3, fixture.game.world.?.pending_operations.items.len);
    fixture.game.editBlockInView(.{ .place = fixture.game.selected_material });
    try std.testing.expectEqual(3, fixture.game.world.?.pending_operations.items.len);
}

test "demotion retains complete local geometry and masks until the service mesh arrives" {
    var fixture: StreamingTest = .{};
    fixture.init();
    defer fixture.deinit();
    const coords = ChunkCoords{ 2, 2, 2 };
    fixture.game.last_camera_chunk_coords = .{ 3, 2, 2 };
    try fixture.game.world.?.insertChunk(coords, singleTestBlock(.{ 0, 8, 8 }, 0));
    fixture.game.loadChunkIfNeeded(2, 2, 2);
    fixture.game.installBoundaries(coords, @splat(.{}), 0);
    fixture.game.rebuildDirtyChunks();
    try std.testing.expectEqual(1, fixture.grid.chunks_to_upload.items[0].chunk_side_data.blocks_grouped_by_side[@intFromEnum(Side.left)].items.len);
    const original_faces = fixture.grid.chunks_to_upload.items[0].chunk_side_data.blocks_grouped_by_side[0].items.ptr;
    fixture.game.last_camera_chunk_coords = .{ 0, 2, 2 };
    try fixture.subscribe(coords, 2, .mesh);
    fixture.game.rebuildDirtyChunks();
    try std.testing.expectEqual(original_faces, fixture.grid.chunks_to_upload.items[0].chunk_side_data.blocks_grouped_by_side[0].items.ptr);
    try std.testing.expect(fixture.game.boundary_snapshots.contains(test_layout.encodeChunkCoords(coords)));
    try std.testing.expectEqual(1, fixture.grid.chunks_to_upload.items[0].chunk_side_data.blocks_grouped_by_side[@intFromEnum(Side.left)].items.len);
    try std.testing.expect(fixture.game.world.?.hasChunk(coords));
    try fixture.apply(&.{.{ .coords = coords, .subscription_id = 2, .data = .{ .mesh = .{} } }});
    try std.testing.expect(!fixture.game.world.?.hasChunk(coords));
    try std.testing.expect(!fixture.game.boundary_snapshots.contains(test_layout.encodeChunkCoords(coords)));
    try std.testing.expectEqual(1, fixture.grid.chunks_to_upload.items.len);
    for (fixture.grid.chunks_to_upload.items[0].chunk_side_data.blocks_grouped_by_side) |side| try std.testing.expectEqual(0, side.items.len);
}

test "unreachable status completes demotion without uploading and cannot hide a later reveal" {
    var fixture: StreamingTest = .{};
    fixture.init();
    defer fixture.deinit();
    const coords = ChunkCoords{ 2, 2, 2 };
    const id = test_layout.encodeChunkCoords(coords);
    const chunk = singleTestBlock(.{ 8, 8, 8 }, 0);
    defer chunk.deinit(std.testing.allocator);
    try fixture.game.world.?.insertChunk(coords, chunk.clone(std.testing.allocator));
    fixture.game.loadChunkIfNeeded(2, 2, 2);
    fixture.game.rebuildDirtyChunks();
    try fixture.subscribe(coords, 2, .mesh);
    fixture.game.markChunkDirtyIfLoaded(coords);
    // A late reply from a previous subscription must preserve the retained display.
    try fixture.apply(&.{.{ .coords = coords, .subscription_id = 1, .data = .unreachable_chunk }});
    try std.testing.expect(fixture.game.world.?.hasChunk(coords));
    try std.testing.expectEqual(1, fixture.grid.chunks_to_upload.items.len);

    try fixture.apply(&.{.{ .coords = coords, .subscription_id = 2, .chunk_revision = 0, .mesh_revision = 4, .data = .unreachable_chunk }});
    try std.testing.expect(!fixture.game.world.?.hasChunk(coords));
    try std.testing.expect(fixture.game.loaded_chunk_ids.contains(id));
    try std.testing.expect(!fixture.game.dirty_chunk_ids.contains(id));
    try std.testing.expectEqual(2, fixture.game.chunk_subscriptions.get(id).?);
    try std.testing.expectEqual(0, fixture.game.mesh_versions.get(id).?.chunk_revision);
    try std.testing.expectEqual(4, fixture.game.mesh_versions.get(id).?.mesh_revision);
    fixture.game.rebuildDirtyChunks();
    try std.testing.expectEqual(0, fixture.grid.chunks_to_upload.items.len);

    // The same subscription resumes mesh delivery when its enclosure is opened.
    try fixture.apply(&.{.{ .coords = coords, .subscription_id = 2, .chunk_revision = 1, .mesh_revision = 5, .data = .{ .mesh = world_engine.extractChunkSideData(std.testing.allocator, chunk.content, @splat(.{})) } }});
    try fixture.apply(&.{.{ .coords = coords, .subscription_id = 2, .chunk_revision = 0, .mesh_revision = 4, .data = .unreachable_chunk }});
    try std.testing.expectEqual(1, fixture.grid.chunks_to_upload.items.len);
    try std.testing.expectEqual(5, fixture.game.mesh_versions.get(id).?.mesh_revision);
    for (fixture.grid.chunks_to_upload.items[0].chunk_side_data.blocks_grouped_by_side) |side| try std.testing.expectEqual(1, side.items.len);
}

test "GPU preflight reduces subscriptions to 5x5x5 without writing a partial upload" {
    const service = try WorldDataService.create(std.testing.io, std.testing.allocator, &test_layout, .flat);
    defer service.destroy();
    var fixture: StreamingTest = .{};
    fixture.init();
    defer fixture.deinit();
    fixture.game.world_client = try service.createClient();
    // Occupy every allocator span. The undefined graphics device must never be accessed.
    for (0..64) |_| _ = try fixture.grid.gpu_block_buffer_manager.occupyBlock(.{ .size_exponent = 6 });
    var mesh: voxel_chunk_module.ChunkSideData = .{};
    try mesh.blocks_grouped_by_side[0].append(std.testing.allocator, .{ .coords = .{ 8, 8, 8 }, .block_type = .stone });
    fixture.grid.appendChunk(.{ .chunk_coords = .{ 0, 0, 0 }, .chunk_side_data = mesh });
    fixture.game.updateWorld();
    try std.testing.expectEqual(2, fixture.game.render_radius);
    try std.testing.expectEqual(125, fixture.game.chunk_subscriptions.count());
    try std.testing.expect(fixture.game.gpu_capacity_warning);
    try std.testing.expect(fixture.grid.chunks_to_upload.items.len > 0);
}

test "movement retains certified meshes and remote boundary changes invalidate them without movement" {
    const service = try WorldDataService.create(std.testing.io, std.testing.allocator, &test_layout, .flat);
    defer service.destroy();
    var fixture: StreamingTest = .{};
    fixture.init();
    defer fixture.deinit();
    fixture.game.world_client = try service.createClient();
    const origin = test_layout.origin_chunk;
    const coords = ChunkCoords{ origin[0] + 1, origin[1], origin[2] };
    const id = test_layout.encodeChunkCoords(coords);
    const chunk = singleTestBlock(.{ 31, 8, 8 }, 1);
    defer chunk.deinit(std.testing.allocator);
    var neighbors: world_engine.BoundaryMasks = @splat(.{});
    neighbors[@intFromEnum(Side.right)] = .{ .rows = @splat(std.math.maxInt(u32)) };
    try fixture.subscribe(coords, 1, .mesh);
    try fixture.apply(&.{.{ .coords = coords, .subscription_id = 1, .chunk_revision = 1, .mesh_revision = 1, .data = .{ .mesh = world_engine.extractChunkSideData(std.testing.allocator, chunk.content, neighbors) } }});
    try fixture.subscribe(coords, 2, .blocks);
    try fixture.apply(&.{.{ .coords = coords, .subscription_id = 2, .chunk_revision = 1, .mesh_revision = 1, .data = .{ .blocks = .{ .chunk = chunk.clone(std.testing.allocator), .neighbors = neighbors } } }});
    try std.testing.expect(!fixture.game.dirty_chunk_ids.contains(id));
    fixture.game.last_camera_chunk_coords = origin;
    fixture.camera.position[0] = 32;
    fixture.game.updateChunksAroundCamera(false);
    try std.testing.expect(!fixture.game.dirty_chunk_ids.contains(id));
    try std.testing.expect(fixture.game.mesh_versions.contains(id));
    try fixture.apply(&.{.{ .coords = coords, .subscription_id = 2, .mesh_revision = 2, .data = .{ .boundaries = @splat(.{}) } }});
    try std.testing.expect(fixture.game.dirty_chunk_ids.contains(id));
    fixture.game.rebuildDirtyChunks();
    try std.testing.expectEqual(1, fixture.grid.chunks_to_upload.items[0].chunk_side_data.blocks_grouped_by_side[@intFromEnum(Side.right)].items.len);
}

test "newer boundary inputs prevent promotion reuse in either package order and reject stale planes" {
    for ([_]bool{ false, true }) |boundaries_first| {
        var fixture: StreamingTest = .{};
        fixture.init();
        defer fixture.deinit();
        const coords = ChunkCoords{ 1, 1, 1 };
        const id = test_layout.encodeChunkCoords(coords);
        const chunk = singleTestBlock(.{ 31, 8, 8 }, 1);
        defer chunk.deinit(std.testing.allocator);
        try fixture.subscribe(coords, 1, .mesh);
        try fixture.apply(&.{.{ .coords = coords, .subscription_id = 1, .chunk_revision = 1, .mesh_revision = 8, .data = .{ .mesh = world_engine.extractChunkSideData(std.testing.allocator, chunk.content, @splat(.{})) } }});
        try fixture.subscribe(coords, 2, .blocks);
        var masks: world_engine.BoundaryMasks = @splat(.{});
        masks[@intFromEnum(Side.right)].set(.right, .{ 31, 8, 8 }, true);
        const block_response: ChunkResponse = .{ .coords = coords, .subscription_id = 2, .chunk_revision = 1, .mesh_revision = 8, .data = .{ .blocks = .{ .chunk = chunk.clone(std.testing.allocator), .neighbors = @splat(.{}) } } };
        const mask_response: ChunkResponse = .{ .coords = coords, .subscription_id = 2, .mesh_revision = 9, .data = .{ .boundaries = masks } };
        try fixture.apply(if (boundaries_first) &.{ mask_response, block_response } else &.{ block_response, mask_response });
        try std.testing.expectEqual(9, fixture.game.boundary_snapshots.get(id).?.mesh_revision);
        try std.testing.expect(fixture.game.dirty_chunk_ids.contains(id));
        // Applying a package never uploads intermediate local geometry.
        try std.testing.expectEqual(1, fixture.grid.chunks_to_upload.items[0].chunk_side_data.blocks_grouped_by_side[@intFromEnum(Side.right)].items.len);
        fixture.game.rebuildDirtyChunks();
        try std.testing.expectEqual(0, fixture.grid.chunks_to_upload.items[0].chunk_side_data.blocks_grouped_by_side[@intFromEnum(Side.right)].items.len);
        try fixture.apply(&.{
            .{ .coords = coords, .subscription_id = 2, .mesh_revision = 8, .data = .{ .boundaries = @splat(.{}) } },
            .{ .coords = coords, .subscription_id = 1, .mesh_revision = 100, .data = .{ .boundaries = @splat(.{}) } },
        });
        try std.testing.expectEqual(9, fixture.game.boundary_snapshots.get(id).?.mesh_revision);
        try std.testing.expect(!fixture.game.dirty_chunk_ids.contains(id));
    }
}

test "fresh remote masks override unsubscribed blocks retained during neighbor demotion" {
    var fixture: StreamingTest = .{};
    fixture.init();
    defer fixture.deinit();
    const coords = ChunkCoords{ 1, 1, 1 };
    const neighbor = ChunkCoords{ 2, 1, 1 };
    try fixture.subscribe(coords, 1, .blocks);
    try fixture.subscribe(neighbor, 2, .blocks);
    try fixture.game.world.?.insertChunk(coords, singleTestBlock(.{ 31, 8, 8 }, 0));
    try fixture.game.world.?.insertChunk(neighbor, singleTestBlock(.{ 0, 8, 8 }, 0));
    fixture.game.loadChunkIfNeeded(1, 1, 1);
    fixture.game.rebuildDirtyChunks();
    try std.testing.expectEqual(0, fixture.grid.chunks_to_upload.items[0].chunk_side_data.blocks_grouped_by_side[@intFromEnum(Side.right)].items.len);
    try fixture.subscribe(neighbor, 3, .mesh);
    try fixture.apply(&.{.{ .coords = coords, .subscription_id = 1, .mesh_revision = 1, .data = .{ .boundaries = @splat(.{}) } }});
    fixture.game.rebuildDirtyChunks();
    try std.testing.expect(fixture.game.world.?.hasChunk(neighbor));
    try std.testing.expectEqual(1, fixture.grid.chunks_to_upload.items[0].chunk_side_data.blocks_grouped_by_side[@intFromEnum(Side.right)].items.len);
}

test "boundary changes opposite air retain masks without rebuilding and affect later optimistic placement" {
    for (std.enums.values(Side)) |side| {
        var fixture: StreamingTest = .{};
        fixture.init();
        defer fixture.deinit();
        const coords = ChunkCoords{ 2, 2, 2 };
        const id = test_layout.encodeChunkCoords(coords);
        const i = @intFromEnum(side);
        const axis = i / 2;
        var local = [3]u5{ 8, 11, 15 };
        local[axis] = if (i % 2 == 0) 0 else consts.CHUNK_SIZE - 1;
        var opposite_air = local;
        opposite_air[(axis + 1) % 3] = 18;
        var masks: world_engine.BoundaryMasks = @splat(.{});
        masks[i].set(side, opposite_air, true);
        try fixture.subscribe(coords, 1, .blocks);
        try fixture.apply(&.{.{ .coords = coords, .subscription_id = 1, .mesh_revision = 1, .data = .{ .blocks = .{ .chunk = singleTestBlock(local, 0), .neighbors = masks } } }});
        fixture.game.rebuildDirtyChunks();
        const original_faces = fixture.grid.chunks_to_upload.items[0].chunk_side_data.blocks_grouped_by_side[i].items.ptr;
        try std.testing.expectEqual(1, fixture.grid.chunks_to_upload.items[0].chunk_side_data.blocks_grouped_by_side[i].items.len);

        try fixture.apply(&.{.{ .coords = coords, .subscription_id = 1, .mesh_revision = 2, .data = .{ .boundaries = @splat(.{}) } }});
        try std.testing.expect(!fixture.game.dirty_chunk_ids.contains(id));
        try std.testing.expectEqual(2, fixture.game.boundary_snapshots.get(id).?.mesh_revision);
        try std.testing.expect(!fixture.game.boundary_snapshots.get(id).?.masks[i].contains(side, opposite_air));
        fixture.game.rebuildDirtyChunks();
        try std.testing.expectEqual(original_faces, fixture.grid.chunks_to_upload.items[0].chunk_side_data.blocks_grouped_by_side[i].items.ptr);

        // This placement must use the updated plane even though no rebuild accompanied it.
        const block = [3]u32{
            @as(u32, @intCast(coords[0])) * consts.CHUNK_SIZE + opposite_air[0],
            @as(u32, @intCast(coords[1])) * consts.CHUNK_SIZE + opposite_air[1],
            @as(u32, @intCast(coords[2])) * consts.CHUNK_SIZE + opposite_air[2],
        };
        fixture.game.world.?.setBlockUnchecked(block, .sand);
        fixture.game.markChunksAroundBlockDirty(block);
        fixture.game.rebuildDirtyChunks();
        try std.testing.expectEqual(2, fixture.grid.chunks_to_upload.items[0].chunk_side_data.blocks_grouped_by_side[i].items.len);

        masks[i].set(side, opposite_air, false);
        masks[i].set(side, local, true);
        try fixture.apply(&.{.{ .coords = coords, .subscription_id = 1, .mesh_revision = 3, .data = .{ .boundaries = masks } }});
        try std.testing.expect(fixture.game.dirty_chunk_ids.contains(id));
        fixture.game.rebuildDirtyChunks();
        try std.testing.expectEqual(1, fixture.grid.chunks_to_upload.items[0].chunk_side_data.blocks_grouped_by_side[i].items.len);
        try fixture.apply(&.{.{ .coords = coords, .subscription_id = 1, .mesh_revision = 4, .data = .{ .boundaries = @splat(.{}) } }});
        try std.testing.expect(fixture.game.dirty_chunk_ids.contains(id));
        fixture.game.rebuildDirtyChunks();
        try std.testing.expectEqual(2, fixture.grid.chunks_to_upload.items[0].chunk_side_data.blocks_grouped_by_side[i].items.len);
    }
}

test "authoritative fallback changes do not rebuild faces supplied by an optimistic local neighbor" {
    var fixture: StreamingTest = .{};
    fixture.init();
    defer fixture.deinit();
    const coords = ChunkCoords{ 1, 1, 1 };
    const neighbor = ChunkCoords{ 2, 1, 1 };
    const id = test_layout.encodeChunkCoords(coords);
    const i = @intFromEnum(Side.right);
    var masks: world_engine.BoundaryMasks = @splat(.{});
    masks[i].set(.right, .{ 31, 8, 8 }, true);
    try fixture.subscribe(coords, 1, .blocks);
    try fixture.subscribe(neighbor, 2, .blocks);
    try fixture.game.world.?.insertChunk(neighbor, singleTestBlock(.{ 0, 8, 8 }, 0));
    try fixture.apply(&.{.{ .coords = coords, .subscription_id = 1, .mesh_revision = 1, .data = .{ .blocks = .{ .chunk = singleTestBlock(.{ 31, 8, 8 }, 0), .neighbors = masks } } }});
    fixture.game.rebuildDirtyChunks();
    const edited = [3]u32{ 2 * consts.CHUNK_SIZE, consts.CHUNK_SIZE + 8, consts.CHUNK_SIZE + 8 };
    fixture.game.world.?.setBlockUnchecked(edited, .none);
    fixture.game.markChunksAroundBlockDirty(edited);
    fixture.game.rebuildDirtyChunks();
    try std.testing.expectEqual(1, fixture.grid.chunks_to_upload.items[0].chunk_side_data.blocks_grouped_by_side[i].items.len);
    const original_faces = fixture.grid.chunks_to_upload.items[0].chunk_side_data.blocks_grouped_by_side[i].items.ptr;
    try fixture.apply(&.{.{ .coords = coords, .subscription_id = 1, .mesh_revision = 2, .data = .{ .boundaries = @splat(.{}) } }});
    try std.testing.expect(!fixture.game.dirty_chunk_ids.contains(id));
    try std.testing.expect(!fixture.game.boundary_snapshots.get(id).?.masks[i].contains(.right, .{ 31, 8, 8 }));
    fixture.game.rebuildDirtyChunks();
    try std.testing.expectEqual(original_faces, fixture.grid.chunks_to_upload.items[0].chunk_side_data.blocks_grouped_by_side[i].items.ptr);
}

test "different runtime layouts stream, edit, and evict across their own x seams" {
    const layouts = [_]WorldLayout{
        try WorldLayout.init(.{ .size_in_chunks = .{ 128, 64, 16 } }),
        try WorldLayout.init(.{ .size_in_chunks = .{ 256, 128, 4 } }),
    };
    const first_service = try WorldDataService.create(std.testing.io, std.testing.allocator, &layouts[0], .flat);
    defer first_service.destroy();
    const second_service = try WorldDataService.create(std.testing.io, std.testing.allocator, &layouts[1], .flat);
    defer second_service.destroy();
    for ([_]*WorldDataService{ first_service, second_service }) |service| {
        const layout = service.layout;
        var fixture: StreamingTest = .{};
        fixture.initWithLayout(layout);
        defer fixture.deinit();
        fixture.game.world_client = try service.createClient();
        const half_width: f64 = @floatFromInt(layout.size_in_blocks[0] / 2);
        fixture.camera.position[0] = -half_width + 0.5;
        fixture.game.updateChunksAroundCamera(false);
        try fixture.drainUntilSettled();
        const expected_z: usize = @intCast(@min(layout.size_in_chunks[2], 7));
        try std.testing.expectEqual(49 * expected_z, fixture.game.chunk_subscriptions.count());
        try std.testing.expectEqual(27, fixture.game.world.?.chunks.count());
        const origin = layout.origin_chunk;
        const local = ChunkCoords{ 0, origin[1], origin[2] };
        const neighbor = ChunkCoords{ layout.size_in_chunks[0] - 1, origin[1], origin[2] };
        try std.testing.expect(fixture.game.world.?.hasChunk(local));
        try std.testing.expect(fixture.game.world.?.hasChunk(neighbor));
        const block = [3]u32{ 0, @as(u32, @intCast(origin[1])) * consts.CHUNK_SIZE + 8, @as(u32, @intCast(origin[2])) * consts.CHUNK_SIZE + 8 };
        fixture.game.world.?.setBlockUnchecked(block, .snow);
        fixture.game.markChunksAroundBlockDirty(block);
        fixture.game.flushBlockOperations();
        try std.testing.expect(fixture.game.dirty_chunk_ids.contains(layout.encodeChunkCoords(neighbor)));
        fixture.camera.position[0] -= 1;
        fixture.game.updateChunksAroundCamera(false);
        try std.testing.expectEqual(layout.size_in_chunks[0] - 1, fixture.game.last_camera_chunk_coords.?[0]);
        try fixture.drainUntilSettled();
        try std.testing.expect(try fixture.game.world.?.isBlockSolid(block));
        fixture.camera.position[0] = 0;
        fixture.game.updateChunksAroundCamera(false);
        try fixture.drainUntilSettled();
        try std.testing.expect(!fixture.game.world.?.hasChunk(local));
        try std.testing.expect(!fixture.game.chunk_subscriptions.contains(layout.encodeChunkCoords(neighbor)));
    }
}

test {
    _ = @import("persistence/lifecycle_tests.zig");
    _ = @import("persistence_service_tests.zig");
}

test "shutdown cannot save ahead of optimistic edits that have not been admitted" {
    const allocator = std.testing.allocator;
    var uuid: [16]u8 = undefined;
    std.c.arc4random_buf(&uuid, uuid.len);
    const path = try std.fmt.allocPrintSentinel(allocator, "/private/tmp/persistence-app-drain-{x}", .{uuid}, 0);
    defer allocator.free(path);
    defer std.Io.Dir.cwd().deleteTree(std.testing.io, path) catch {};
    const descriptor = try persistence_format.encodeDescriptor(allocator, .{
        .dimensions = test_layout.size_in_chunks,
        .generator_id = 2,
        .seed = 0,
        .settings = &persistence_format.flat_settings,
    });
    defer allocator.free(descriptor);
    const global = persistence_format.encodeGlobal(0);
    var store = try persistence_storage.Store.create(allocator, path, .{
        .world_uuid = uuid,
        .descriptor = descriptor,
        .global = &global,
        .players = &.{},
        .player_count = 0,
    }, .{});
    defer store.deinit();
    // Zero authority slots deterministically exercises the not-admitted state.
    const service = try WorldDataService.createPersistent(std.testing.io, allocator, &test_layout, .flat, &store, .{ .pending_commands = 0 });
    defer service.destroy();
    var fixture: StreamingTest = .{};
    fixture.init();
    defer fixture.deinit();
    try fixture.preparePlayerToolTest();
    const game = &fixture.game;
    game.world_client = try service.createClient();
    game.world_data = service;
    game.persistence_store = &store;
    game.player = PlayerController.init(allocator, .{ 0, 0, 0 });
    game.block_interaction.press(.key);
    game.updateBlockTool();
    fixture.engine.frame_delta = 3;
    game.updateBlockTool();
    game.flushBlockOperations();
    try std.testing.expectEqual(voxel_chunk_module.BlockType.sand, game.heldMaterial().?);
    try std.testing.expectEqual(null, game.block_interaction.pending.?.request_id);
    try std.testing.expectEqual(@as(usize, 1), game.world.?.pending_operations.items.len);
    try std.testing.expectEqual(null, game.world.?.pending_operations.items[0].request_id);
    try std.testing.expectEqual(@as(u64, 0), game.world_client.?.last_operation_id);
    fixture.engine.callbacks.onCloseRequest = onCloseRequest;
    game.setOverlay(.menu);
    game.handleMenuAction(.exit_game);
    try std.testing.expect(game.exit_requested);
    try std.testing.expectEqual(.none, game.overlay);
    game.setOverlay(.menu);
    try std.testing.expectEqual(.none, game.overlay);
    try std.testing.expectEqual(null, game.exit_intent);
    try std.testing.expectEqual(@as(u64, 0), service.persistenceStatus().intent_id);
    // Canceling this drain restores controls without discarding the intent.
    game.cancelExit();
    try std.testing.expect(!game.exit_requested);
    try std.testing.expect(!fixture.engine.paused);
    try std.testing.expect(!fixture.engine.gameplay_input_blocked);
    try std.testing.expectEqual(voxel_chunk_module.BlockType.sand, game.heldMaterial().?);
    try std.testing.expect(game.block_interaction.pending != null);
    try std.testing.expectEqual(@as(usize, 1), game.world.?.pending_operations.items.len);
}

test "persistent service initialization releases partial ownership at every allocation failure" {
    const allocator = std.testing.allocator;
    var uuid: [16]u8 = undefined;
    std.c.arc4random_buf(&uuid, uuid.len);
    const path = try std.fmt.allocPrintSentinel(allocator, "/private/tmp/persistence-service-init-{x}", .{uuid}, 0);
    defer allocator.free(path);
    defer std.Io.Dir.cwd().deleteTree(std.testing.io, path) catch {};
    const descriptor = try persistence_format.encodeDescriptor(allocator, .{
        .dimensions = test_layout.size_in_chunks,
        .generator_id = 2,
        .seed = 0,
        .settings = &persistence_format.flat_settings,
    });
    defer allocator.free(descriptor);
    const global = persistence_format.encodeGlobal(12);
    const player = try persistence_format.encodePlayer(.{ .id = 1, .feet = .{ 0, 0, 0 }, .yaw = 0, .pitch = 0 });
    var store = try persistence_storage.Store.create(allocator, path, .{
        .world_uuid = uuid,
        .descriptor = descriptor,
        .global = &global,
        .players = &player,
        .player_count = 1,
    }, .{});
    defer store.deinit();
    const Probe = struct {
        fn run(a: std.mem.Allocator, saved: *persistence_storage.Store) !void {
            const service = try WorldDataService.createPersistent(std.testing.io, a, &test_layout, .flat, saved, .{});
            defer service.destroy();
            try std.testing.expectEqual(@as(u64, 12), service.restoredTick());
            try std.testing.expectEqual(@as(u64, 1), service.restoredPlayer(1).?.id);
        }
    };
    try std.testing.checkAllAllocationFailures(allocator, Probe.run, .{&store});
}

test "snapshot rebase allocation failure renews subscription and accepts replacement" {
    var fixture: StreamingTest = .{};
    fixture.init();
    defer fixture.deinit();
    const game = &fixture.game;
    const service = try WorldDataService.create(std.testing.io, std.testing.allocator, &test_layout, .flat);
    defer service.destroy();
    game.world_client = try service.createClient();
    const coords = test_layout.origin_chunk;
    const id = test_layout.encodeChunkCoords(coords);
    try fixture.subscribe(coords, 99, .blocks);
    var snapshot = WorldChunk.initEmpty();
    snapshot.chunk_revision = 5;
    var failing = std.testing.FailingAllocator.init(std.testing.allocator, .{ .fail_index = 0 });
    game.world.?.allocator = failing.allocator();
    fixture.apply(&.{.{ .coords = coords, .subscription_id = 99, .chunk_revision = 5, .data = .{ .blocks = .{ .chunk = snapshot } } }}) catch |err| {
        game.world.?.allocator = std.testing.allocator;
        return err;
    };
    game.world.?.allocator = std.testing.allocator;
    try std.testing.expect(!game.world.?.hasChunk(coords));
    try std.testing.expectEqual(@as(?u64, 99), game.chunk_subscriptions.get(id));
    try std.testing.expectEqual(@as(?world_data_service.Representation, null), game.chunk_modes.get(id));
    game.requestChunkMode(coords, .blocks);
    const fresh = game.chunk_subscriptions.get(id).?;
    try std.testing.expect(fresh != 99);
    try fixture.apply(&.{.{ .coords = coords, .subscription_id = fresh, .chunk_revision = 5, .data = .{ .blocks = .{ .chunk = snapshot } } }});
    try std.testing.expectEqual(@as(u64, 5), game.world.?.getChunk(coords).?.chunk_revision);
    try std.testing.expectEqual(@as(usize, 0), game.world.?.pending_operations.items.len);
}

test "player holds E or mouse for three seconds to extract and one second to place" {
    for ([_]player_interaction.Source{ .key, .mouse }) |source| {
        var fixture: StreamingTest = .{};
        fixture.init();
        defer fixture.deinit();
        try fixture.preparePlayerToolTest();
        const game = &fixture.game;
        const target = StreamingTest.toolTarget();
        game.block_interaction.press(source);
        game.updateBlockTool();
        fixture.engine.frame_delta = 2.5;
        game.updateBlockTool();
        try std.testing.expect(try game.world.?.isBlockSolid(target));
        try std.testing.expectEqual(null, game.heldMaterial());
        try std.testing.expectEqual(0, game.world.?.pending_operations.items.len);
        fixture.engine.frame_delta = 0.5;
        game.updateBlockTool();
        try std.testing.expect(!try game.world.?.isBlockSolid(target));
        try std.testing.expectEqual(voxel_chunk_module.BlockType.sand, game.heldMaterial().?);
        try std.testing.expectEqual(.putting, game.blockMode());
        try fixture.acknowledgePlayer(1, .success, .sand);
        // Holding through completion and acknowledgement does not start placement.
        fixture.engine.frame_delta = 10;
        game.updateBlockTool();
        try std.testing.expectEqual(null, game.block_interaction.holding);
        try std.testing.expectEqual(0, game.world.?.pending_operations.items.len);
        game.block_interaction.release(source);
        game.block_interaction.press(source);
        game.updateBlockTool();
        fixture.engine.frame_delta = 0.75;
        game.updateBlockTool();
        try std.testing.expect(!try game.world.?.isBlockSolid(target));
        try std.testing.expectEqual(voxel_chunk_module.BlockType.sand, game.heldMaterial().?);
        fixture.engine.frame_delta = 0.25;
        game.updateBlockTool();
        try std.testing.expect(try game.world.?.isBlockSolid(target));
        try std.testing.expectEqual(null, game.heldMaterial());
        try std.testing.expectEqual(.removing, game.blockMode());
        try fixture.acknowledgePlayer(2, .success, null);
        game.updateBlockTool();
        try std.testing.expectEqual(null, game.block_interaction.holding);
    }
}

test "early release and same-frame repress restart work without editing terrain or inventory" {
    for ([_]bool{ false, true }) |placing| {
        var fixture: StreamingTest = .{};
        fixture.init();
        defer fixture.deinit();
        try fixture.preparePlayerToolTest();
        const game = &fixture.game;
        if (placing) game.block_interaction.inventory = .sand;
        handleKeyPress(game, .{ .key = .e, .mods = .{} });
        game.updateBlockTool();
        fixture.engine.frame_delta = if (placing) 0.75 else 2.5;
        game.updateBlockTool();
        handleKeyRelease(game, .{ .key = .e, .mods = .{} });
        try std.testing.expectEqual(null, game.block_interaction.holding);
        handleKeyPress(game, .{ .key = .e, .mods = .{} });
        game.updateBlockTool();
        try std.testing.expectEqual(@as(f64, 0), game.block_interaction.holding.?.elapsed);
        game.updateBlockTool();
        try std.testing.expectEqual(0, game.world.?.pending_operations.items.len);
        try std.testing.expectEqual(if (placing) @as(?voxel_chunk_module.BlockType, .sand) else null, game.heldMaterial());
        handleKeyRelease(game, .{ .key = .e, .mods = .{} });
        handleMouseButtonPress(game, .{ .button = .left, .mods = .{} });
        game.updateBlockTool();
        handleMouseButtonRelease(game, .{ .button = .left, .mods = .{} });
        try std.testing.expectEqual(null, game.block_interaction.holding);
    }
}

test "player inventory preserves mining conversions and blocks Tab X and material shortcuts" {
    for ([_]voxel_chunk_module.BlockType{ .stone, .grass, .packed_dirt, .sand }) |material| {
        var fixture: StreamingTest = .{};
        fixture.init();
        defer fixture.deinit();
        try fixture.preparePlayerToolTest();
        const game = &fixture.game;
        fixture.changeToolMaterial(material);
        handleKeyPress(game, .{ .key = .tab, .mods = .{} });
        handleKeyPress(game, .{ .key = .three, .mods = .{} });
        handleKeyPress(game, .{ .key = .x, .mods = .{} });
        handleKeyPress(game, .{ .key = .e, .mods = .{ .control = true } });
        game.updateBlockTool();
        try std.testing.expectEqual(.removing, game.blockMode());
        try std.testing.expectEqual(voxel_chunk_module.BlockType.sand, game.selected_material);
        try std.testing.expectEqual(null, game.block_interaction.holding);
        handleKeyPress(game, .{ .key = .e, .mods = .{} });
        game.updateBlockTool();
        fixture.engine.frame_delta = 3;
        game.updateBlockTool();
        try std.testing.expectEqual(material.minedType(), game.heldMaterial().?);
        handleKeyPress(game, .{ .key = .tab, .mods = .{} });
        handleKeyPress(game, .{ .key = .eight, .mods = .{} });
        try std.testing.expectEqual(.putting, game.blockMode());
        try std.testing.expectEqual(material.minedType(), game.heldMaterial().?);
    }
}

test "changing target range terrain or focus cancels player work without automatic restart" {
    for (0..6) |cause| {
        var fixture: StreamingTest = .{};
        fixture.init();
        defer fixture.deinit();
        try fixture.preparePlayerToolTest();
        const game = &fixture.game;
        handleKeyPress(game, .{ .key = .e, .mods = .{} });
        game.updateBlockTool();
        fixture.engine.frame_delta = 2;
        game.updateBlockTool();
        switch (cause) {
            0 => fixture.camera.updateView(zmath.rotationY(math.pi / 2.0)),
            1 => {
                try game.world.?.insertChunk(test_layout.origin_chunk - ChunkCoords{ 0, 1, 0 }, WorldChunk.initEmpty());
                fixture.camera.updatePosition(.{ 0.5, -5, 0.5 });
            },
            2 => fixture.changeToolMaterial(.snow),
            3 => fixture.input.focused = false,
            4 => fixture.input.focus_changed = true,
            5 => game.world.?.removeChunk(test_layout.origin_chunk),
            else => unreachable,
        }
        game.updateBlockTool();
        try std.testing.expectEqual(null, game.block_interaction.holding);
        try std.testing.expectEqual(null, game.block_interaction.inventory);
        try std.testing.expectEqual(0, game.world.?.pending_operations.items.len);
        fixture.input.focused = true;
        fixture.input.focus_changed = false;
        game.updateBlockTool();
        try std.testing.expectEqual(null, game.block_interaction.holding);
    }
}

test "inventory waits for acknowledgement and rejection restores extraction and placement" {
    for ([_]bool{ false, true }) |placing| {
        var fixture: StreamingTest = .{};
        fixture.init();
        defer fixture.deinit();
        try fixture.preparePlayerToolTest();
        const game = &fixture.game;
        if (placing) game.block_interaction.inventory = .sand;
        game.block_interaction.press(.key);
        game.updateBlockTool();
        fixture.engine.frame_delta = if (placing) 1 else 3;
        game.updateBlockTool();
        try std.testing.expect(game.block_interaction.pending != null);
        const before = if (placing) @as(?voxel_chunk_module.BlockType, .sand) else null;
        try std.testing.expectEqual(if (placing) null else @as(?voxel_chunk_module.BlockType, .sand), game.heldMaterial());
        game.block_interaction.release(.key);
        game.block_interaction.press(.mouse);
        fixture.engine.frame_delta = 100;
        game.updateBlockTool();
        try std.testing.expectEqual(1, game.world.?.pending_operations.items.len);
        try std.testing.expectEqual(null, game.block_interaction.holding);
        // The result is processed even without a matching terrain subscription.
        try fixture.acknowledgePlayer(42, if (placing) .already_exists else .already_removed, before);
        try std.testing.expectEqual(before, game.heldMaterial());
        try std.testing.expectEqual(null, game.block_interaction.pending);
        try std.testing.expectEqual(0, game.world.?.pending_operations.items.len);
        game.updateBlockTool();
        try std.testing.expectEqual(null, game.block_interaction.holding);
        game.block_interaction.release(.mouse);
        game.block_interaction.press(.mouse);
        game.updateBlockTool();
        try std.testing.expect(game.block_interaction.holding != null);
    }
}

test "real service reconciles NPC-winning extraction and placement conflicts" {
    for ([_]bool{ false, true }) |placing| {
        const service = try WorldDataService.create(std.testing.io, std.testing.allocator, &test_layout, .flat);
        defer service.destroy();
        var fixture: StreamingTest = .{};
        fixture.init();
        defer fixture.deinit();
        const game = &fixture.game;
        game.world_client = try service.createClient();
        const npc = try service.createClient();
        const original = StreamingTest.toolTarget();
        // Use the flat world's natural surface so both authority and prediction
        // see the complete nine-cell footprint for each sand transfer.
        const target: [3]u32 = .{ original[0] + 8, original[1], original[2] - consts.CHUNK_SIZE / 2 };
        const backing = [3]u32{ target[0], target[1] + 1, target[2] };
        _ = try StreamingTest.serviceOperation(npc, .{ .block = target, .action = .{ .put = .sand } });
        _ = try StreamingTest.serviceOperation(npc, .{ .block = backing, .action = .{ .put = .sand } });
        game.world_client.?.publishCheckpoint(.{ .id = game.player_id, .feet = .{ 0, 0, 0 }, .yaw = 0, .pitch = 0 });
        const coords, _ = world_module.splitBlockCoords(target);
        const token = game.world_client.?.requestChunks(.{ coords[0], coords[1] }, coords[2], coords[2] + 1);
        try fixture.subscribe(coords, token, .blocks);
        try fixture.waitAndApplyPackages();
        fixture.camera.updatePosition(.{ 8.5, 0.5, 0.5 - consts.CHUNK_SIZE / 2 });
        if (placing) {
            game.block_interaction.press(.key);
            game.updateBlockTool();
            fixture.engine.frame_delta = 3;
            game.updateBlockTool();
            game.flushBlockOperations();
            while (game.block_interaction.pending != null) try fixture.waitAndApplyPackages();
            game.block_interaction.release(.key);
            try std.testing.expectEqual(voxel_chunk_module.BlockType.sand, game.heldMaterial().?);
        }
        // Delay receiving the NPC's update until after the optimistic player commit.
        _ = try StreamingTest.serviceOperation(npc, .{ .block = target, .action = if (placing) .{ .put = .snow } else .remove });
        game.block_interaction.press(.mouse);
        game.updateBlockTool();
        fixture.engine.frame_delta = if (placing) 1 else 3;
        game.updateBlockTool();
        try std.testing.expectEqual(if (placing) null else @as(?voxel_chunk_module.BlockType, .sand), game.heldMaterial());
        game.flushBlockOperations();
        while (game.block_interaction.pending != null) try fixture.waitAndApplyPackages();
        try std.testing.expectEqual(if (placing) @as(?voxel_chunk_module.BlockType, .sand) else null, game.heldMaterial());
        const chunk = game.world.?.getChunk(coords).?;
        const local = world_module.splitBlockCoords(target)[1];
        try std.testing.expectEqual(if (placing) voxel_chunk_module.BlockType.snow else .none, chunk.content.getBlock(local));
        try std.testing.expectEqual(0, game.world.?.pending_operations.items.len);
    }
}

test "invalid local placement retains the carried block without submitting a transfer" {
    var fixture: StreamingTest = .{};
    fixture.init();
    defer fixture.deinit();
    try fixture.preparePlayerToolTest();
    const game = &fixture.game;
    const target = StreamingTest.toolTarget();
    game.world.?.setBlockUnchecked(.{ target[0] - 1, target[1] - 1, target[2] - 1 }, .none);
    game.world.?.pending_operations.clearRetainingCapacity();
    game.block_interaction.inventory = .dirt;
    game.block_interaction.press(.mouse);
    game.updateBlockTool();
    fixture.engine.frame_delta = 1;
    game.updateBlockTool();
    try std.testing.expectEqual(voxel_chunk_module.BlockType.dirt, game.heldMaterial().?);
    try std.testing.expectEqual(null, game.block_interaction.pending);
    try std.testing.expectEqual(null, game.block_interaction.holding);
    try std.testing.expectEqual(0, game.world.?.pending_operations.items.len);
    try std.testing.expect(game.block_action_error.message(0) != null);
}

test "player work survives unrelated cell edits and cancels a same-material replacement" {
    for ([_]bool{ false, true }) |replace_target| {
        var fixture: StreamingTest = .{};
        fixture.init();
        defer fixture.deinit();
        try fixture.preparePlayerToolTest();
        const game = &fixture.game;
        const target = StreamingTest.toolTarget();
        game.block_interaction.press(.key);
        game.updateBlockTool();
        fixture.engine.frame_delta = 1;
        game.updateBlockTool();
        const coords, const local = world_module.splitBlockCoords(target);
        var snapshot = try game.world.?.getChunk(coords).?.tryClone(std.testing.allocator);
        if (replace_target) {
            try std.testing.expectEqual(world_module.OperationStatus.success, snapshot.apply(std.testing.allocator, local, .remove));
            try std.testing.expectEqual(world_module.OperationStatus.success, snapshot.apply(std.testing.allocator, local, .{ .put = .sand }));
        } else {
            try std.testing.expectEqual(world_module.OperationStatus.success, snapshot.apply(std.testing.allocator, .{ 10, 10, 10 }, .{ .put = .snow }));
        }
        snapshot.chunk_revision += 1;
        try game.world.?.insertChunk(coords, snapshot);
        fixture.engine.frame_delta = 2;
        game.updateBlockTool();
        try std.testing.expectEqual(null, game.block_interaction.holding);
        try std.testing.expectEqual(if (replace_target) null else @as(?voxel_chunk_module.BlockType, .sand), game.heldMaterial());
        try std.testing.expectEqual(@as(usize, if (replace_target) 0 else 1), game.world.?.pending_operations.items.len);
    }
}

test "return from spectator waits for a legal player pose above the finite floor" {
    const layout = try WorldLayout.init(.{ .size_in_chunks = .{ 4, 4, 4 } });
    var fixture: StreamingTest = undefined;
    fixture.initWithLayout(&layout);
    defer fixture.deinit();
    var spectator: std.meta.Child(@TypeOf(@as(Scene, undefined).spectator_camera)) = .{
        .camera = &fixture.camera,
        .input_controller = @ptrCast(&fixture.input),
    };
    fixture.scene.spectator_camera = &spectator;
    fixture.scene.spectator_enabled = true;
    fixture.game.player = PlayerController.init(std.testing.allocator, .{ 0.5, 0.5, -65 });
    fixture.game.control_mode = .spectator;
    fixture.game.toggleControlMode();
    try std.testing.expectEqual(.spectator, fixture.game.control_mode);
    try fixture.game.world.?.insertChunk(.{ 2, 2, 0 }, WorldChunk.initEmpty());
    fixture.game.toggleControlMode();
    try std.testing.expectEqual(.player, fixture.game.control_mode);
    try std.testing.expect(fixture.game.player.?.position[2] >= -64);
    var query: terrain_collision.Query = .{ .world = &fixture.game.world.?, .body = fixture.game.player.?.body };
    try std.testing.expectEqual(terrain_collision.Overlap.clear, query.overlap(fixture.game.player.?.position, false));
}
