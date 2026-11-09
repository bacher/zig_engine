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
const chunk_visual_queue = @import("chunk_visual_queue.zig");
const transformations = @import("block_transformations.zig");
const block_targeting = @import("block_targeting.zig");
const block_coordinates = @import("block_coordinates.zig");
const blueprint = @import("blueprint.zig");
const blueprint_capture = @import("blueprint_capture.zig");
const BlueprintTool = @import("blueprint_tool.zig").BlueprintTool;
const blueprint_renderer = @import("engine").blueprint_renderer;
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
    const map_teleport_timeout_seconds: f64 = 30;
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
    map_teleport: ?struct { xy: [2]f64, deadline: f64, request_id: ?u64 = null } = null,
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
    blueprint_tool: BlueprintTool = .{},
    blueprint_renderer: ?blueprint_renderer.Renderer = null,
    blueprint_render_instances: std.ArrayList(blueprint_renderer.Instance) = .empty,
    blueprint_render_preview: ?blueprint_renderer.Preview = null,
    blueprint_selection_frame_start: ?u32 = null,
    blueprint_visible_chunks: std.ArrayList(u32) = .empty,
    blueprint_visible_miniatures: u32 = 0,
    miniature_cells: std.ArrayList(blueprint_renderer.MiniatureCell) = .empty,
    /// Latest source revision for each loaded chunk requiring a cache update.
    miniature_dirty_chunks: std.AutoHashMapUnmanaged(u32, u64) = .empty,
    miniature_revision: u64 = 0,
    package_pending_cells: std.ArrayList(struct { block: [3]u32, material: ?voxel_chunk_module.BlockType }) = .empty,
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
    /// Loaded chunks awaiting local terrain preparation.
    dirty_chunk_ids: std.AutoHashMapUnmanaged(u32, void) = .empty,
    /// One FIFO visit covers this chunk's independent terrain/miniature flags.
    chunk_visuals: chunk_visual_queue.Queue = .{},
    visual_budget: chunk_visual_queue.FrameBudget = .{},
    visual_frame: u64 = 0,
    last_camera_chunk_coords: ?ChunkCoords = null,
    saved_game_objects: std.StringHashMapUnmanaged(*GameObject) = .empty,
    saved_game_object_groups: std.StringHashMapUnmanaged(*GameObjectGroup) = .empty,

    fn clearToolInputs(game: *Game) void {
        game.block_interaction.loseFocus();
        game.blueprint_tool.press.loseFocus();
        game.tool_commands.clearRetainingCapacity();
        game.jump_requested = false;
        game.engine.input_controller.cursor_position_delta = .{ 0, 0 };
        if (game.player) |*player| player.resetJumpInput();
        game.clearBlockFocus();
    }

    fn updateBlueprintInputBlock(game: *Game) void {
        game.clearToolInputs();
        game.engine.setGameplayInputBlocked(game.overlay != .none or game.blueprint_tool.controlsBlocked());
    }

    fn discardBlueprintDraft(game: *Game) void {
        game.blueprint_tool.resetDraft(game.allocator);
        game.updateBlueprintInputBlock();
    }

    fn leaveBlueprintTool(game: *Game) void {
        game.blueprint_tool.leave(game.allocator);
        game.blueprint_render_preview = null;
        game.updateBlueprintInputBlock();
    }

    fn enterBlueprintCapture(game: *Game) void {
        if (game.control_mode != .player) {
            game.block_action_error.show("Blueprint tools require player control.", game.engine.time);
            return;
        }
        if (game.block_interaction.inventory != null) {
            game.block_action_error.show("Cannot enter blueprint capture while holding a block.", game.engine.time);
            return;
        }
        game.blueprint_tool.enterCapture(game.allocator);
        game.updateBlueprintInputBlock();
    }

    fn openBlueprintChooser(game: *Game) void {
        if (game.overlay != .none or !game.blueprint_tool.canOpenChooser()) return;
        if (game.control_mode != .player) {
            game.block_action_error.show("Blueprint tools require player control.", game.engine.time);
            return;
        }
        const world = if (game.world) |*world| world else return;
        var definitions = world.blueprints.definitions.valueIterator();
        while (definitions.next()) |saved| {
            if (saved.owner != game.player_id) continue;
            game.blueprint_tool.openChooser();
            game.updateBlueprintInputBlock();
            return;
        }
        game.block_action_error.show("You do not have any blueprints yet.", game.engine.time);
    }

    fn cancelBlueprintChooser(game: *Game) void {
        game.blueprint_tool.cancelChooser();
        game.updateBlueprintInputBlock();
    }

    fn selectBlueprint(game: *Game, definition_id: u64) void {
        if (!game.blueprint_tool.chooser_open) return;
        const world = if (game.world) |*world| world else return;
        const saved = world.blueprints.definitions.get(definition_id) orelse return;
        if (saved.owner != game.player_id) return;
        game.blueprint_tool.select(game.allocator, definition_id);
        game.updateBlueprintInputBlock();
    }

    fn blueprintAnchorTarget(game: *Game) ?[3]u32 {
        const scene = game.engine.active_scene orelse return null;
        const world = if (game.world) |*world| world else return null;
        const camera = scene.camera;
        return block_targeting.findTargetWithReach(world, camera.position, camera.forwardDirection(), .putting, @sqrt(blueprint_capture.range_squared)) catch null;
    }

    fn updateBlueprintRay(game: *Game) void {
        const scene = game.engine.active_scene orelse return;
        const player = game.player orelse return;
        const selection = &game.blueprint_tool.selection;
        const camera = scene.camera;
        const direction = camera.forwardDirection();
        const heading: Position = .{ -@sin(player.yaw), @cos(player.yaw), 0 };
        if (selection.usesPlacementTarget(game.layout(), camera.position)) {
            var target: ?blueprint_capture.PlacementTarget = null;
            if (game.world) |*world| {
                const length = @sqrt(@reduce(.Add, direction * direction));
                if (std.math.isFinite(length) and length > 0) {
                    const eye_offset = camera.position - player.position;
                    // Traverse far enough for every hit within 30 m of the feet;
                    // selection validates the raw hit before projecting to anchor Z.
                    const query_reach = @sqrt(blueprint_capture.range_squared) + @sqrt(@reduce(.Add, eye_offset * eye_offset));
                    if (block_targeting.castWithReach(world, camera.position, direction, query_reach) catch null) |hit| if (hit.placement) |cell| {
                        target = .{ .cell = cell, .hit = camera.position + direction * @as(Position, @splat(hit.distance / length)) };
                    };
                }
            }
            selection.updatePlacementTarget(game.layout(), player.position, camera.position, heading, target);
        } else {
            selection.updateRay(game.layout(), player.position, camera.position, direction, heading);
        }
    }

    fn prepareBlueprintSource(game: *Game) void {
        game.blueprint_tool.prepareSource(game.allocator, game.layout());
    }

    fn updateBlueprintTool(game: *Game) void {
        game.blueprint_tool.pollCapture(game.allocator);
        if (game.world_client) |client| {
            // Success can reach its mailbox before the matching ordered package.
            // Keep that result until the package has passed local atomic preflight.
            if (game.blueprint_tool.results.items.len == 0) client.takeBlueprintResults(&game.blueprint_tool.results);
            game.resolveBlueprintResults();
        }
        if (game.blueprint_tool.mode == .capture) {
            game.updateBlueprintRay();
            if (game.blueprint_tool.selection.stage == .loading) {
                const world = if (game.world) |*world| world else return;
                for (game.blueprint_tool.source_chunks.items) |id| if (!world.hasChunk(game.layout().decodeChunkId(id))) return;
                if (game.blueprint_tool.helper == null) game.blueprint_tool.helper = blueprint_capture.Helper.create(game.allocator, game.engine.io) catch {
                    game.blueprint_tool.error_message = "Could not start the blueprint validation helper.";
                    game.blueprint_tool.selection.stage = .invalid;
                    game.blueprint_tool.source_chunks.clearRetainingCapacity();
                    return;
                };
                const helper = game.blueprint_tool.helper.?;
                // A cancelled job retains its one slot until its immutable input is released.
                if (!helper.isIdle()) return;
                const box = game.blueprint_tool.selection.bounds.?;
                const size = box.size();
                const count = box.volume() catch unreachable;
                const cells = game.allocator.alloc(voxel_chunk_module.BlockType, count) catch {
                    game.blueprint_tool.error_message = "Not enough memory for the blueprint snapshot.";
                    game.blueprint_tool.selection.stage = .invalid;
                    game.blueprint_tool.source_chunks.clearRetainingCapacity();
                    return;
                };
                const started = std.Io.Clock.awake.now(game.engine.io);
                // This is the sole snapshot pass. No replies or edits are processed midway.
                for (cells, 0..) |*material, index| {
                    const local = blueprint.cellAtIndex(size, index);
                    const source = box.min + blueprint_capture.Cell{ local[0], local[1], local[2] };
                    const block = block_coordinates.fromStorage(game.layout(), source) orelse unreachable;
                    material.* = world.plannedBlock(block) orelse {
                        game.allocator.free(cells);
                        game.blueprint_tool.error_message = "Blueprint source data is unknown.";
                        game.blueprint_tool.selection.stage = .invalid;
                        game.blueprint_tool.source_chunks.clearRetainingCapacity();
                        return;
                    };
                }
                game.blueprint_tool.copy_ns = @intCast(started.durationTo(std.Io.Clock.awake.now(game.engine.io)).nanoseconds);
                game.blueprint_tool.snapshot_bytes = count * @sizeOf(voxel_chunk_module.BlockType);
                game.blueprint_tool.source_peak = @max(game.blueprint_tool.source_peak, game.blueprint_tool.source_chunks.items.len);
                game.blueprint_tool.source_chunks.clearRetainingCapacity();
                helper.submit(.{ .generation = game.blueprint_tool.selection.generation, .size = size, .cells = cells, .horizontal_limit = blueprint_capture.horizontalLimit(game.layout()), .max_cells = game.blueprint_tool.budgets.max_cells }) catch {
                    game.allocator.free(cells);
                    return;
                };
                game.blueprint_tool.selection.stage = .validating;
            }
        }
        if (game.blueprint_tool.mode == .preview and game.blueprint_tool.preview != null and game.blueprint_tool.canRetarget()) {
            const world = if (game.world) |*world| world else return;
            const camera = game.engine.active_scene.?.camera;
            game.blueprint_tool.updatePreviewOrigin(block_targeting.findTarget(world, camera.position, camera.forwardDirection(), .putting) catch null);
        }
        const input = game.engine.input_controller;
        if (!input.focused or input.focus_changed) {
            game.blueprint_tool.press.loseFocus();
            return;
        }
        if (game.blueprint_tool.press.requested != null) {
            game.blueprint_tool.press.requested = null;
            game.confirmBlueprintTool();
        }
    }

    fn blueprintResultReady(game: *const Game, result: world_data_service.BlueprintResult) bool {
        const published: BlueprintTool.Publication = if (game.world) |world| .{
            .definition_present = if (result.definition_id) |id| world.blueprints.definitions.contains(id) else false,
            .max_instance_id = world.blueprints.max_instance_id,
        } else .{};
        return game.blueprint_tool.resultReady(result, published);
    }

    fn resolveBlueprintResults(game: *Game) void {
        var retained: usize = 0;
        for (game.blueprint_tool.results.items) |result| {
            if (game.blueprintResultReady(result)) {
                game.acceptBlueprintResult(result);
            } else {
                game.blueprint_tool.results.items[retained] = result;
                retained += 1;
            }
        }
        game.blueprint_tool.results.items.len = retained;
    }

    fn acceptBlueprintResult(game: *Game, result: world_data_service.BlueprintResult) void {
        if (game.blueprint_tool.acceptResult(game.allocator, result, .{ .now = game.engine.real_time, .persistent = game.persistence_store != null, .status_duration = block_messages.action_error_duration })) {
            if (game.blueprint_tool.mode == .none) game.blueprint_render_preview = null;
            game.updateBlueprintInputBlock();
        }
    }

    fn confirmBlueprintTool(game: *Game) void {
        if (game.blueprint_tool.chooser_open) return;
        if (game.blueprint_tool.mode == .capture) {
            const selection = &game.blueprint_tool.selection;
            if (selection.stage == .anchor) {
                const target = game.blueprintAnchorTarget() orelse return;
                const camera = game.engine.active_scene.?.camera;
                selection.setAnchor(game.layout(), target, camera.position);
                game.updateBlueprintRay();
            } else {
                game.updateBlueprintRay();
                if (selection.confirmExtent() and selection.stage == .loading) game.prepareBlueprintSource();
            }
        } else if (game.blueprint_tool.mode == .preview and game.blueprint_tool.apply == null) {
            const preview = game.blueprint_tool.preview orelse return;
            const origin = preview.origin orelse return;
            const client = game.world_client orelse return;
            const saved = game.world.?.blueprints.definitions.get(preview.definition_id) orelse return;
            const size = blueprint.rotatedSize(saved.definition.size, preview.rotation);
            if (size[0] > blueprint_capture.horizontalLimit(game.layout()) or size[1] > blueprint_capture.horizontalLimit(game.layout())) {
                game.blueprint_tool.error_message = "Rotated blueprint exceeds the horizontal size limit.";
                return;
            }
            const request_id = client.tryApplyBlueprint(game.player_id, preview.definition_id, origin, preview.rotation) catch {
                game.blueprint_tool.error_message = "Could not submit blueprint application. Try again.";
                return;
            };
            game.blueprint_tool.didSubmitApply(request_id, preview.generation, game.engine.real_time);
        }
    }

    fn submitBlueprintName(game: *Game) void {
        const name = game.blueprint_tool.nameForSave() orelse return;
        const candidate = if (game.blueprint_tool.candidate) |*candidate| candidate else return;
        const client = game.world_client orelse return;
        const request_id = client.trySaveBlueprint(game.player_id, name, candidate) catch {
            game.blueprint_tool.error_message = "Could not submit blueprint save. The checked draft is retained; try again.";
            return;
        };
        game.blueprint_tool.didSubmitSave(request_id, game.engine.real_time);
        game.updateBlueprintInputBlock();
    }

    fn blueprintChoiceButton(id: u64, name: []const u8) bool {
        var id_buffer: [40]u8 = undefined;
        const label = std.fmt.bufPrintZ(&id_buffer, "##blueprint-{d}", .{id}) catch unreachable;
        const style = zgui.getStyle();
        const size = zgui.calcTextSize(name, .{ .hide_text_after_double_hash = false });
        const pressed = zgui.button(label, .{
            .w = size[0] + 2 * style.frame_padding[0],
            .h = size[1] + 2 * style.frame_padding[1],
        });
        // User names are literal text; ImGui label syntax belongs only to the ID.
        const min = zgui.getItemRectMin();
        var color = style.getColor(.text);
        color[3] *= style.alpha;
        zgui.getWindowDrawList().addTextUnformatted(
            .{ min[0] + style.frame_padding[0], min[1] + style.frame_padding[1] },
            zgui.colorConvertFloat4ToU32(color),
            name,
        );
        return pressed;
    }

    fn drawBlueprintUI(game: *Game) void {
        const screen = zgui.io.getDisplaySize();
        const status = game.blueprint_tool.statusMessage(game.engine.real_time);
        if (game.blueprint_tool.mode == .capture or game.blueprint_tool.mode == .preview or status != null) {
            zgui.setNextWindowPos(.{ .x = screen[0] - 16, .y = 16, .pivot_x = 1 });
            _ = zgui.begin("Blueprint status", .{ .flags = .{ .always_auto_resize = true, .no_title_bar = true, .no_collapse = true, .no_saved_settings = true, .no_focus_on_appearing = true, .no_mouse_inputs = true, .no_nav_inputs = true, .no_nav_focus = true } });
            if (game.blueprint_tool.mode == .capture) {
                zgui.textUnformatted("Blueprint capture");
                zgui.textUnformatted(switch (game.blueprint_tool.selection.stage) {
                    .anchor => "Mouse1 / E: select anchor (30 m)",
                    .xy => if (game.engine.active_scene != null and game.blueprint_tool.selection.usesPlacementTarget(game.layout(), game.engine.active_scene.?.camera.position)) "Mouse1 / E: confirm XY (aim next to a block, 30 m)" else "Mouse1 / E: confirm XY extent",
                    .height => "Mouse1 / E: confirm height",
                    .loading => "Loading selected blocks...",
                    .validating => if (game.blueprint_tool.save != null) "Saving..." else "Validating frozen snapshot...",
                    .ready => "Press Enter to create a blueprint.",
                    .naming => "Enter a blueprint name.",
                    .invalid => "Blueprint rejected. Escape: start again",
                });
                if (game.blueprint_tool.selection.target_error) |reason| if (game.blueprint_tool.selection.stage == .xy or game.blueprint_tool.selection.stage == .height) zgui.textUnformatted(blueprint_capture.targetMessage(reason));
                if (game.blueprint_tool.diagnostics) |diagnostics| {
                    const mineral_height_failure = if (diagnostics.failure) |failure| failure.reason == .mineral_height else false;
                    if (mineral_height_failure and diagnostics.actual > 0 and diagnostics.limit > 0) zgui.text("Blueprint mineral height {d} exceeds the limit of {d}.", .{ diagnostics.actual, diagnostics.limit }) else zgui.text("Blueprint rejected: {s}.", .{@tagName(diagnostics.code)});
                    if (diagnostics.failure) |failure| {
                        var buffer: [block_diagnostics.message_capacity]u8 = undefined;
                        if (block_diagnostics.errorMessageForResult(.{ .status = .constraint_violation, .failure = failure }, &buffer)) |message| zgui.textUnformatted(message);
                    }
                }
            } else if (game.blueprint_tool.mode == .preview) {
                zgui.textUnformatted("Blueprint placement");
                zgui.textUnformatted(if (game.blueprint_tool.apply != null) "Checking destination..." else "R: rotate   Mouse1 / E: apply   B / Escape: cancel");
                if (game.blueprint_tool.preview) |preview| if (preview.rejection) |rejection| if (rejection.failure) |failure| {
                    var buffer: [block_diagnostics.message_capacity]u8 = undefined;
                    if (block_diagnostics.errorMessageForResult(.{ .status = .constraint_violation, .failure = failure }, &buffer)) |message| zgui.textUnformatted(message);
                };
            }
            if (game.blueprint_tool.error_message) |message| zgui.textUnformatted(message);
            if (status) |message| zgui.textUnformatted(message);
            zgui.end();
        }
        if (game.blueprint_tool.chooser_open) {
            zgui.setNextWindowPos(.{ .x = screen[0] / 2, .y = screen[1] / 2, .pivot_x = 0.5, .pivot_y = 0.5 });
            _ = zgui.begin("Choose a blueprint", .{ .flags = .{ .always_auto_resize = true, .no_collapse = true, .no_saved_settings = true } });
            // Auto-sized windows ignore WindowMinSize; reserve the content width instead.
            const style = zgui.getStyle();
            zgui.dummy(.{ .w = @max(0, 300 * style.font_scale_dpi - 2 * style.window_padding[0]), .h = 0 });
            if (game.world) |*world| {
                var definitions = world.blueprints.definitions.valueIterator();
                while (definitions.next()) |saved| {
                    if (saved.owner != game.player_id) continue;
                    if (blueprintChoiceButton(saved.id, saved.name)) game.selectBlueprint(saved.id);
                }
            }
            if (zgui.button("Cancel", .{})) game.cancelBlueprintChooser();
            zgui.end();
        } else if (game.blueprint_tool.mode == .capture and game.blueprint_tool.selection.stage == .naming) {
            zgui.setNextWindowPos(.{ .x = screen[0] / 2, .y = screen[1] / 2, .pivot_x = 0.5, .pivot_y = 0.5 });
            _ = zgui.begin("Name blueprint", .{ .flags = .{ .always_auto_resize = true, .no_collapse = true, .no_saved_settings = true } });
            const opening = game.blueprint_tool.name_focus;
            // Wait for the opening key's release so ImGui cannot also submit or
            // deactivate the new field with that same press (including repeats).
            if (opening and !zgui.isKeyDown(.enter) and !zgui.isKeyDown(.keypad_enter)) {
                zgui.setKeyboardFocusHere(0);
                game.blueprint_tool.name_focus = false;
            }
            const enter = zgui.inputText("Name", .{ .buf = &game.blueprint_tool.name, .flags = .{ .enter_returns_true = true } });
            if (zgui.button("Save", .{}) or (enter and !opening)) game.submitBlueprintName();
            zgui.sameLine(.{});
            if (zgui.button("Cancel capture", .{})) game.discardBlueprintDraft();
            zgui.end();
        }
    }

    fn buildBlueprintRenderInstances(game: *Game) void {
        game.blueprint_selection_frame_start = null;
        game.blueprint_render_preview = null;
        const list = &game.blueprint_render_instances;
        list.clearRetainingCapacity();
        const scene = game.engine.active_scene orelse return;
        const world = if (game.world) |*world| world else return;
        var visible_frames: std.AutoHashMapUnmanaged(u64, void) = .empty;
        defer visible_frames.deinit(game.allocator);
        game.blueprint_visible_chunks.clearRetainingCapacity();
        game.blueprint_visible_miniatures = 0;
        if (game.blueprint_renderer) |*renderer| {
            var visible = game.loaded_chunk_ids.keyIterator();
            while (visible.next()) |id| {
                if (getChunkDistance(game.layout(), id.*, scene.camera.chunk) > game.render_radius) continue;
                const count = renderer.miniatureChunkCount(id.*);
                if (count == 0) continue;
                game.blueprint_visible_chunks.append(game.allocator, id.*) catch return game.blueprintRenderLimit();
                game.blueprint_visible_miniatures += count;
            }
        }
        const dynamic_capacity = @as(usize, blueprint_renderer.capacity) -| game.blueprint_visible_miniatures;
        var chunks = game.loaded_chunk_ids.keyIterator();
        while (chunks.next()) |id| {
            if (getChunkDistance(game.layout(), id.*, scene.camera.chunk) > game.render_radius) continue;
            for (world.blueprints.chunkInstances(id.*)) |instance_id| {
                const instance = world.blueprints.instances.get(instance_id) orelse continue;
                if (!instance.active or visible_frames.contains(instance_id)) continue;
                visible_frames.put(game.allocator, instance_id, {}) catch return game.blueprintRenderLimit();
                const saved = world.blueprints.definitions.get(instance.definition_id) orelse continue;
                if (list.items.len + 12 > dynamic_capacity) return game.blueprintRenderLimit();
                blueprint_renderer.appendFrame(list, game.allocator, scene.camera, .{ instance.origin[0], instance.origin[1], instance.origin[2] }, blueprint.rotatedSize(saved.definition.size, instance.rotation)) catch return game.blueprintRenderLimit();
            }
        }
        if (game.blueprint_tool.mode == .capture) {
            if (game.blueprint_tool.selection.stage == .anchor) {
                if (game.blueprintAnchorTarget()) |target| {
                    if (list.items.len + 12 > dynamic_capacity) return game.blueprintRenderLimit();
                    blueprint_renderer.appendFrame(list, game.allocator, scene.camera, .{ target[0], target[1], target[2] }, .{ 1, 1, 1 }) catch return game.blueprintRenderLimit();
                    game.blueprint_selection_frame_start = @intCast(list.items.len - blueprint_renderer.frame_instance_count);
                }
            } else if (game.blueprint_tool.selection.bounds) |box| {
                if (list.items.len + 12 > dynamic_capacity) return game.blueprintRenderLimit();
                blueprint_renderer.appendFrame(list, game.allocator, scene.camera, box.min, box.size()) catch return game.blueprintRenderLimit();
                game.blueprint_selection_frame_start = @intCast(list.items.len - blueprint_renderer.frame_instance_count);
                if (game.blueprint_tool.diagnostics) |diagnostics| for (diagnostics.highlightedCells()) |local| {
                    if (list.items.len >= dynamic_capacity) return game.blueprintRenderLimit();
                    const cell = box.min + blueprint_capture.Cell{ local[0], local[1], local[2] };
                    list.append(game.allocator, blueprint_renderer.blockInstance(scene.camera, cell, .dirt, false, true)) catch return game.blueprintRenderLimit();
                };
            }
        }
        if (game.blueprint_tool.mode == .preview) if (game.blueprint_tool.preview) |preview| {
            const saved = world.blueprints.definitions.get(preview.definition_id) orelse return;
            if (preview.origin) |origin| {
                // The cached draw shares the existing total visible-instance budget.
                if (list.items.len + blueprint_renderer.frame_instance_count + saved.definition.target_count > dynamic_capacity) return game.blueprintRenderLimit();
                blueprint_renderer.appendFrame(list, game.allocator, scene.camera, .{ origin[0], origin[1], origin[2] }, blueprint.rotatedSize(saved.definition.size, preview.rotation)) catch return game.blueprintRenderLimit();
            }
            if (preview.rejection) |rejection| if (rejection.cell) |cell| {
                if (list.items.len + saved.definition.target_count >= dynamic_capacity) return game.blueprintRenderLimit();
                var marker = blueprint_renderer.blockInstance(scene.camera, .{ cell[0], cell[1], cell[2] }, .dirt, false, true);
                // Extend past the preview and existing block faces so their
                // later equal-depth draw cannot hide the diagnostic.
                inline for (0..3) |axis| {
                    marker.position[axis] -= 0.01;
                    marker.scale[axis] += 0.02;
                }
                list.append(game.allocator, marker) catch return game.blueprintRenderLimit();
            };
            // Borrow immutable source data only until this frame's renderer upload.
            // Missing targeting hides the draw without invalidating its GPU cache.
            game.blueprint_render_preview = .{
                .definition_id = saved.id,
                .generation = preview.generation,
                .size = saved.definition.size,
                .cells = saved.definition.cells,
                .target_count = saved.definition.target_count,
                .origin = preview.origin,
                .rotation = preview.rotation,
            };
        };
    }
    fn blueprintRenderLimit(game: *Game) void {
        game.blueprint_tool.error_message = "Visible blueprints exceed the rendering resource budget; some previews are unavailable.";
    }

    fn setOverlay(game: *Game, overlay: Overlay) void {
        if (game.exit_requested or overlay == game.overlay) return;
        if ((game.blueprint_tool.chooser_open or game.blueprint_tool.mode != .none) and overlay != .none) return;
        if (game.overlay == .world_map and game.map_teleport != null) return;
        if (game.overlay == .world_map) game.cancelMapTeleport();
        game.overlay = overlay;
        game.engine.setPaused(overlay == .menu and game.menu_pauses_game);
        game.engine.setGameplayInputBlocked(overlay != .none or game.blueprint_tool.controlsBlocked());
    }

    fn cancelMapTeleport(game: *Game) void {
        // Abandoned reads can finish after shutdown or a timeout. Request IDs
        // keep their late replies from being applied to a new teleport.
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
            game.map_teleport = .{ .xy = xy, .deadline = game.engine.real_time + map_teleport_timeout_seconds };
        }
    }

    fn updateMapTeleport(game: *Game) void {
        if (comptime !world_map.debug_teleport_enabled) return;
        const pending = game.map_teleport orelse return;
        if (game.engine.real_time >= pending.deadline) {
            game.map_teleport = null;
            game.map_teleport_error = "Teleport timed out; try again";
            return;
        }
        const client = game.world_client orelse return;
        if (pending.request_id == null) {
            // Submitted edits can still be delayed by persistence capture. Wait
            // for acknowledgments so the lookup sees their final terrain state.
            if (game.world.?.pending_operations.items.len != 0) {
                // A failed dependency can retain an edit without acknowledging
                // it. Release the map controls without dropping that edit.
                if (game.world_data) |service| if (service.persistenceStatus().phase == .failed) {
                    game.map_teleport = null;
                    game.map_teleport_error = "Teleport unavailable while terrain edits are blocked";
                };
                return;
            }
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
        game.blueprint_tool.stopCapture(game.allocator);
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
        game.blueprint_tool.deinit(game.allocator);
        game.blueprint_render_instances.deinit(game.allocator);
        game.deinitMiniatureState();
        if (game.blueprint_renderer) |renderer| renderer.deinit(game.engine.gctx);
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
        // Retire client metadata even on empty-package frames, outside fulfillment.
        game.world.?.blueprints.cleanup(game.allocator, 4);
        // Synchronize blocks first, then resolve local movement against that cache.
        // Player input remains independent of mesh work and GPU upload capacity.
        game.updateGameplay(has_new_chunks);
        game.updateBlueprintTool();
        game.flushBlockOperations();
        game.updatePersistence();
        game.updateChunksAroundCamera(has_new_chunks);
        if (!game.engine.gameplay_input_blocked and game.blueprint_tool.mode == .none) game.updateBlockFocus();
        // Preparation is budgeted before draw collection and terrain capacity
        // checks. Terrain and miniature updates may complete independently.
        game.rebuildDirtyChunks();
        game.buildBlueprintRenderInstances();
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
        game.leaveBlueprintTool();
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
        if (!game.engine.gameplay_input_blocked and game.blueprint_tool.mode == .none) game.updateBlockTool();
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
        // Preserve the entire ordered package after a failed blueprint preflight.
        if (game.chunk_packages.items.len == 0) game.world_client.?.takePackages(&game.chunk_packages);
        var consumed: usize = 0;
        while (consumed < game.chunk_packages.items.len) : (consumed += 1) {
            const package = &game.chunk_packages.items[consumed];
            if (!game.applyPackage(package)) break;
            package.responses.deinit(game.allocator);
        }
        if (consumed != 0) {
            const remaining = game.chunk_packages.items.len - consumed;
            std.mem.copyForwards(world_data_service.ResponsePackage, game.chunk_packages.items[0..remaining], game.chunk_packages.items[consumed..]);
            game.chunk_packages.items.len = remaining;
        }
        return consumed != 0;
    }

    fn observeBlueprintInstance(context: *anyopaque, ids: []const u32) void {
        const game: *Game = @ptrCast(@alignCast(context));
        for (ids) |id| game.markMiniatureChunkDirty(id);
    }

    fn observeBlueprintFulfilled(context: *anyopaque, cell: [3]u32) void {
        const game: *Game = @ptrCast(@alignCast(context));
        game.markMiniatureChunkDirty(game.layout().encodeChunkCoords(world_module.splitBlockCoords(cell)[0]));
    }

    fn applyPackage(game: *Game, package: *world_data_service.ResponsePackage) bool {
        const world = &game.world.?;
        // Reconciliation can roll back a later prediction in a chunk with no
        // response. Remember its effective cell, then compare the final replay.
        game.package_pending_cells.clearRetainingCapacity();
        game.package_pending_cells.ensureTotalCapacity(game.allocator, world.pending_operations.items.len) catch return false;
        for (world.pending_operations.items) |pending| {
            const block = pending.operation.block;
            game.package_pending_cells.appendAssumeCapacity(.{ .block = block, .material = world.reader().get(.{ block[0], block[1], block[2] }) });
        }
        world.applyBlueprintChangesObserved(package.blueprint_changes.items, .{
            .context = game,
            .instance_published = observeBlueprintInstance,
            .fulfilled = observeBlueprintFulfilled,
        }) catch return false;
        for (package.blueprint_changes.items) |*change| change.deinit(game.allocator);
        package.blueprint_changes.deinit(game.allocator);
        package.blueprint_changes = .empty;
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
                    game.clearTerrainDirty(id);
                    _ = game.block_snapshot_tokens.remove(id);
                    if (world.hasChunk(response.coords)) {
                        world.removeChunk(response.coords);
                        game.markChunkAndNeighborsDirty(response.coords);
                        game.clearTerrainDirty(id);
                    }
                    _ = game.boundary_snapshots.remove(id);
                    game.markMiniatureChunkDirty(id);
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
                game.clearTerrainDirty(id);
        }
        for (game.package_pending_cells.items) |before| {
            const block = before.block;
            if (world.reader().get(.{ block[0], block[1], block[2] }) != before.material) game.markChunksAroundBlockDirty(block);
        }
        return true;
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
        if (game.chunk_visuals.contains(id)) game.enqueueChunkVisual(id);
    }

    fn wantsBlocks(game: *const Game, coords: ChunkCoords) bool {
        const id = game.layout().encodeChunkCoords(coords);
        return game.pinned_chunks.contains(id) or if (game.last_camera_chunk_coords) |camera| getChunkDistance(game.layout(), id, camera) <= BLOCK_LOAD_RADIUS else true;
    }

    fn refreshPinnedChunks(game: *Game) void {
        game.pinned_chunks.clearRetainingCapacity();
        for (game.blueprint_tool.source_chunks.items) |id| game.pinned_chunks.put(game.allocator, id, {}) catch @panic("OOM");
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
        game.markMiniatureChunkDirty(chunk_id);
        game.markChunkDirtyIfLoaded(chunk_coords);
    }

    fn removeChunkIfNeeded(game: *Game, chunk_coords: ChunkCoords) void {
        game.removeChunkByIdIfNeeded(game.layout().encodeChunkCoords(chunk_coords));
    }

    fn removeChunkByIdIfNeeded(game: *Game, chunk_id: u32) void {
        _ = game.chunk_visuals.remove(chunk_id);
        _ = game.miniature_dirty_chunks.remove(chunk_id);
        if (game.blueprint_renderer) |*renderer| renderer.removeMiniatureChunk(game.engine.gctx, chunk_id);
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
        const compacting = interaction.requested == .secondary_mouse or (if (interaction.holding) |hold| hold.operation.action == .compact else false);
        const mode: block_targeting.Mode = if (compacting) .removing else game.blockMode();
        const target = (block_targeting.findTarget(world, camera.position, camera.forwardDirection(), mode) catch null);
        if (interaction.requested) |source| {
            interaction.requested = null;
            // Observer edits may still be reconciling when returning to the player.
            if (interaction.pending != null or world.pending_operations.items.len != 0) return;
            const block = target orelse return;
            const coords, const local = world_module.splitBlockCoords(block);
            const chunk = world.getChunk(coords) orelse return;
            if (compacting and chunk.content.getBlock(local) != .dirt) return;
            interaction.holding = .{
                .source = source,
                .operation = .{
                    .block = block,
                    .action = if (compacting) .compact else if (interaction.inventory) |material| .{ .put = material } else .remove,
                    .blueprint = if (!compacting and interaction.inventory != null) (if (world.blueprints.targetAt(block)) |planned_target| .{ .instance_id = planned_target.instance_id, .cell_index = planned_target.cell_index } else null) else null,
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
        const compacting = if (game.block_interaction.holding) |hold| hold.operation.action == .compact else false;
        const mode: block_targeting.Mode = if (compacting) .removing else game.blockMode();
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
                .result = world.previewOperation(.{ .block = block, .action = .{ .put = material }, .blueprint = if (world.blueprints.targetAt(block)) |target| .{ .instance_id = target.instance_id, .cell_index = target.cell_index } else null }),
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
        const result = world.tryOperation(.{ .block = edited_block, .blueprint = if (action == .place) (if (world.blueprints.targetAt(edited_block)) |target| .{ .instance_id = target.instance_id, .cell_index = target.cell_index } else null) else null, .action = switch (action) {
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

        game.markMiniatureChunkDirty(game.layout().encodeChunkCoords(chunk_coords));
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
        game.markMiniatureChunkDirty(game.layout().encodeChunkCoords(chunk_coords));
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
            game.enqueueChunkVisual(chunk_id);
        }
    }

    fn clearTerrainDirty(game: *Game, id: u32) void {
        _ = game.dirty_chunk_ids.remove(id);
        if (!game.miniature_dirty_chunks.contains(id)) _ = game.chunk_visuals.remove(id);
    }

    fn enqueueChunkVisual(game: *Game, id: u32) void {
        if (!game.loaded_chunk_ids.contains(id)) return;
        game.chunk_visuals.mark(game.allocator, id, game.chunk_subscriptions.get(id), game.visual_frame) catch @panic("OOM");
    }

    fn markMiniatureChunkDirty(game: *Game, id: u32) void {
        if (!game.loaded_chunk_ids.contains(id)) return;
        game.miniature_revision +%= 1;
        game.miniature_dirty_chunks.put(game.allocator, id, game.miniature_revision) catch @panic("OOM");
        game.enqueueChunkVisual(id);
    }

    /// Camera-independent source resolution only runs for changed chunks.
    fn collectMiniatureCells(game: *Game, id: u32) ![]const blueprint_renderer.MiniatureCell {
        game.miniature_cells.clearRetainingCapacity();
        const world = &game.world.?;
        const targets = world.blueprints.chunkTargets(id);
        try game.miniature_cells.ensureTotalCapacity(game.allocator, targets.len);
        for (targets) |block| {
            const target = world.blueprints.targetAt(block) orelse continue;
            if (world.isBlockSolid(block) catch false) continue;
            const local = world_module.splitBlockCoords(block)[1];
            game.miniature_cells.appendAssumeCapacity(.{ .local = .{ local[0], local[1], local[2] }, .material = @intFromEnum(target.material) });
        }
        return game.miniature_cells.items;
    }

    const VisualUpdater = struct {
        game: *Game,

        fn terrain(self: @This(), id: u32) !void {
            try self.game.rebuildTerrainChunk(id);
        }

        fn replace(self: @This(), id: u32, coords: ChunkCoords, revision: u64, cells: []const blueprint_renderer.MiniatureCell) !void {
            const renderer = if (self.game.blueprint_renderer) |*renderer| renderer else return error.MiniatureRendererUnavailable;
            try renderer.replaceMiniatureChunk(self.game.engine.gctx, id, coords, revision, cells);
        }
    };

    /// A whole chunk visit consumes one item, including failed/stale visits. The
    /// initial-count bound prevents a failed item requeued at the tail from being
    /// retried again in this update. No mandatory age delays newly dirty chunks.
    fn processChunkVisuals(game: *Game, updater: anytype, settings: chunk_visual_queue.FrameBudget, timed: bool) void {
        var remaining = game.chunk_visuals.count();
        if (remaining == 0) return;
        const started = if (timed) std.Io.Clock.awake.now(game.engine.io) else undefined;
        var budget = settings;
        budget.completed = 0;
        while (remaining != 0) {
            const elapsed: u64 = if (timed) @intCast(@max(0, started.durationTo(std.Io.Clock.awake.now(game.engine.io)).nanoseconds)) else 0;
            if (!budget.canStart(elapsed)) break;
            const item = game.chunk_visuals.take(game.visual_frame) orelse break;
            remaining -= 1;
            budget.record();
            const id = item.id;
            if (!game.loaded_chunk_ids.contains(id)) {
                _ = game.dirty_chunk_ids.remove(id);
                _ = game.miniature_dirty_chunks.remove(id);
                continue;
            }
            if (item.subscription != game.chunk_subscriptions.get(id)) {
                game.enqueueChunkVisual(id);
                continue;
            }
            if (game.dirty_chunk_ids.contains(id)) {
                var succeeded = true;
                updater.terrain(id) catch {
                    succeeded = false;
                };
                if (succeeded) _ = game.dirty_chunk_ids.remove(id);
            }
            if (game.miniature_dirty_chunks.get(id)) |revision| miniature: {
                const cells = game.collectMiniatureCells(id) catch {
                    game.blueprintRenderLimit();
                    break :miniature;
                };
                updater.replace(id, game.layout().decodeChunkId(id), revision, cells) catch {
                    game.blueprintRenderLimit();
                    break :miniature;
                };
                _ = game.miniature_dirty_chunks.remove(id);
            }
            if (game.dirty_chunk_ids.contains(id) or game.miniature_dirty_chunks.contains(id)) game.enqueueChunkVisual(id);
        }
    }

    fn collectRoadVisualChanges(game: *Game) void {
        for (game.world.?.changed_road_chunks.items) |id| game.markChunkDirtyIfLoaded(game.layout().decodeChunkId(id));
        game.world.?.changed_road_chunks.clearRetainingCapacity();
    }

    fn drainChunkVisualsForTesting(game: *Game) void {
        const DiscardMiniatures = struct {
            fn replace(_: @This(), _: u32, _: ChunkCoords, _: u64, _: []const blueprint_renderer.MiniatureCell) !void {}
        };
        game.drainChunkVisualsWithMiniaturesForTesting(DiscardMiniatures{});
    }

    fn drainChunkVisualsWithMiniaturesForTesting(game: *Game, miniatures: anytype) void {
        const Updater = struct {
            game: *Game,
            miniatures: @TypeOf(miniatures),

            fn terrain(self: @This(), id: u32) !void {
                try self.game.rebuildTerrainChunk(id);
            }
            fn replace(self: @This(), id: u32, coords: ChunkCoords, revision: u64, cells: []const blueprint_renderer.MiniatureCell) !void {
                try self.miniatures.replace(id, coords, revision, cells);
            }
        };
        game.collectRoadVisualChanges();
        game.visual_frame +%= 1;
        // A test sink may intentionally fail, so a drain is one unbounded visit
        // pass plus one identity refresh pass, never an unbounded retry loop.
        var pass: usize = 0;
        while (pass < 2 and game.chunk_visuals.count() != 0) : (pass += 1) {
            game.processChunkVisuals(Updater{ .game = game, .miniatures = miniatures }, .{ .max_items = std.math.maxInt(u32), .max_elapsed_ns = std.math.maxInt(u64) }, false);
        }
    }

    fn deinitMiniatureState(game: *Game) void {
        game.blueprint_visible_chunks.deinit(game.allocator);
        game.miniature_cells.deinit(game.allocator);
        game.miniature_dirty_chunks.deinit(game.allocator);
        game.package_pending_cells.deinit(game.allocator);
        game.chunk_visuals.deinit(game.allocator);
    }

    /// Run once after edits, responses, and camera loading, before draw collection
    /// and terrain uploads. Direct service-mesh responses remain outside this budget.
    fn rebuildDirtyChunks(game: *Game) void {
        game.collectRoadVisualChanges();
        game.visual_frame +%= 1;
        game.processChunkVisuals(VisualUpdater{ .game = game }, game.visual_budget, true);
    }

    /// Prepare fallible local work before replacing either resident or queued
    /// terrain. No mesh payload survives a failed visit or is staged across frames.
    fn rebuildTerrainChunk(game: *Game, id: u32) !void {
        const coords = game.layout().decodeChunkId(id);
        const chunk = game.world.?.getChunk(coords) orelse return;
        const grid = game.engine.active_scene.?.voxel_grid;
        var replacement: ?voxel_chunk_module.VoxelChunkUpload = null;
        defer if (replacement) |*upload| upload.chunk_side_data.deinit(game.allocator);
        if (chunk.content == .blocks and !chunk.flags.is_unreachable) {
            var climate: world_engine.ClimateMap = @splat(@splat(.temperate));
            if (game.world_data) |service| service.preparedGenerator().fillClimateMap(.{ coords[0], coords[1] }, &climate);
            replacement = .{
                .chunk_coords = coords,
                .chunk_side_data = try world_engine.tryExtractChunkGeometryWithClimate(game.allocator, chunk, game.meshNeighbors(coords), &climate),
            };
            try grid.chunks_to_upload.ensureUnusedCapacity(grid.allocator, 1);
        }
        _ = game.mesh_versions.remove(id);
        grid.removeChunk(coords);
        if (replacement) |upload| {
            grid.appendChunk(upload);
            replacement = null;
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
            .onRenderWorldOverlay3D = onRenderWorldOverlay3D,
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
    game.blueprint_renderer = blueprint_renderer.Renderer.init(engine.gctx, engine.bind_group_layouts.regular.bind_group_layout_handle, engine.gctx.swapchain_descriptor.format);
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
    game.blueprint_tool.press.loseFocus();
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
    if (game.exit_requested) return true;
    const action: BlueprintTool.Action = switch (key_params.key) {
        .escape => .escape,
        .z => .capture,
        .b => if (key_params.mods.control) .other else .chooser,
        .enter, .kp_enter => .name,
        .r => if (key_params.mods.control) .other else .rotate,
        .e => if (key_params.mods.control) .other else .interact,
        .q => .control,
        .m => .map,
        else => .other,
    };
    switch (game.blueprint_tool.handleAction(game.allocator, action, game.overlay != .none)) {
        .unhandled => {},
        .consumed => return true,
        .capture => {
            game.enterBlueprintCapture();
            return true;
        },
        .chooser => {
            game.openBlueprintChooser();
            return true;
        },
        .reset_inputs, .menu, .control => |effect| {
            if (game.blueprint_tool.mode == .none) game.blueprint_render_preview = null;
            game.updateBlueprintInputBlock();
            if (effect == .menu) game.setOverlay(.menu);
            if (effect == .control) game.toggleControlMode();
            return true;
        },
    }
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
    if (game.blueprint_tool.mode != .none and key_params.key != .space) return;
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
    if (params.key == .e) {
        game.block_interaction.release(.key);
        // Capture uses immediate presses, so a release before the next frame
        // ends the held source without cancelling its queued confirmation.
        game.blueprint_tool.press.key_down = false;
    }
}

fn onMouseButtonRelease(_: *Engine, params: MouseButtonParams, game_opaque: *anyopaque) void {
    const game: *Game = @ptrCast(@alignCast(game_opaque));
    handleMouseButtonRelease(game, params);
}

fn handleMouseButtonRelease(game: *Game, params: MouseButtonParams) void {
    if (params.button == .left) {
        game.block_interaction.release(.mouse);
        game.blueprint_tool.press.mouse_down = false;
    }
    if (params.button == .right) game.block_interaction.release(.secondary_mouse);
}

fn onMouseButtonPress(engine: *Engine, params: MouseButtonParams, game_opaque: *anyopaque) void {
    const game: *Game = @ptrCast(@alignCast(game_opaque));
    if (!engine.window_context.window.getAttribute(.focused)) return;
    handleMouseButtonPress(game, params);
}

fn handleMouseButtonPress(game: *Game, params: MouseButtonParams) void {
    if (game.exit_requested or game.engine.gameplay_input_blocked) return;
    if (game.blueprint_tool.mode != .none) {
        if (params.button == .left and (game.blueprint_tool.mode == .capture or game.blueprint_tool.mode == .preview)) game.blueprint_tool.press.press(.mouse);
        return;
    }
    if (game.control_mode == .player) {
        if (params.button == .left) game.block_interaction.press(.mouse);
        if (params.button == .right) game.block_interaction.press(.secondary_mouse);
        return;
    }
    if (params.button == .left) game.queueBlockAction(switch (game.block_mode) {
        .putting => .{ .place = game.selected_material },
        .removing => .remove,
    });
}

fn onRenderWorldOverlay3D(engine: *Engine, pass: wgpu.RenderPassEncoder, game_opaque: *anyopaque) void {
    const game: *Game = @ptrCast(@alignCast(game_opaque));
    if (game.blueprint_renderer) |*renderer| if (engine.active_scene) |scene| {
        renderer.drawWithPreview(engine.gctx, pass, engine.bind_group_minecraft_texture.wgpu_bind_group, scene.camera, game.blueprint_render_instances.items, game.blueprint_selection_frame_start, game.allocator, game.blueprint_render_preview) catch game.blueprintRenderLimit();
        const preview_count = if (game.blueprint_render_preview) |preview| (if (preview.origin != null) preview.target_count else @as(u32, 0)) else @as(u32, 0);
        renderer.drawMiniatures(engine.gctx, pass, engine.bind_group_minecraft_texture.wgpu_bind_group, scene.camera, game.blueprint_visible_chunks.items, @intCast(@as(usize, blueprint_renderer.capacity) -| game.blueprint_render_instances.items.len -| preview_count)) catch game.blueprintRenderLimit();
    };
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
    if (game.overlay == .none and !engine.gameplay_input_blocked) {
        block_messages.draw(game.current_placement_preview, &game.block_action_error, engine.time);
        drawCrosshair();
        if (game.control_mode == .player) if (game.block_interaction.holding) |hold| {
            drawBlockActionProgress(hold);
        };
    }
    if (game.overlay == .world_map) if (game.world_data) |service| if (engine.active_scene) |scene| {
        game.handleMapAction(game.map_state.draw(game.allocator, engine.gctx, service.preparedGenerator(), game.mapView(scene)));
    };
    game.drawBlueprintUI();
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
        if (zgui.button("Retry saving world", .{})) _ = game.world_data.?.requestSave(false);
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

test "debug map teleport waits for edit acknowledgment and keeps player view and inventory" {
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
    const block = [3]u32{ 234, 42, 16 };
    const coords, const local = world_module.splitBlockCoords(block);
    const token = game.world_client.?.requestChunks(.{ coords[0], coords[1] }, coords[2], coords[2] + 1);
    try fixture.subscribe(coords, token, .blocks);
    while (!fixture.settled()) try fixture.waitAndApplyPackages();
    try std.testing.expectEqual(voxel_chunk_module.BlockType.none, game.world.?.getChunk(coords).?.content.getBlock(local));
    try std.testing.expectEqual(.success, game.world.?.tryOperation(.{ .block = block, .action = .{ .put = .dirt } }).status);
    try std.testing.expectEqual(1, game.world.?.pending_operations.items.len);
    try std.testing.expectEqual(null, game.world.?.pending_operations.items[0].request_id);
    game.setOverlay(.world_map);
    game.handleMapAction(.{ .teleport_xy = .{ 106.5, -85.5 } });
    game.updateMapTeleport();
    try std.testing.expectEqual(null, game.map_teleport.?.request_id);
    game.flushBlockOperations();
    try std.testing.expect(game.world.?.pending_operations.items[0].request_id != null);
    // Even a completed worker edit must be reconciled before the lookup starts.
    for (0..5000) |_| {
        game.updateMapTeleport();
        try std.testing.expectEqual(null, game.map_teleport.?.request_id);
        try std.testing.expectEqual(Position{ 0.5, 0.5, -16 }, game.player.?.position);
        try std.testing.expectEqual(.world_map, game.overlay);
        _ = game.receiveChunks();
        if (game.world.?.pending_operations.items.len == 0) break;
        try std.Io.sleep(std.testing.io, .fromMilliseconds(1), .awake);
    }
    try std.testing.expectEqual(0, game.world.?.pending_operations.items.len);
    try std.testing.expectEqual(.success, game.world.?.last_edit_result.?.status);
    try std.testing.expectEqual(voxel_chunk_module.BlockType.dirt, game.world.?.getChunk(coords).?.content.getBlock(local));
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

test "debug map teleport releases controls when a persisted edit dependency is corrupt" {
    if (comptime !world_map.debug_teleport_enabled) return error.SkipZigTest;
    const allocator = std.testing.allocator;
    const layout = try WorldLayout.init(.{ .size_in_chunks = .{ 4, 4, 4 } });
    var uuid: [16]u8 = undefined;
    std.c.arc4random_buf(&uuid, uuid.len);
    const path = try std.fmt.allocPrintSentinel(allocator, "/private/tmp/map-teleport-dependency-{x}", .{uuid}, 0);
    defer allocator.free(path);
    defer std.Io.Dir.cwd().deleteTree(std.testing.io, path) catch {};
    const descriptor = try persistence_format.encodeDescriptor(allocator, .{
        .dimensions = .{ @intCast(layout.size_in_chunks[0]), @intCast(layout.size_in_chunks[1]), @intCast(layout.size_in_chunks[2]) },
        .generator_id = persistence_format.generator_id,
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
    {
        const service = try WorldDataService.createPersistent(std.testing.io, allocator, &layout, .flat, &store, .{});
        defer service.destroy();
        const client = try service.createClient();
        try std.testing.expectEqual(.success, (try StreamingTest.serviceOperation(client, .{
            .block = .{ 10, 10, 48 },
            .action = .{ .put = .snow },
        })).status);
        const intent = service.requestSave(true);
        var saved = false;
        for (0..5000) |_| {
            const status = service.persistenceStatus();
            if (status.intent_id == intent and !status.active and (status.phase == .complete or status.phase == .failed)) {
                try std.testing.expectEqual(.complete, status.phase);
                saved = true;
                break;
            }
            try std.Io.sleep(std.testing.io, .fromMilliseconds(1), .awake);
        }
        try std.testing.expect(saved);
    }
    {
        var catalog = try store.snapshotCatalog();
        defer catalog.deinit();
        var read = (try catalog.prepareRead(layout.encodeChunkCoords(.{ 0, 0, 1 }))).?;
        defer read.deinit();
        const record = try read.read(allocator);
        defer allocator.free(record);
        record[record.len - 1] ^= 1;
        try read.file.write(record[record.len - 1 ..], read.offset + record.len - 1);
    }
    const service = try WorldDataService.createPersistent(std.testing.io, allocator, &layout, .flat, &store, .{});
    defer service.destroy();
    var fixture: StreamingTest = .{};
    fixture.initWithLayout(&layout);
    defer fixture.deinit();
    const game = &fixture.game;
    game.world_data = service;
    game.world_client = try service.createClient();
    game.persistence_store = &store;
    game.player = PlayerController.init(allocator, .{ 0.5, 0.5, -16 });
    game.player.?.yaw = 0.7;
    game.player.?.pitch = -0.2;
    game.player.?.vertical_velocity = -30;
    game.player.?.applyCamera(&fixture.camera);
    game.block_interaction.inventory = .planks;
    const original_camera = fixture.camera.position;

    // Loading this generated chunk uses only face neighbors, excluding the
    // corrupt chunk. Its edit validation later requires the wider +/-2 envelope.
    const coords: ChunkCoords = .{ 2, 2, 1 };
    const block = [3]u32{ 74, 74, 48 };
    const token = game.world_client.?.requestChunks(.{ coords[0], coords[1] }, coords[2], coords[2] + 1);
    try fixture.subscribe(coords, token, .blocks);
    while (!fixture.settled()) try fixture.waitAndApplyPackages();
    try std.testing.expectEqual(.success, game.world.?.tryOperation(.{ .block = block, .action = .{ .put = .snow } }).status);
    game.flushBlockOperations();
    try std.testing.expectEqual(1, game.world.?.pending_operations.items.len);
    const edit_id = game.world.?.pending_operations.items[0].request_id.?;
    const next_request_id = game.world_client.?.next_request_id;
    var dependency_failed = false;
    for (0..5000) |_| {
        const status = service.persistenceStatus();
        if (status.phase == .failed and status.pending_commands == 1) {
            try std.testing.expectEqualStrings("ChecksumMismatch", status.error_name.?);
            dependency_failed = true;
            break;
        }
        try std.Io.sleep(std.testing.io, .fromMilliseconds(1), .awake);
    }
    try std.testing.expect(dependency_failed);
    _ = game.receiveChunks();
    game.setOverlay(.world_map);
    game.handleMapAction(.{ .teleport_xy = .{ 10.5, 10.5 } });
    try std.testing.expect(game.mapView(&fixture.scene).teleport_pending);
    game.updateMapTeleport();
    try std.testing.expectEqual(null, game.map_teleport);
    try std.testing.expectEqualStrings("Teleport unavailable while terrain edits are blocked", game.map_teleport_error.?);
    try std.testing.expect(!game.mapView(&fixture.scene).teleport_pending);
    try std.testing.expectEqual(.world_map, game.overlay);
    try std.testing.expectEqual(Position{ 0.5, 0.5, -16 }, game.player.?.position);
    try std.testing.expectEqualDeep(original_camera, fixture.camera.position);
    try std.testing.expectEqual(@as(f32, 0.7), game.player.?.yaw);
    try std.testing.expectEqual(@as(f32, -0.2), game.player.?.pitch);
    try std.testing.expectEqual(@as(f64, -30), game.player.?.vertical_velocity);
    try std.testing.expectEqual(voxel_chunk_module.BlockType.planks, game.block_interaction.inventory.?);
    // The unsuccessful teleport neither dispatches a search nor resolves or
    // drops the edit whose authoritative dependency remains unreadable.
    try std.testing.expectEqual(next_request_id, game.world_client.?.next_request_id);
    try std.testing.expectEqual(1, game.world.?.pending_operations.items.len);
    try std.testing.expectEqual(edit_id, game.world.?.pending_operations.items[0].request_id.?);
    try std.testing.expectEqualDeep(block, game.world.?.pending_operations.items[0].operation.block);

    try std.testing.expect(handleUIKeyPress(game, .{ .key = .m, .mods = .{} }));
    try std.testing.expectEqual(.none, game.overlay);
    game.setOverlay(.world_map);
    try std.testing.expect(handleUIKeyPress(game, .{ .key = .escape, .mods = .{} }));
    try std.testing.expectEqual(.none, game.overlay);
    game.setOverlay(.world_map);
    game.handleMapAction(.{ .close = true });
    try std.testing.expectEqual(.none, game.overlay);
    try std.testing.expect(handleUIKeyPress(game, .{ .key = .escape, .mods = .{} }));
    try std.testing.expectEqual(.menu, game.overlay);
    try std.testing.expect(fixture.engine.paused);
    try std.testing.expectEqual(edit_id, game.world.?.pending_operations.items[0].request_id.?);
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

test "map teleport timeout restores controls while preserving edits and ignores late search replies" {
    if (comptime !world_map.debug_teleport_enabled) return error.SkipZigTest;
    for ([_]bool{ false, true }) |submitted| {
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
        game.player.?.applyCamera(&fixture.camera);
        const camera_position = fixture.camera.position;
        game.block_interaction.inventory = .planks;
        const block = [3]u32{ 42, 42, 48 };
        if (!submitted) {
            try game.world.?.insertChunk(layout.origin_chunk, WorldChunk.initEmpty());
            game.world.?.setBlockUnchecked(block, .dirt);
            try std.testing.expectEqual(1, game.world.?.pending_operations.items.len);
        }
        fixture.engine.real_time = 10;
        game.setOverlay(.world_map);
        game.handleMapAction(.{ .teleport_xy = .{ -10.5, -10.5 } });
        const deadline = game.map_teleport.?.deadline;
        try std.testing.expectEqual(@as(f64, 40), deadline);
        fixture.engine.real_time = deadline - 0.001;
        game.updateMapTeleport();
        const request_id = game.map_teleport.?.request_id;
        try std.testing.expectEqual(submitted, request_id != null);
        game.handleMapAction(.{ .close = true });
        try std.testing.expectEqual(.world_map, game.overlay);
        fixture.engine.real_time = deadline;
        game.updateMapTeleport();
        try std.testing.expectEqual(null, game.map_teleport);
        try std.testing.expectEqualStrings("Teleport timed out; try again", game.map_teleport_error.?);
        try std.testing.expect(!game.mapView(&fixture.scene).teleport_pending);
        try std.testing.expectEqual(original, game.player.?.position);
        try std.testing.expectEqual(camera_position, fixture.camera.position);
        try std.testing.expectEqual(voxel_chunk_module.BlockType.planks, game.block_interaction.inventory.?);
        if (submitted) {
            game.handleMapAction(.{ .teleport_xy = .{ 10.5, 10.5 } });
            game.updateMapTeleport();
            try std.testing.expect(game.map_teleport.?.request_id.? != request_id.?);
            try finishMapTeleport(game);
            try std.testing.expectEqual(Position{ 10.5, 10.5, -16 }, game.player.?.position);
        } else {
            try std.testing.expectEqual(1, game.world.?.pending_operations.items.len);
            try std.testing.expectEqual(null, game.world.?.pending_operations.items[0].request_id);
            try std.testing.expect(try game.world.?.isBlockSolid(block));
            game.handleMapAction(.{ .close = true });
        }
        try std.testing.expect(game.overlay == .none and !fixture.engine.gameplay_input_blocked);
    }
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

fn drawBlockActionProgress(hold: player_interaction.Interaction.Hold) void {
    const screen = zgui.io.getDisplaySize();
    if (screen[0] <= 0 or screen[1] <= 0) return;
    const scale = zgui.getStyle().font_scale_dpi;
    const min: [2]f32 = .{ screen[0] / 2 - 32 * scale, screen[1] / 2 + 16 * scale };
    const max: [2]f32 = .{ min[0] + 64 * scale, min[1] + 8 * scale };
    const inner_min: [2]f32 = .{ min[0] + scale, min[1] + scale };
    const inner_max: [2]f32 = .{ max[0] - scale, max[1] - scale };
    const progress: f32 = @floatCast(std.math.clamp(hold.elapsed / hold.duration(), 0, 1));
    const list = zgui.getForegroundDrawList();
    list.addRectFilled(.{
        .pmin = min,
        .pmax = max,
        .col = zgui.colorConvertFloat4ToU32(.{ 0, 0, 0, 1 }),
    });
    list.addRectFilled(.{
        .pmin = inner_min,
        .pmax = inner_max,
        .col = zgui.colorConvertFloat4ToU32(.{ 0.15, 0.15, 0.15, 1 }),
    });
    if (progress > 0) list.addRectFilled(.{
        .pmin = inner_min,
        .pmax = .{ inner_min[0] + (inner_max[0] - inner_min[0]) * progress, inner_max[1] },
        .col = zgui.colorConvertFloat4ToU32(.{ 1, 1, 1, 1 }),
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
    // Keep this focus/cache fixture's single-cell geological foundation; literal
    // stone platform diagnostics are covered by the structural-rule fixtures.
    fixture.game.world.?.setBlockUnchecked(.{ target[0], target[1] - 1, target[2] - 1 }, .limestone);
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
    defer game.deinitMiniatureState();
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
    game.drainChunkVisualsForTesting();
    try std.testing.expectEqual(0, game.dirty_chunk_ids.count());
    try std.testing.expectEqual(1, grid.chunks_to_upload.items.len);
    const upload = grid.chunks_to_upload.items[0];
    try std.testing.expectEqual(coords, upload.chunk_coords);
    for (upload.chunk_side_data.blocks_grouped_by_side) |side| {
        try std.testing.expectEqual(1, side.items.len);
        try std.testing.expectEqual(voxel_chunk_module.RenderMaterial.grass, side.items[0].block_type);
        try std.testing.expectEqual([3]u8{ 2, 3, 4 }, side.items[0].coords);
    }
    game.drainChunkVisualsForTesting();
    try std.testing.expectEqual(1, grid.chunks_to_upload.items.len);

    // After the upload, a later frame can dirty the same chunk again. Removing its last
    // block must remove its previous mesh even though there is no replacement to upload.
    grid.clearChunks();
    try grid.chunks.append(allocator, voxel_chunk_module.VoxelChunk.init(coords));
    game.world.?.setBlockUnchecked(block, .none);
    game.markChunksAroundBlockDirty(block);
    try std.testing.expectEqual(1, grid.chunks.items.len);
    game.drainChunkVisualsForTesting();
    try std.testing.expectEqual(0, grid.chunks.items.len);
    try std.testing.expectEqual(0, grid.chunks_to_upload.items.len);
    try std.testing.expect(game.loaded_chunk_ids.contains(chunk_id));

    // An empty loaded chunk can become visible again in a subsequent frame.
    game.world.?.setBlockUnchecked(block, .stone);
    game.markChunksAroundBlockDirty(block);
    game.drainChunkVisualsForTesting();
    try std.testing.expectEqual(1, grid.chunks_to_upload.items.len);
    grid.clearChunks();

    // Unloading cancels pending work, and later invalidations don't reload the chunk.
    game.markChunkAndNeighborsDirty(coords);
    game.removeChunkByIdIfNeeded(chunk_id);
    game.markChunksAroundBlockDirty(block);
    game.drainChunkVisualsForTesting();
    try std.testing.expectEqual(0, game.dirty_chunk_ids.count());
    try std.testing.expectEqual(0, grid.chunks_to_upload.items.len);
    try std.testing.expect(!game.loaded_chunk_ids.contains(chunk_id));
}

test "boundary edits dirty only loaded face neighbors with world wrapping and limits" {
    var game: Game = .{ .allocator = std.testing.allocator, .engine = undefined, .world = try World.init(std.testing.allocator, &test_layout) };
    defer game.world.?.deinit();
    defer game.loaded_chunk_ids.deinit(game.allocator);
    defer game.dirty_chunk_ids.deinit(game.allocator);
    defer game.deinitMiniatureState();
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
    defer game.deinitMiniatureState();
    defer game.chunk_subscriptions.deinit(allocator);
    const coords = ChunkCoords{ 1, 1, 2 };
    var prepared = try world_generator.WorldGenerator.prepare(.flat, std.testing.allocator, &test_layout);
    defer prepared.deinit(std.testing.allocator);
    const column = world_generator.ColumnGenerator.init(&prepared, .{ 1, 1 });
    try game.world.?.insertChunk(coords, column.generateChunk(allocator, 2));
    try game.world.?.insertChunk(.{ 1, 1, 3 }, column.generateChunk(allocator, 3));
    game.loadChunkIfNeeded(1, 1, 2);
    game.drainChunkVisualsForTesting();
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
    game.drainChunkVisualsForTesting();
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
    game.drainChunkVisualsForTesting();
    try std.testing.expectEqual(1, grid.chunks_to_upload.items.len);
    try std.testing.expectEqual(coords, grid.chunks_to_upload.items[0].chunk_coords);
    grid.clearChunks();

    // A service-only metadata change also invalidates a hidden chunk's GPU state.
    const remote_coords = ChunkCoords{ 5, 5, 2 };
    const remote_column = world_generator.ColumnGenerator.init(&prepared, .{ 5, 5 });
    try game.world.?.insertChunk(remote_coords, remote_column.generateChunk(allocator, 2));
    game.loadChunkIfNeeded(5, 5, 2);
    game.drainChunkVisualsForTesting();
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
    game.drainChunkVisualsForTesting();
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
        self.engine.io = std.testing.io;
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
        self.game.blueprint_tool.deinit(allocator);
        self.game.blueprint_render_instances.deinit(allocator);
        self.game.deinitMiniatureState();
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
        try std.testing.expect(self.game.applyPackage(&package));
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
            try std.testing.expect(self.game.applyPackage(package));
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
            self.game.drainChunkVisualsForTesting();
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
        fixture.game.drainChunkVisualsForTesting();
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
            fixture.game.drainChunkVisualsForTesting();
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
    fixture.game.drainChunkVisualsForTesting();
    fixture.grid.clearChunks();

    for (0..4) |step| {
        _ = worker.submitOperation(.{ .block = block, .action = if (step % 2 == 0) .{ .put = .dirt } else .remove });
        try fixture.waitAndApplyPackages();
        fixture.game.drainChunkVisualsForTesting();
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
    fixture.game.drainChunkVisualsForTesting();
    const neighbor_faces = fixture.upload(neighbor).chunk_side_data.blocks_grouped_by_side[@intFromEnum(Side.bottom)].items.ptr;
    var snapshot = singleTestBlock(local, 1);
    snapshot.changeType(local, .grass);
    try fixture.apply(&.{.{ .coords = coords, .subscription_id = 1, .chunk_revision = 1, .data = .{ .blocks = .{ .chunk = snapshot } } }});
    try std.testing.expectEqual(1, fixture.game.dirty_chunk_ids.count());
    try std.testing.expect(!fixture.game.dirty_chunk_ids.contains(neighbor_id));
    fixture.game.drainChunkVisualsForTesting();
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
    fixture.game.drainChunkVisualsForTesting();
    fixture.game.world.?.setBlockUnchecked(block, .none);
    fixture.game.world.?.pending_operations.items[0].request_id = 7;
    fixture.game.markChunksAroundBlockDirty(block);
    fixture.game.drainChunkVisualsForTesting();
    try std.testing.expectEqual(1, fixture.upload(neighbor).chunk_side_data.blocks_grouped_by_side[@intFromEnum(Side.left)].items.len);

    // An older authority snapshot still contains the block; pending removal is replayed.
    try fixture.apply(&.{.{ .coords = coords, .subscription_id = 1, .data = .{ .blocks = .{ .chunk = singleTestBlock(local, 0) } } }});
    try std.testing.expectEqual(voxel_chunk_module.BlockType.none, fixture.game.world.?.getChunk(coords).?.content.getBlock(local));
    try std.testing.expect(!fixture.game.dirty_chunk_ids.contains(neighbor_id));
    fixture.game.drainChunkVisualsForTesting();

    // A failed acknowledgment retires the removal and restores boundary occupancy.
    try fixture.apply(&.{.{ .coords = coords, .subscription_id = 1, .operation = .{ .request_id = 7, .status = .constraint_violation }, .data = .{ .blocks = .{ .chunk = singleTestBlock(local, 0) } } }});
    try std.testing.expectEqual(0, fixture.game.world.?.pending_operations.items.len);
    try std.testing.expect(fixture.game.dirty_chunk_ids.contains(neighbor_id));
    fixture.game.drainChunkVisualsForTesting();
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
        fixture.game.drainChunkVisualsForTesting();
        try std.testing.expectEqual(0, fixture.upload(coords).chunk_side_data.blocks_grouped_by_side[i].items.len);

        // Reject a remote removal on B's obsolete block subscription, retaining its blocks.
        try fixture.subscribe(neighbor, 3, .mesh);
        try fixture.apply(&.{
            .{ .coords = neighbor, .subscription_id = 2, .chunk_revision = 1, .mesh_revision = 1, .data = .{ .blocks = .{ .chunk = WorldChunk.initEmpty() } } },
            .{ .coords = coords, .subscription_id = 1, .mesh_revision = 1, .data = .{ .boundaries = @splat(.{}) } },
        });
        try std.testing.expectEqual(voxel_chunk_module.BlockType.stone, fixture.game.world.?.getChunk(neighbor).?.content.getBlock(.{ 0, 8, 8 }));
        fixture.game.drainChunkVisualsForTesting();
        try std.testing.expectEqual(1, fixture.upload(coords).chunk_side_data.blocks_grouped_by_side[i].items.len);

        // Restore B at the authority, then promote before the demotion mesh arrives.
        try fixture.subscribe(neighbor, 4, .blocks);
        const snapshot: ChunkResponse = .{ .coords = neighbor, .subscription_id = 4, .chunk_revision = 2, .mesh_revision = 2, .data = .{ .blocks = .{ .chunk = singleTestBlock(.{ 0, 8, 8 }, 2) } } };
        const boundaries: ChunkResponse = .{ .coords = coords, .subscription_id = 1, .mesh_revision = 2, .data = .{ .boundaries = solid_masks } };
        try fixture.apply(if (boundaries_first) &.{ boundaries, snapshot } else &.{ snapshot, boundaries });
        fixture.game.drainChunkVisualsForTesting();
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
    fixture.game.drainChunkVisualsForTesting();
    try std.testing.expect(fixture.game.world.?.hasChunk(coords));
    try std.testing.expect(fixture.game.mesh_versions.contains(id));
    try std.testing.expectEqual(original_faces, fixture.grid.chunks_to_upload.items[0].chunk_side_data.blocks_grouped_by_side[0].items.ptr);

    try fixture.game.world.?.insertChunk(.{ 2, 1, 1 }, singleTestBlock(.{ 0, 8, 8 }, 1));
    try fixture.apply(&.{.{ .coords = coords, .subscription_id = 2, .chunk_revision = 12, .mesh_revision = 21, .data = .{ .blocks = .{ .chunk = chunk.clone(std.testing.allocator) } } }});
    try std.testing.expect(fixture.game.dirty_chunk_ids.contains(id));
    fixture.game.drainChunkVisualsForTesting();
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
    fixture.game.drainChunkVisualsForTesting();
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
    fixture.game.drainChunkVisualsForTesting();
    try std.testing.expectEqual(0, fixture.grid.chunks_to_upload.items[0].chunk_side_data.blocks_grouped_by_side[@intFromEnum(Side.right)].items.len);
    // A neighbor-only update exposes this outward face without loading distant blocks.
    try fixture.apply(&.{.{ .coords = coords, .subscription_id = 1, .mesh_revision = 1, .data = .{ .boundaries = @splat(.{}) } }});
    fixture.game.drainChunkVisualsForTesting();
    try std.testing.expectEqual(1, fixture.grid.chunks_to_upload.items[0].chunk_side_data.blocks_grouped_by_side[@intFromEnum(Side.right)].items.len);
    try std.testing.expect(!fixture.game.world.?.hasChunk(.{ 3, 1, 1 }));
    try fixture.game.world.?.insertChunk(.{ 3, 1, 1 }, singleTestBlock(.{ 0, 8, 8 }, 0));
    fixture.game.markChunkAndNeighborsDirty(.{ 3, 1, 1 });
    fixture.game.drainChunkVisualsForTesting();
    try std.testing.expectEqual(0, fixture.grid.chunks_to_upload.items[0].chunk_side_data.blocks_grouped_by_side[@intFromEnum(Side.right)].items.len);
    const edited = [3]u32{ 3 * consts.CHUNK_SIZE, consts.CHUNK_SIZE + 8, consts.CHUNK_SIZE + 8 };
    fixture.game.world.?.setBlockUnchecked(edited, .none);
    fixture.game.markChunksAroundBlockDirty(edited);
    // The authoritative fallback still contains the block we just removed optimistically.
    try fixture.apply(&.{.{ .coords = coords, .subscription_id = 1, .mesh_revision = 2, .data = .{ .boundaries = masks } }});
    fixture.game.drainChunkVisualsForTesting();
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
    fixture.game.drainChunkVisualsForTesting();
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
    fixture.game.drainChunkVisualsForTesting();
    try std.testing.expectEqual(1, fixture.grid.chunks_to_upload.items[0].chunk_side_data.blocks_grouped_by_side[@intFromEnum(Side.left)].items.len);
    const original_faces = fixture.grid.chunks_to_upload.items[0].chunk_side_data.blocks_grouped_by_side[0].items.ptr;
    fixture.game.last_camera_chunk_coords = .{ 0, 2, 2 };
    try fixture.subscribe(coords, 2, .mesh);
    fixture.game.drainChunkVisualsForTesting();
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
    fixture.game.drainChunkVisualsForTesting();
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
    fixture.game.drainChunkVisualsForTesting();
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
    fixture.game.drainChunkVisualsForTesting();
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
        fixture.game.drainChunkVisualsForTesting();
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
    fixture.game.drainChunkVisualsForTesting();
    try std.testing.expectEqual(0, fixture.grid.chunks_to_upload.items[0].chunk_side_data.blocks_grouped_by_side[@intFromEnum(Side.right)].items.len);
    try fixture.subscribe(neighbor, 3, .mesh);
    try fixture.apply(&.{.{ .coords = coords, .subscription_id = 1, .mesh_revision = 1, .data = .{ .boundaries = @splat(.{}) } }});
    fixture.game.drainChunkVisualsForTesting();
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
        fixture.game.drainChunkVisualsForTesting();
        const original_faces = fixture.grid.chunks_to_upload.items[0].chunk_side_data.blocks_grouped_by_side[i].items.ptr;
        try std.testing.expectEqual(1, fixture.grid.chunks_to_upload.items[0].chunk_side_data.blocks_grouped_by_side[i].items.len);

        try fixture.apply(&.{.{ .coords = coords, .subscription_id = 1, .mesh_revision = 2, .data = .{ .boundaries = @splat(.{}) } }});
        try std.testing.expect(!fixture.game.dirty_chunk_ids.contains(id));
        try std.testing.expectEqual(2, fixture.game.boundary_snapshots.get(id).?.mesh_revision);
        try std.testing.expect(!fixture.game.boundary_snapshots.get(id).?.masks[i].contains(side, opposite_air));
        fixture.game.drainChunkVisualsForTesting();
        try std.testing.expectEqual(original_faces, fixture.grid.chunks_to_upload.items[0].chunk_side_data.blocks_grouped_by_side[i].items.ptr);

        // This placement must use the updated plane even though no rebuild accompanied it.
        const block = [3]u32{
            @as(u32, @intCast(coords[0])) * consts.CHUNK_SIZE + opposite_air[0],
            @as(u32, @intCast(coords[1])) * consts.CHUNK_SIZE + opposite_air[1],
            @as(u32, @intCast(coords[2])) * consts.CHUNK_SIZE + opposite_air[2],
        };
        fixture.game.world.?.setBlockUnchecked(block, .sand);
        fixture.game.markChunksAroundBlockDirty(block);
        fixture.game.drainChunkVisualsForTesting();
        try std.testing.expectEqual(2, fixture.grid.chunks_to_upload.items[0].chunk_side_data.blocks_grouped_by_side[i].items.len);

        masks[i].set(side, opposite_air, false);
        masks[i].set(side, local, true);
        try fixture.apply(&.{.{ .coords = coords, .subscription_id = 1, .mesh_revision = 3, .data = .{ .boundaries = masks } }});
        try std.testing.expect(fixture.game.dirty_chunk_ids.contains(id));
        fixture.game.drainChunkVisualsForTesting();
        try std.testing.expectEqual(1, fixture.grid.chunks_to_upload.items[0].chunk_side_data.blocks_grouped_by_side[i].items.len);
        try fixture.apply(&.{.{ .coords = coords, .subscription_id = 1, .mesh_revision = 4, .data = .{ .boundaries = @splat(.{}) } }});
        try std.testing.expect(fixture.game.dirty_chunk_ids.contains(id));
        fixture.game.drainChunkVisualsForTesting();
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
    fixture.game.drainChunkVisualsForTesting();
    const edited = [3]u32{ 2 * consts.CHUNK_SIZE, consts.CHUNK_SIZE + 8, consts.CHUNK_SIZE + 8 };
    fixture.game.world.?.setBlockUnchecked(edited, .none);
    fixture.game.markChunksAroundBlockDirty(edited);
    fixture.game.drainChunkVisualsForTesting();
    try std.testing.expectEqual(1, fixture.grid.chunks_to_upload.items[0].chunk_side_data.blocks_grouped_by_side[i].items.len);
    const original_faces = fixture.grid.chunks_to_upload.items[0].chunk_side_data.blocks_grouped_by_side[i].items.ptr;
    try fixture.apply(&.{.{ .coords = coords, .subscription_id = 1, .mesh_revision = 2, .data = .{ .boundaries = @splat(.{}) } }});
    try std.testing.expect(!fixture.game.dirty_chunk_ids.contains(id));
    try std.testing.expect(!fixture.game.boundary_snapshots.get(id).?.masks[i].contains(.right, .{ 31, 8, 8 }));
    fixture.game.drainChunkVisualsForTesting();
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

test "mouse2 compacts the aimed loose soil in three seconds with either inventory state" {
    for ([_]?voxel_chunk_module.BlockType{ null, .sand }) |inventory| {
        var fixture: StreamingTest = .{};
        fixture.init();
        defer fixture.deinit();
        try fixture.preparePlayerToolTest();
        const game = &fixture.game;
        const target = StreamingTest.toolTarget();
        fixture.changeToolMaterial(.dirt);
        game.block_interaction.inventory = inventory;
        handleMouseButtonPress(game, .{ .button = .right, .mods = .{} });
        game.updateBlockTool();
        try std.testing.expectEqual(.compact, std.meta.activeTag(game.block_interaction.holding.?.operation.action));
        try std.testing.expectEqual(player_interaction.compaction_seconds, game.block_interaction.holding.?.duration());
        game.updateBlockFocus();
        try std.testing.expectEqual(StreamingTest.toolTarget(), fixture.scene.highlighted_block.?);
        try std.testing.expectEqual(null, game.current_placement_preview);
        fixture.engine.frame_delta = 2.75;
        game.updateBlockTool();
        try std.testing.expectEqual(voxel_chunk_module.BlockType.dirt, game.world.?.reader().get(.{ target[0], target[1], target[2] }).?);
        try std.testing.expectEqual(0, game.world.?.pending_operations.items.len);
        fixture.engine.frame_delta = 0.25;
        game.updateBlockTool();
        try std.testing.expectEqual(voxel_chunk_module.BlockType.packed_dirt, game.world.?.reader().get(.{ target[0], target[1], target[2] }).?);
        try std.testing.expectEqual(inventory, game.block_interaction.inventory);
        try std.testing.expectEqual(null, game.block_interaction.holding);
        try std.testing.expectEqual(.compact, std.meta.activeTag(game.world.?.pending_operations.items[0].operation.action));
        try fixture.acknowledgePlayer(1, .success, inventory);
        game.updateBlockTool();
        try std.testing.expectEqual(null, game.block_interaction.pending);
        try std.testing.expectEqual(null, game.block_interaction.holding);
        try std.testing.expectEqual(inventory, game.block_interaction.inventory);
    }
}

test "mouse2 work cancels on release target range terrain focus and control changes" {
    for (0..8) |cause| {
        var fixture: StreamingTest = .{};
        fixture.init();
        defer fixture.deinit();
        try fixture.preparePlayerToolTest();
        const game = &fixture.game;
        var spectator: std.meta.Child(@TypeOf(fixture.scene.spectator_camera)) = .{
            .camera = &fixture.camera,
            .input_controller = @ptrCast(&fixture.input),
        };
        fixture.scene.spectator_camera = &spectator;
        fixture.changeToolMaterial(.dirt);
        handleMouseButtonPress(game, .{ .button = .right, .mods = .{} });
        game.updateBlockTool();
        fixture.engine.frame_delta = 2;
        game.updateBlockTool();
        switch (cause) {
            0 => handleMouseButtonRelease(game, .{ .button = .right, .mods = .{} }),
            1 => fixture.camera.updateView(zmath.rotationY(math.pi / 2.0)),
            2 => {
                try game.world.?.insertChunk(test_layout.origin_chunk - ChunkCoords{ 0, 1, 0 }, WorldChunk.initEmpty());
                fixture.camera.updatePosition(.{ 0.5, -5, 0.5 });
            },
            3 => fixture.changeToolMaterial(.packed_dirt),
            4 => fixture.input.focused = false,
            5 => fixture.input.focus_changed = true,
            6 => game.world.?.removeChunk(test_layout.origin_chunk),
            7 => {
                game.player = PlayerController.init(std.testing.allocator, .{ 0.5, 0.5, 0 });
                game.toggleControlMode();
            },
            else => unreachable,
        }
        game.updateBlockTool();
        try std.testing.expectEqual(null, game.block_interaction.holding);
        try std.testing.expectEqual(null, game.block_interaction.inventory);
        try std.testing.expectEqual(0, game.world.?.pending_operations.items.len);
    }
}

test "mouse2 ignores non-loose materials and cannot restart after early release without a press" {
    var fixture: StreamingTest = .{};
    fixture.init();
    defer fixture.deinit();
    try fixture.preparePlayerToolTest();
    const game = &fixture.game;
    for ([_]voxel_chunk_module.BlockType{ .sand, .packed_dirt, .grass, .stone }) |material| {
        fixture.changeToolMaterial(material);
        handleMouseButtonPress(game, .{ .button = .right, .mods = .{} });
        game.updateBlockTool();
        try std.testing.expectEqual(null, game.block_interaction.holding);
        handleMouseButtonRelease(game, .{ .button = .right, .mods = .{} });
    }
    fixture.changeToolMaterial(.dirt);
    handleMouseButtonPress(game, .{ .button = .right, .mods = .{} });
    game.updateBlockTool();
    fixture.engine.frame_delta = 2.9;
    game.updateBlockTool();
    handleMouseButtonRelease(game, .{ .button = .right, .mods = .{} });
    fixture.engine.frame_delta = 10;
    game.updateBlockTool();
    try std.testing.expectEqual(null, game.block_interaction.holding);
    try std.testing.expectEqual(0, game.world.?.pending_operations.items.len);
    handleMouseButtonPress(game, .{ .button = .right, .mods = .{} });
    game.updateBlockTool();
    try std.testing.expectEqual(@as(f64, 0), game.block_interaction.holding.?.elapsed);
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

test "blueprint capture preserves normal quick-tap and held Space jumps" {
    const coordinates = @import("block_coordinates.zig");
    for ([_]bool{ false, true }) |capture| {
        for ([_]bool{ false, true }) |held| {
            var fixture: StreamingTest = .{};
            fixture.init();
            defer fixture.deinit();
            const game = &fixture.game;
            try game.world.?.insertChunk(test_layout.origin_chunk, WorldChunk.initEmpty());
            try game.world.?.insertChunk(test_layout.origin_chunk - ChunkCoords{ 0, 0, 1 }, WorldChunk.initEmpty());
            game.world.?.setBlockUnchecked(coordinates.fromWorld(&test_layout, .{ 0, 0, -1 }).?, .stone);
            game.player = PlayerController.init(std.testing.allocator, .{ 0.5, 0.5, 0 });
            if (capture) game.enterBlueprintCapture();
            try std.testing.expect(!handleUIKeyPress(game, .{ .key = .space, .mods = .{} }));
            handleKeyPress(game, .{ .key = .space, .mods = .{} });
            if (held) {
                try fixture.input.pressed_keys.put(.space, {});
            } else {
                // A press and release between frames must still jump once.
                handleKeyRelease(game, .{ .key = .space, .mods = .{} });
            }
            fixture.engine.frame_delta = 0.1;
            fixture.engine.time = fixture.engine.frame_delta;
            game.updateGameplay(false);
            try std.testing.expectApproxEqAbs(player_module.jump_speed * 0.1 - 0.5 * player_module.gravity * 0.1 * 0.1, game.player.?.position[2], 0.000001);
            try std.testing.expectApproxEqAbs(player_module.jump_speed - player_module.gravity * 0.1, game.player.?.vertical_velocity, 0.000001);
            try std.testing.expect(!game.jump_requested);
            for (0..20) |_| {
                fixture.engine.time += fixture.engine.frame_delta;
                game.updateGameplay(false);
            }
            try std.testing.expect(game.player.?.grounded);
            try std.testing.expectApproxEqAbs(@as(f64, 0), game.player.?.position[2], 0.000001);
            try std.testing.expectEqual(@as(f64, 0), game.player.?.vertical_velocity);
        }
    }
}

test "blueprint foreground routing owns capture reset, text, map, and held inputs" {
    var fixture: StreamingTest = .{};
    fixture.init();
    defer fixture.deinit();
    const game = &fixture.game;
    game.block_interaction.inventory = .sand;
    try std.testing.expect(handleUIKeyPress(game, .{ .key = .z, .mods = .{} }));
    try std.testing.expectEqual(.none, game.blueprint_tool.mode);
    try std.testing.expect(game.block_action_error.message(0) != null);
    game.block_interaction.inventory = null;
    game.block_interaction.press(.key);
    game.jump_requested = true;
    try std.testing.expect(handleUIKeyPress(game, .{ .key = .z, .mods = .{} }));
    try std.testing.expectEqual(.capture, game.blueprint_tool.mode);
    try std.testing.expect(!fixture.engine.gameplay_input_blocked and !fixture.engine.paused);
    try std.testing.expectEqual(null, game.block_interaction.requested);
    try std.testing.expect(!game.jump_requested);
    const generation = game.blueprint_tool.selection.generation;
    try std.testing.expect(handleUIKeyPress(game, .{ .key = .m, .mods = .{} }));
    try std.testing.expectEqual(.none, game.overlay);
    try std.testing.expect(handleUIKeyPress(game, .{ .key = .b, .mods = .{} }));
    try std.testing.expectEqual(blueprint_capture.Stage.anchor, game.blueprint_tool.selection.stage);
    try std.testing.expect(handleUIKeyPress(game, .{ .key = .enter, .mods = .{} }));
    try std.testing.expectEqual(blueprint_capture.Stage.anchor, game.blueprint_tool.selection.stage);
    try std.testing.expect(!handleUIKeyPress(game, .{ .key = .b, .mods = .{ .control = true } }));
    const compiled = try blueprint.compile(std.testing.allocator, .{ .size = .{ 1, 1, 1 }, .cells = &.{.dirt} }, .{ .horizontal_limit = blueprint.horizontalLimit(game.layout()) });
    game.blueprint_tool.candidate = compiled.valid;
    game.blueprint_tool.selection.stage = .ready;
    try std.testing.expect(handleUIKeyPress(game, .{ .key = .b, .mods = .{} }));
    try std.testing.expectEqual(blueprint_capture.Stage.ready, game.blueprint_tool.selection.stage);
    try std.testing.expect(handleUIKeyPress(game, .{ .key = .enter, .mods = .{} }));
    try std.testing.expectEqual(blueprint_capture.Stage.naming, game.blueprint_tool.selection.stage);
    try std.testing.expect(fixture.engine.gameplay_input_blocked and !fixture.engine.paused);
    inline for (.{ zglfw.Key.m, .z, .f, .q, .b, .enter, .kp_enter, .r, .e, .space }) |key| {
        try std.testing.expect(handleUIKeyPress(game, .{ .key = key, .mods = .{} }));
        try std.testing.expectEqual(blueprint_capture.Stage.naming, game.blueprint_tool.selection.stage);
        try std.testing.expectEqual(.capture, game.blueprint_tool.mode);
    }
    try std.testing.expect(handleUIKeyPress(game, .{ .key = .escape, .mods = .{} }));
    try std.testing.expectEqual(.capture, game.blueprint_tool.mode);
    try std.testing.expectEqual(blueprint_capture.Stage.anchor, game.blueprint_tool.selection.stage);
    try std.testing.expect(game.blueprint_tool.selection.generation != generation);
    try std.testing.expectEqual(null, game.blueprint_tool.candidate);
    try std.testing.expectEqual(.none, game.overlay);
    try std.testing.expect(!fixture.engine.gameplay_input_blocked);
    try std.testing.expect(handleUIKeyPress(game, .{ .key = .z, .mods = .{} }));
    try std.testing.expectEqual(.none, game.blueprint_tool.mode);
    try std.testing.expect(handleUIKeyPress(game, .{ .key = .m, .mods = .{} }));
    try std.testing.expectEqual(.world_map, game.overlay);
    try std.testing.expect(handleUIKeyPress(game, .{ .key = .z, .mods = .{} }));
    try std.testing.expect(handleUIKeyPress(game, .{ .key = .b, .mods = .{} }));
    try std.testing.expectEqual(.none, game.blueprint_tool.mode);
    try std.testing.expect(handleUIKeyPress(game, .{ .key = .escape, .mods = .{} }));
    try std.testing.expectEqual(.none, game.overlay);
    try std.testing.expect(!handleUIKeyPress(game, .{ .key = .f, .mods = .{} }));
    try std.testing.expect(!handleUIKeyPress(game, .{ .key = .enter, .mods = .{} }));
    try std.testing.expect(!handleUIKeyPress(game, .{ .key = .b, .mods = .{ .control = true } }));
    try std.testing.expect(handleUIKeyPress(game, .{ .key = .b, .mods = .{} }));
    try std.testing.expectEqual(.none, game.blueprint_tool.mode);
    try std.testing.expectEqualStrings("You do not have any blueprints yet.", game.block_action_error.message(0).?);

    const runtime = @import("blueprint_runtime.zig");
    var saved: runtime.SavedDefinition = .{ .id = 1, .owner = game.player_id, .name = try std.testing.allocator.dupe(u8, "Hotkeys"), .definition = .{ .size = .{ 1, 1, 1 }, .cells = try std.testing.allocator.dupe(voxel_chunk_module.BlockType, &.{.dirt}), .target_count = 1 } };
    defer saved.deinit(std.testing.allocator);
    try game.world.?.applyBlueprintChanges(&.{.{ .definition = saved }});
    try std.testing.expect(handleUIKeyPress(game, .{ .key = .b, .mods = .{} }));
    try std.testing.expect(game.blueprint_tool.chooser_open);
    try std.testing.expectEqual(.none, game.blueprint_tool.mode);
    try std.testing.expect(fixture.engine.gameplay_input_blocked);
    try std.testing.expect(handleUIKeyPress(game, .{ .key = .b, .mods = .{} }));
    try std.testing.expect(!game.blueprint_tool.chooser_open);
    try std.testing.expectEqual(.none, game.blueprint_tool.mode);
    game.blueprint_tool.mode = .preview;
    game.updateBlueprintInputBlock();
    try std.testing.expect(!handleUIKeyPress(game, .{ .key = .b, .mods = .{ .control = true } }));
    try std.testing.expectEqual(.preview, game.blueprint_tool.mode);
    try std.testing.expect(!handleUIKeyPress(game, .{ .key = .f, .mods = .{} }));
    try std.testing.expectEqual(.preview, game.blueprint_tool.mode);
    try std.testing.expect(handleUIKeyPress(game, .{ .key = .b, .mods = .{} }));
    try std.testing.expectEqual(.none, game.blueprint_tool.mode);
}

test "blueprint chooser preserves unanchored capture until a definition is selected" {
    var fixture: StreamingTest = .{};
    fixture.init();
    defer fixture.deinit();
    try fixture.prepareToolTest();
    const game = &fixture.game;
    game.control_mode = .player;
    game.enterBlueprintCapture();
    const generation = game.blueprint_tool.selection.generation;
    try std.testing.expect(handleUIKeyPress(game, .{ .key = .b, .mods = .{} }));
    try std.testing.expect(!game.blueprint_tool.chooser_open);
    try std.testing.expectEqual(.capture, game.blueprint_tool.mode);
    try std.testing.expectEqual(generation, game.blueprint_tool.selection.generation);
    try std.testing.expectEqualStrings("You do not have any blueprints yet.", game.block_action_error.message(0).?);

    const runtime = @import("blueprint_runtime.zig");
    var saved: runtime.SavedDefinition = .{ .id = 1, .owner = game.player_id, .name = try std.testing.allocator.dupe(u8, "Chooser"), .definition = .{ .size = .{ 1, 1, 1 }, .cells = try std.testing.allocator.dupe(voxel_chunk_module.BlockType, &.{.dirt}), .target_count = 1 } };
    defer saved.deinit(std.testing.allocator);
    try game.world.?.applyBlueprintChanges(&.{.{ .definition = saved }});
    const Dismissal = enum { button, escape, hotkey };
    for ([_]Dismissal{ .button, .escape, .hotkey }) |dismissal| {
        game.jump_requested = true;
        game.blueprint_tool.press.press(.key);
        try std.testing.expect(handleUIKeyPress(game, .{ .key = .b, .mods = .{} }));
        try std.testing.expect(game.blueprint_tool.chooser_open);
        try std.testing.expectEqual(.capture, game.blueprint_tool.mode);
        try std.testing.expectEqual(generation, game.blueprint_tool.selection.generation);
        try std.testing.expect(fixture.engine.gameplay_input_blocked and !fixture.engine.paused);
        try std.testing.expect(!game.jump_requested);
        try std.testing.expectEqual(null, game.blueprint_tool.press.requested);
        inline for (.{ zglfw.Key.m, .z, .enter, .e, .space }) |key| try std.testing.expect(handleUIKeyPress(game, .{ .key = key, .mods = .{} }));
        try std.testing.expect(handleUIKeyPress(game, .{ .key = .b, .mods = .{ .control = true } }));
        handleMouseButtonPress(game, .{ .button = .left, .mods = .{} });
        game.confirmBlueprintTool();
        game.setOverlay(.world_map);
        try std.testing.expectEqual(.none, game.overlay);
        try std.testing.expectEqual(.anchor, game.blueprint_tool.selection.stage);
        try std.testing.expectEqual(null, game.blueprint_tool.selection.bounds);
        try std.testing.expectEqual(null, game.blueprint_tool.press.requested);
        switch (dismissal) {
            .button => game.cancelBlueprintChooser(), // Same action as the dialog's Cancel.
            .escape => try std.testing.expect(handleUIKeyPress(game, .{ .key = .escape, .mods = .{} })),
            .hotkey => try std.testing.expect(handleUIKeyPress(game, .{ .key = .b, .mods = .{} })),
        }
        try std.testing.expect(!game.blueprint_tool.chooser_open);
        try std.testing.expectEqual(.capture, game.blueprint_tool.mode);
        try std.testing.expectEqual(.player, game.control_mode);
        try std.testing.expectEqual(generation, game.blueprint_tool.selection.generation);
        try std.testing.expect(!fixture.engine.gameplay_input_blocked and !fixture.engine.paused);
    }
    game.confirmBlueprintTool();
    try std.testing.expectEqual(.xy, game.blueprint_tool.selection.stage);
    try std.testing.expect(handleUIKeyPress(game, .{ .key = .b, .mods = .{} }));
    try std.testing.expect(!game.blueprint_tool.chooser_open);
    try std.testing.expectEqual(.xy, game.blueprint_tool.selection.stage);
    game.discardBlueprintDraft();
    try std.testing.expect(handleUIKeyPress(game, .{ .key = .b, .mods = .{} }));
    game.selectBlueprint(saved.id);
    try std.testing.expect(!game.blueprint_tool.chooser_open);
    try std.testing.expectEqual(.preview, game.blueprint_tool.mode);
    try std.testing.expectEqual(.player, game.control_mode);
    try std.testing.expectEqual(saved.id, game.blueprint_tool.preview.?.definition_id);
    try std.testing.expect(game.blueprint_tool.preview.?.generation > 0);
    try std.testing.expect(!fixture.engine.gameplay_input_blocked and !fixture.engine.paused);
    game.updateBlueprintTool();
    try std.testing.expect(game.blueprint_tool.preview.?.origin != null);
    try std.testing.expect(handleUIKeyPress(game, .{ .key = .escape, .mods = .{} }));
    try std.testing.expectEqual(.none, game.blueprint_tool.mode);
    try std.testing.expect(handleUIKeyPress(game, .{ .key = .b, .mods = .{} }));
    game.cancelBlueprintChooser();
    try std.testing.expectEqual(.none, game.blueprint_tool.mode);
}

test "Escape opens the game menu before capture starts and after discarding a selection" {
    var fixture: StreamingTest = .{};
    fixture.init();
    defer fixture.deinit();
    const game = &fixture.game;
    inline for (.{ true, false }) |menu_pauses_game| {
        game.menu_pauses_game = menu_pauses_game;
        try std.testing.expect(handleUIKeyPress(game, .{ .key = .z, .mods = .{} }));
        game.blueprint_tool.press.press(.key);
        try std.testing.expect(handleUIKeyPress(game, .{ .key = .escape, .mods = .{} }));
        try std.testing.expectEqual(.menu, game.overlay);
        try std.testing.expectEqual(.none, game.blueprint_tool.mode);
        try std.testing.expectEqual(null, game.blueprint_tool.press.requested);
        try std.testing.expect(fixture.engine.gameplay_input_blocked);
        try std.testing.expectEqual(menu_pauses_game, fixture.engine.paused);
        try std.testing.expect(handleUIKeyPress(game, .{ .key = .escape, .mods = .{} }));
        try std.testing.expectEqual(.none, game.overlay);
        try std.testing.expect(!fixture.engine.gameplay_input_blocked and !fixture.engine.paused);

        try std.testing.expect(handleUIKeyPress(game, .{ .key = .z, .mods = .{} }));
        game.blueprint_tool.selection.setAnchor(game.layout(), StreamingTest.toolTarget(), fixture.camera.position);
        try std.testing.expect(handleUIKeyPress(game, .{ .key = .escape, .mods = .{} }));
        try std.testing.expectEqual(.capture, game.blueprint_tool.mode);
        try std.testing.expectEqual(.anchor, game.blueprint_tool.selection.stage);
        try std.testing.expectEqual(null, game.blueprint_tool.selection.bounds);
        try std.testing.expectEqual(.none, game.overlay);
        try std.testing.expect(!fixture.engine.gameplay_input_blocked and !fixture.engine.paused);
        try std.testing.expect(handleUIKeyPress(game, .{ .key = .escape, .mods = .{} }));
        try std.testing.expectEqual(.menu, game.overlay);
        try std.testing.expectEqual(.none, game.blueprint_tool.mode);
        try std.testing.expect(handleUIKeyPress(game, .{ .key = .escape, .mods = .{} }));
    }
}

test "opening blueprint name entry with held Enter waits for release before accepting another Enter" {
    zgui.init(std.testing.allocator);
    defer zgui.deinit();
    zgui.io.setIniFilename(null);
    zgui.io.setBackendFlags(.{ .renderer_has_textures = true });
    zgui.io.setDisplaySize(1280, 720);
    _ = zgui.io.addFontFromFile("content/Roboto-Medium.ttf", 16);
    var fixture: StreamingTest = .{};
    fixture.init();
    defer fixture.deinit();
    const game = &fixture.game;
    inline for (.{ zglfw.Key.enter, .kp_enter }) |key| {
        const gui_key: zgui.Key = if (key == .enter) .enter else .keypad_enter;
        game.enterBlueprintCapture();
        const compiled = try blueprint.compile(std.testing.allocator, .{ .size = .{ 1, 1, 1 }, .cells = &.{.dirt} }, .{ .horizontal_limit = blueprint.horizontalLimit(game.layout()) });
        game.blueprint_tool.candidate = compiled.valid;
        game.blueprint_tool.selection.stage = .ready;
        try std.testing.expect(handleUIKeyPress(game, .{ .key = key, .mods = .{} }));
        zgui.io.addKeyEvent(gui_key, true);
        // Holding the opening press beyond ImGui's repeat delay must not submit.
        for (0..30) |_| {
            zgui.newFrame();
            game.drawBlueprintUI();
            zgui.render();
            try std.testing.expectEqual(blueprint_capture.Stage.naming, game.blueprint_tool.selection.stage);
            try std.testing.expectEqual(null, game.blueprint_tool.error_message);
        }
        zgui.io.addKeyEvent(gui_key, false);
        for (0..2) |_| {
            zgui.newFrame();
            game.drawBlueprintUI();
            zgui.render();
        }
        try std.testing.expect(!game.blueprint_tool.name_focus);
        zgui.io.addKeyEvent(gui_key, true);
        zgui.newFrame();
        game.drawBlueprintUI();
        zgui.render();
        // A separate Enter now submits the name through the dialog normally.
        try std.testing.expectEqualStrings("Enter a nonempty blueprint name.", game.blueprint_tool.error_message.?);
        zgui.io.addKeyEvent(gui_key, false);
        game.leaveBlueprintTool();
        zgui.newFrame();
        zgui.render();
    }
}

test "late blueprint save and apply results cannot reset a newer tool or close map" {
    var fixture: StreamingTest = .{};
    fixture.init();
    defer fixture.deinit();
    const game = &fixture.game;
    game.enterBlueprintCapture();
    const old_generation = game.blueprint_tool.selection.generation;
    game.blueprint_tool.save = .{ .request_id = 77, .generation = old_generation };
    game.discardBlueprintDraft();
    const current_generation = game.blueprint_tool.selection.generation;
    game.acceptBlueprintResult(.{ .request_id = 77, .kind = .save, .status = .success });
    try std.testing.expectEqual(current_generation, game.blueprint_tool.selection.generation);
    try std.testing.expectEqual(.capture, game.blueprint_tool.mode);
    try std.testing.expectEqual(null, game.blueprint_tool.save);
    game.blueprint_tool.apply = .{ .request_id = 78, .generation = 10 };
    game.leaveBlueprintTool();
    game.setOverlay(.world_map);
    game.acceptBlueprintResult(.{ .request_id = 78, .kind = .apply, .status = .success });
    try std.testing.expectEqual(.world_map, game.overlay);
    try std.testing.expectEqual(.none, game.blueprint_tool.mode);
    try std.testing.expectEqual(null, game.blueprint_tool.apply);
    try std.testing.expect(game.blueprint_tool.status != null);
}

test "terminal blueprint save rejection retains its error and allows capture restart" {
    for ([_]@FieldType(world_data_service.BlueprintResult, "status"){ .resource_exhausted, .invalid }) |status| {
        var fixture: StreamingTest = .{};
        fixture.init();
        defer fixture.deinit();
        const game = &fixture.game;
        game.enterBlueprintCapture();
        game.blueprint_tool.selection.anchor = .{ 1, 1, 5 };
        game.blueprint_tool.selection.bounds = .{ .min = .{ 1, 1, 5 }, .max = .{ 2, 1, 5 } };
        // Successful submission has transferred the candidate and left no helper job.
        game.blueprint_tool.selection.stage = .validating;
        const selection = game.blueprint_tool.selection;
        game.blueprint_tool.save = .{ .request_id = 77, .generation = selection.generation };
        game.blueprint_tool.setStatus(game.engine.real_time, "Saving blueprint...", math.inf(f64));
        // An unrelated response must not end the tracked save or change its draft.
        game.acceptBlueprintResult(.{ .request_id = 76, .kind = .save, .status = status });
        try std.testing.expectEqual(@as(u64, 77), game.blueprint_tool.save.?.request_id);
        try std.testing.expectEqualDeep(selection, game.blueprint_tool.selection);
        try std.testing.expectEqual(null, game.blueprint_tool.error_message);
        try game.blueprint_tool.results.append(std.testing.allocator, .{ .request_id = 77, .kind = .save, .status = status });
        game.resolveBlueprintResults();
        const message = if (status == .resource_exhausted) "Blueprint library capacity was reached; this blueprint was not saved." else "Blueprint save was rejected; no blueprint was published.";
        try std.testing.expectEqual(@as(usize, 0), game.blueprint_tool.results.items.len);
        try std.testing.expectEqual(null, game.blueprint_tool.save);
        try std.testing.expectEqual(null, game.blueprint_tool.candidate);
        try std.testing.expectEqual(null, game.blueprint_tool.helper);
        try std.testing.expectEqual(blueprint_capture.Stage.invalid, game.blueprint_tool.selection.stage);
        try std.testing.expectEqual(selection.generation, game.blueprint_tool.selection.generation);
        try std.testing.expectEqualDeep(selection.bounds, game.blueprint_tool.selection.bounds);
        try std.testing.expectEqual(.capture, game.blueprint_tool.mode);
        try std.testing.expectEqualStrings(message, game.blueprint_tool.error_message.?);
        try std.testing.expect(!fixture.engine.gameplay_input_blocked and !fixture.engine.paused);
        fixture.engine.real_time += block_messages.action_error_duration;
        try std.testing.expectEqual(null, game.blueprint_tool.statusMessage(game.engine.real_time));
        game.updateBlueprintTool();
        try std.testing.expectEqual(blueprint_capture.Stage.invalid, game.blueprint_tool.selection.stage);
        try std.testing.expectEqualStrings(message, game.blueprint_tool.error_message.?);
        // A duplicate completion cannot erase the persistent failure or reset the tool.
        game.acceptBlueprintResult(.{ .request_id = 77, .kind = .save, .status = .success });
        try std.testing.expectEqual(blueprint_capture.Stage.invalid, game.blueprint_tool.selection.stage);
        try std.testing.expectEqualStrings(message, game.blueprint_tool.error_message.?);
        try std.testing.expect(handleUIKeyPress(game, .{ .key = .escape, .mods = .{} }));
        try std.testing.expectEqual(.capture, game.blueprint_tool.mode);
        try std.testing.expectEqual(.none, game.overlay);
        try std.testing.expectEqual(blueprint_capture.Stage.anchor, game.blueprint_tool.selection.stage);
        try std.testing.expect(game.blueprint_tool.selection.generation != selection.generation);
        try std.testing.expectEqual(null, game.blueprint_tool.selection.anchor);
        try std.testing.expectEqual(null, game.blueprint_tool.selection.bounds);
        try std.testing.expectEqual(null, game.blueprint_tool.error_message);
    }
}

test "late rejected blueprint saves preserve a newer name dialog and unrelated overlays" {
    for ([_]@FieldType(world_data_service.BlueprintResult, "status"){ .resource_exhausted, .invalid }) |status| {
        var fixture: StreamingTest = .{};
        fixture.init();
        defer fixture.deinit();
        const game = &fixture.game;
        game.enterBlueprintCapture();
        game.blueprint_tool.save = .{ .request_id = 77, .generation = game.blueprint_tool.selection.generation };
        game.discardBlueprintDraft();
        const compiled = try blueprint.compile(std.testing.allocator, .{ .size = .{ 1, 1, 1 }, .cells = &.{.dirt} }, .{ .horizontal_limit = blueprint.horizontalLimit(game.layout()) });
        game.blueprint_tool.candidate = compiled.valid;
        game.blueprint_tool.selection.stage = .naming;
        @memcpy(game.blueprint_tool.name[0..9], "New draft");
        game.blueprint_tool.error_message = "Keep this dialog error.";
        game.updateBlueprintInputBlock();
        const selection = game.blueprint_tool.selection;
        const name = game.blueprint_tool.name;
        const cells = game.blueprint_tool.candidate.?.definition.cells.ptr;
        game.acceptBlueprintResult(.{ .request_id = 77, .kind = .save, .status = status });
        try std.testing.expectEqual(null, game.blueprint_tool.save);
        try std.testing.expectEqualDeep(selection, game.blueprint_tool.selection);
        try std.testing.expectEqual(.capture, game.blueprint_tool.mode);
        try std.testing.expectEqualSlices(u8, &name, &game.blueprint_tool.name);
        try std.testing.expectEqual(cells, game.blueprint_tool.candidate.?.definition.cells.ptr);
        try std.testing.expectEqualStrings("Keep this dialog error.", game.blueprint_tool.error_message.?);
        try std.testing.expect(fixture.engine.gameplay_input_blocked);

        game.blueprint_tool.save = .{ .request_id = 78, .generation = selection.generation };
        game.leaveBlueprintTool();
        game.setOverlay(.world_map);
        game.acceptBlueprintResult(.{ .request_id = 78, .kind = .save, .status = status });
        try std.testing.expectEqual(null, game.blueprint_tool.save);
        try std.testing.expectEqual(.none, game.blueprint_tool.mode);
        try std.testing.expectEqual(.world_map, game.overlay);
        try std.testing.expectEqual(blueprint_capture.Stage.anchor, game.blueprint_tool.selection.stage);
        try std.testing.expectEqual(null, game.blueprint_tool.error_message);
        try std.testing.expect(fixture.engine.gameplay_input_blocked);
    }
}

test "client capture pins full source chunks and freezes optimistic view before helper" {
    var fixture: StreamingTest = .{};
    fixture.init();
    defer fixture.deinit();
    const game = &fixture.game;
    const block = StreamingTest.toolTarget();
    const coords, _ = world_module.splitBlockCoords(block);
    try game.world.?.insertChunk(coords, WorldChunk.initEmpty());
    game.world.?.setBlockUnchecked(block, .stone);
    game.blueprint_tool.mode = .capture;
    game.blueprint_tool.selection.bounds = .{ .min = .{ block[0], block[1], block[2] }, .max = .{ block[0], block[1], block[2] } };
    game.blueprint_tool.selection.stage = .loading;
    game.prepareBlueprintSource();
    try std.testing.expectEqual(@as(usize, 1), game.blueprint_tool.source_chunks.items.len);
    game.refreshPinnedChunks();
    try std.testing.expect(game.pinned_chunks.contains(game.layout().encodeChunkCoords(coords)));
    game.updateBlueprintTool();
    try std.testing.expectEqual(blueprint_capture.Stage.validating, game.blueprint_tool.selection.stage);
    try std.testing.expectEqual(@as(usize, 0), game.blueprint_tool.source_chunks.items.len);
    game.world.?.setBlockUnchecked(block, .sand);
    while (game.blueprint_tool.selection.stage == .validating) {
        game.updateBlueprintTool();
        std.Thread.yield() catch {};
    }
    try std.testing.expectEqual(blueprint_capture.Stage.ready, game.blueprint_tool.selection.stage);
    try std.testing.expectEqual(voxel_chunk_module.BlockType.crushed_stone, game.blueprint_tool.candidate.?.definition.cells[0]);
    try std.testing.expectEqual(@as(usize, 1), game.blueprint_tool.snapshot_bytes);
}

test "reference capture copies 320000 predicted cells with fifty retained source chunks" {
    const layout = try WorldLayout.init(.{ .size_in_chunks = .{ 8, 8, 4 } });
    var fixture: StreamingTest = .{};
    fixture.initWithLayout(&layout);
    defer fixture.deinit();
    const game = &fixture.game;
    game.blueprint_tool.mode = .capture;
    game.blueprint_tool.selection.bounds = .{ .min = .{ 31, 31, 31 }, .max = .{ 130, 130, 62 } };
    game.blueprint_tool.selection.stage = .loading;
    game.prepareBlueprintSource();
    try std.testing.expectEqual(@as(usize, 50), game.blueprint_tool.source_chunks.items.len);
    for (game.blueprint_tool.source_chunks.items) |id| try game.world.?.insertChunk(layout.decodeChunkId(id), WorldChunk.initEmpty());
    game.world.?.setBlockUnchecked(.{ 31, 31, 31 }, .stone);
    game.updateBlueprintTool();
    try std.testing.expectEqual(blueprint_capture.Stage.validating, game.blueprint_tool.selection.stage);
    try std.testing.expectEqual(@as(usize, 320_000), game.blueprint_tool.snapshot_bytes);
    try std.testing.expectEqual(@as(usize, 50), game.blueprint_tool.source_peak);
    try std.testing.expectEqual(@as(usize, 0), game.blueprint_tool.source_chunks.items.len);
    while (game.blueprint_tool.selection.stage == .validating) {
        game.updateBlueprintTool();
        std.Thread.yield() catch {};
    }
    try std.testing.expectEqual(blueprint_capture.Stage.ready, game.blueprint_tool.selection.stage);
    std.debug.print("blueprint client reference: cells=320000 source_chunks=50 one_pass_copy_ms={d:.3} snapshot_bytes={d} mode={s}\n", .{ @as(f64, @floatFromInt(game.blueprint_tool.copy_ns)) / std.time.ns_per_ms, game.blueprint_tool.snapshot_bytes, @tagName(@import("builtin").mode) });
}

test "blueprint success waits for matching authoritative package publication" {
    var fixture: StreamingTest = .{};
    fixture.init();
    defer fixture.deinit();
    const game = &fixture.game;
    game.enterBlueprintCapture();
    game.blueprint_tool.selection.stage = .validating;
    game.blueprint_tool.save = .{ .request_id = 77, .generation = game.blueprint_tool.selection.generation };
    try game.blueprint_tool.results.append(std.testing.allocator, .{ .request_id = 77, .kind = .save, .status = .success, .definition_id = 41 });
    game.resolveBlueprintResults();
    try std.testing.expectEqual(@as(usize, 1), game.blueprint_tool.results.items.len);
    try std.testing.expect(game.blueprint_tool.save != null);
    try std.testing.expectEqual(blueprint_capture.Stage.validating, game.blueprint_tool.selection.stage);
    const runtime = @import("blueprint_runtime.zig");
    var definition: runtime.SavedDefinition = .{ .id = 41, .owner = 1, .name = try std.testing.allocator.dupe(u8, "Ordered"), .definition = .{ .size = .{ 1, 1, 1 }, .cells = try std.testing.allocator.dupe(voxel_chunk_module.BlockType, &.{.dirt}), .target_count = 1 } };
    defer definition.deinit(std.testing.allocator);
    try game.world.?.applyBlueprintChanges(&.{.{ .definition = definition }});
    game.resolveBlueprintResults();
    try std.testing.expectEqual(@as(usize, 0), game.blueprint_tool.results.items.len);
    try std.testing.expectEqual(null, game.blueprint_tool.save);
    try std.testing.expectEqual(blueprint_capture.Stage.anchor, game.blueprint_tool.selection.stage);

    game.blueprint_tool.mode = .preview;
    game.blueprint_tool.preview = .{ .definition_id = 41, .generation = 10 };
    game.blueprint_tool.apply = .{ .request_id = 78, .generation = 10 };
    try game.blueprint_tool.results.append(std.testing.allocator, .{ .request_id = 78, .kind = .apply, .status = .success, .definition_id = 41, .instance_id = 45 });
    game.resolveBlueprintResults();
    try std.testing.expectEqual(@as(usize, 1), game.blueprint_tool.results.items.len);
    try std.testing.expectEqual(.preview, game.blueprint_tool.mode);
    var instance = try game.world.?.blueprints.prepareInstance(std.testing.allocator, game.layout(), 45, 41, 1, .{ 3, 3, 3 }, 0);
    defer instance.deinit(std.testing.allocator);
    try game.world.?.applyBlueprintChanges(&.{.{ .instance = instance }});
    game.resolveBlueprintResults();
    try std.testing.expectEqual(@as(usize, 0), game.blueprint_tool.results.items.len);
    try std.testing.expectEqual(null, game.blueprint_tool.apply);
    try std.testing.expectEqual(.none, game.blueprint_tool.mode);
}

test "quick blueprint key and mouse presses survive release before the next frame" {
    var fixture: StreamingTest = .{};
    fixture.init();
    defer fixture.deinit();
    const game = &fixture.game;
    game.enterBlueprintCapture();
    try std.testing.expect(handleUIKeyPress(game, .{ .key = .e, .mods = .{} }));
    handleKeyRelease(game, .{ .key = .e, .mods = .{} });
    try std.testing.expectEqual(BlueprintTool.Press.Source.key, game.blueprint_tool.press.requested.?);
    try std.testing.expect(!game.blueprint_tool.press.key_down);
    game.blueprint_tool.press.requested = null;
    handleMouseButtonPress(game, .{ .button = .left, .mods = .{} });
    handleMouseButtonRelease(game, .{ .button = .left, .mods = .{} });
    try std.testing.expectEqual(BlueprintTool.Press.Source.mouse, game.blueprint_tool.press.requested.?);
    try std.testing.expect(!game.blueprint_tool.press.mouse_down);
    game.discardBlueprintDraft();
    try std.testing.expectEqual(null, game.blueprint_tool.press.requested);
}

test "pending target placement preview uses the dedicated fulfillment identity" {
    var fixture: StreamingTest = .{};
    fixture.init();
    defer fixture.deinit();
    try fixture.prepareSupportedToolTest();
    const game = &fixture.game;
    const target = StreamingTest.toolTarget();
    const pending_cell = [3]u32{ target[0], target[1] - 1, target[2] };
    const runtime = @import("blueprint_runtime.zig");
    var definition: runtime.SavedDefinition = .{ .id = 1, .owner = 1, .name = try std.testing.allocator.dupe(u8, "Preview"), .definition = .{ .size = .{ 1, 1, 1 }, .cells = try std.testing.allocator.dupe(voxel_chunk_module.BlockType, &.{.planks}), .target_count = 1 } };
    defer definition.deinit(std.testing.allocator);
    try game.world.?.applyBlueprintChanges(&.{.{ .definition = definition }});
    var instance = try game.world.?.blueprints.prepareInstance(std.testing.allocator, game.layout(), 1, 1, 1, pending_cell, 0);
    defer instance.deinit(std.testing.allocator);
    try game.world.?.applyBlueprintChanges(&.{.{ .instance = instance }});
    var ordinary_calls: usize = 0;
    game.world.?.ordinary_preview_counter = &ordinary_calls;
    game.block_mode = .putting;
    game.selected_material = .planks;
    game.updateBlockFocus();
    try std.testing.expectEqualDeep(pending_cell, game.current_placement_preview.?.block);
    try std.testing.expectEqual(world_module.OperationStatus.success, game.current_placement_preview.?.result.status);
    try std.testing.expectEqual(@as(usize, 0), ordinary_calls);
    game.selected_material = .sand;
    game.updateBlockFocus();
    try std.testing.expectEqual(world_module.OperationStatus.inventory_mismatch, game.current_placement_preview.?.result.status);
    try std.testing.expectEqual(@as(usize, 0), ordinary_calls);
}

test "blueprint rejection highlights the failed destination and clears on retarget or rotation" {
    const a = std.testing.allocator;
    var fixture: StreamingTest = .{};
    fixture.init();
    defer fixture.deinit();
    const game = &fixture.game;
    const runtime = @import("blueprint_runtime.zig");
    const origin = @import("block_coordinates.zig").fromWorld(&test_layout, .{ 8, 8, 1 }).?;
    var saved: runtime.SavedDefinition = .{ .id = 1, .owner = game.player_id, .name = try a.dupe(u8, "Rejected"), .definition = .{ .size = .{ 1, 1, 1 }, .cells = try a.dupe(voxel_chunk_module.BlockType, &.{.planks}), .target_count = 1 } };
    defer saved.deinit(a);
    try game.world.?.applyBlueprintChanges(&.{.{ .definition = saved }});
    game.blueprint_tool.mode = .preview;
    game.blueprint_tool.preview = .{ .definition_id = 1, .generation = 10, .origin = origin };
    game.blueprint_tool.apply = .{ .request_id = 77, .generation = 10 };
    const rejection: world_data_service.BlueprintRejection = .{ .code = .occupied, .cell = origin };
    game.acceptBlueprintResult(.{ .request_id = 77, .kind = .apply, .status = .invalid, .rejection = rejection });
    try std.testing.expectEqual(null, game.blueprint_tool.apply);
    try std.testing.expectEqualDeep(rejection, game.blueprint_tool.preview.?.rejection.?);
    try std.testing.expectEqualStrings("A required blueprint cell is already occupied. Clear it or move the blueprint.", game.blueprint_tool.error_message.?);
    fixture.engine.real_time += block_messages.action_error_duration;
    try std.testing.expectEqual(null, game.blueprint_tool.statusMessage(game.engine.real_time));
    try std.testing.expect(game.blueprint_tool.error_message != null);
    game.buildBlueprintRenderInstances();
    try std.testing.expectEqual(@as(usize, 13), game.blueprint_render_instances.items.len);
    const marker = game.blueprint_render_instances.items[12];
    const block = blueprint_renderer.blockInstance(&fixture.camera, .{ origin[0], origin[1], origin[2] }, .planks, false, false);
    try std.testing.expectEqual(@as(u32, 2), marker.material[1]);
    inline for (0..3) |axis| {
        try std.testing.expect(marker.position[axis] < block.position[axis]);
        try std.testing.expect(marker.position[axis] + marker.scale[axis] > block.position[axis] + block.scale[axis]);
    }
    game.blueprint_tool.updatePreviewOrigin(origin);
    try std.testing.expect(game.blueprint_tool.preview.?.rejection != null);
    try std.testing.expect(handleUIKeyPress(game, .{ .key = .r, .mods = .{} }));
    try std.testing.expectEqual(@as(u2, 1), game.blueprint_tool.preview.?.rotation);
    try std.testing.expectEqual(null, game.blueprint_tool.preview.?.rejection);
    try std.testing.expectEqual(null, game.blueprint_tool.error_message);
    game.blueprint_tool.preview.?.rejection = rejection;
    game.blueprint_tool.updatePreviewOrigin(null);
    game.buildBlueprintRenderInstances();
    try std.testing.expectEqual(null, game.blueprint_tool.preview.?.rejection);
    try std.testing.expectEqual(@as(usize, 0), game.blueprint_render_instances.items.len);
}

test "blueprint dialogs hide the crosshair and chooser has a DPI-scaled width floor" {
    zgui.init(std.testing.allocator);
    defer zgui.deinit();
    zgui.io.setIniFilename(null);
    zgui.io.setBackendFlags(.{ .renderer_has_textures = true });
    _ = zgui.io.addFontFromFile("content/Roboto-Medium.ttf", 16);
    var dpi = zgui_utils.DpiScaling.init();
    var fixture: StreamingTest = .{};
    fixture.init();
    defer fixture.deinit();
    const game = &fixture.game;

    for ([_]f32{ 1, 2 }) |scale| {
        dpi.update(.{ scale, scale });
        zgui.io.setDisplaySize(1280 * scale, 720 * scale);
        for ([_]struct { mode: @FieldType(BlueprintTool, "mode"), naming: bool = false, chooser: bool = false }{
            .{ .mode = .capture, .naming = true },
            .{ .mode = .none, .chooser = true },
            .{ .mode = .capture, .chooser = true },
            .{ .mode = .capture },
            .{ .mode = .preview },
            .{ .mode = .none },
        }) |state| {
            game.blueprint_tool.mode = state.mode;
            game.blueprint_tool.chooser_open = state.chooser;
            game.blueprint_tool.selection.stage = if (state.naming) .naming else .anchor;
            game.updateBlueprintInputBlock();
            // Auto-sized windows settle after their first content measurement.
            for (0..2) |frame| {
                zgui.newFrame();
                onRender(&fixture.engine, undefined, game);
                try std.testing.expectEqual(!game.blueprint_tool.controlsBlocked(), zgui.getForegroundDrawList().getVertexBuffer().len > 0);
                if (state.chooser and frame > 0) {
                    _ = zgui.begin("Choose a blueprint", .{});
                    try std.testing.expect(zgui.getWindowSize()[0] >= 300 * scale);
                    zgui.end();
                }
                zgui.render();
            }
        }
    }
}

test "blueprint choice buttons render embedded and leading hashes literally" {
    zgui.init(std.testing.allocator);
    defer zgui.deinit();
    zgui.io.setIniFilename(null);
    zgui.io.setBackendFlags(.{ .renderer_has_textures = true });
    _ = zgui.io.addFontFromFile("content/Roboto-Medium.ttf", 16);
    var dpi = zgui_utils.DpiScaling.init();

    for ([_]f32{ 1, 2 }) |scale| {
        dpi.update(.{ scale, scale });
        zgui.io.setDisplaySize(1280 * scale, 720 * scale);
        // The second frame also checks that literal text follows style opacity.
        for ([_]f32{ 1, 0.6 }) |alpha| {
            zgui.getStyle().alpha = alpha;
            zgui.newFrame();
            zgui.setNextWindowPos(.{ .x = 20, .y = 20 });
            zgui.setNextWindowSize(.{ .w = 600 * scale, .h = 320 * scale });
            _ = zgui.begin("Literal blueprint names", .{ .flags = .{ .no_title_bar = true, .no_saved_settings = true } });
            const list = zgui.getWindowDrawList();
            const style = zgui.getStyle();
            var text_color = style.getColor(.text);
            text_color[3] *= style.alpha;
            const color = zgui.colorConvertFloat4ToU32(text_color);
            for ([_][]const u8{ "House", "House##west", "##Tower", "House###west", "###" }, 1..) |name, id| {
                try std.testing.expectEqualStrings(name, try blueprint_capture.checkedName(name));
                const start = list.getVertexBuffer().len;
                _ = Game.blueprintChoiceButton(id, name);
                var text_vertices: usize = 0;
                for (list.getVertexBuffer()[start..]) |vertex| {
                    if (vertex.color == color) text_vertices += 1;
                }
                // Every non-space ASCII glyph contributes a quad. Truncated names
                // and accidentally visible hidden IDs produce a different count.
                try std.testing.expectEqual(4 * name.len, text_vertices);
                const min = zgui.getItemRectMin();
                const max = zgui.getItemRectMax();
                const text_size = zgui.calcTextSize(name, .{});
                try std.testing.expectApproxEqAbs(text_size[0] + 2 * style.frame_padding[0], max[0] - min[0], 0.01);
            }
            zgui.end();
            zgui.render();
        }
    }
}

test "blueprint choice buttons keep duplicate names and full-width IDs distinct" {
    zgui.init(std.testing.allocator);
    defer zgui.deinit();
    zgui.io.setIniFilename(null);
    zgui.io.setBackendFlags(.{ .renderer_has_textures = true });
    zgui.io.setDisplaySize(1280, 720);
    _ = zgui.io.addFontFromFile("content/Roboto-Medium.ttf", 16);
    var fixture: StreamingTest = .{};
    fixture.init();
    defer fixture.deinit();
    const game = &fixture.game;
    const ids = [_]u64{ 1, 1 + (@as(u64, 1) << 32) };
    for (ids) |id| {
        var saved: @import("blueprint_runtime.zig").SavedDefinition = .{
            .id = id,
            .owner = game.player_id,
            .name = try std.testing.allocator.dupe(u8, "House##west"),
            .definition = .{ .size = .{ 1, 1, 1 }, .cells = try std.testing.allocator.dupe(voxel_chunk_module.BlockType, &.{.dirt}), .target_count = 1 },
        };
        defer saved.deinit(std.testing.allocator);
        try game.world.?.blueprints.insertDefinition(std.testing.allocator, try saved.clone(std.testing.allocator));
    }
    game.blueprint_tool.chooser_open = true;
    var second_center: [2]f32 = undefined;
    var presses: usize = 0;
    // Settle layout, move the mouse, then press and release on the second item.
    for (0..5) |frame| {
        if (frame == 2) zgui.io.addMousePositionEvent(second_center[0], second_center[1]);
        if (frame == 3) zgui.io.addMouseButtonEvent(.left, true);
        if (frame == 4) zgui.io.addMouseButtonEvent(.left, false);
        zgui.newFrame();
        zgui.setNextWindowPos(.{ .x = 20, .y = 20 });
        zgui.setNextWindowSize(.{ .w = 600, .h = 320 });
        _ = zgui.begin("Blueprint identity", .{ .flags = .{ .no_title_bar = true, .no_saved_settings = true } });
        for (ids) |id| {
            if (Game.blueprintChoiceButton(id, "House##west")) {
                presses += 1;
                game.selectBlueprint(id);
            }
            if (id == ids[1]) {
                const min = zgui.getItemRectMin();
                const max = zgui.getItemRectMax();
                second_center = .{ (min[0] + max[0]) / 2, (min[1] + max[1]) / 2 };
            }
        }
        zgui.end();
        zgui.render();
    }
    try std.testing.expectEqual(@as(usize, 1), presses);
    try std.testing.expectEqual(.preview, game.blueprint_tool.mode);
    try std.testing.expectEqual(ids[1], game.blueprint_tool.preview.?.definition_id);
}

test "occluded capture frame selects only its own rails among site and preview instances" {
    var fixture: StreamingTest = .{};
    fixture.init();
    defer fixture.deinit();
    const game = &fixture.game;
    fixture.camera.updatePosition(.{ 0, 0, 0 });
    try game.world.?.insertChunk(test_layout.origin_chunk, WorldChunk.initEmpty());
    try game.loaded_chunk_ids.put(std.testing.allocator, test_layout.encodeChunkCoords(test_layout.origin_chunk), {});
    const runtime = @import("blueprint_runtime.zig");
    const coordinates = @import("block_coordinates.zig");
    var saved: runtime.SavedDefinition = .{ .id = 1, .owner = game.player_id, .name = try std.testing.allocator.dupe(u8, "Frame"), .definition = .{ .size = .{ 1, 1, 1 }, .cells = try std.testing.allocator.dupe(voxel_chunk_module.BlockType, &.{.dirt}), .target_count = 1 } };
    defer saved.deinit(std.testing.allocator);
    try game.world.?.applyBlueprintChanges(&.{.{ .definition = saved }});
    const origin = coordinates.fromWorld(&test_layout, .{ 8, 8, 1 }).?;
    var site = try game.world.?.blueprints.prepareInstance(std.testing.allocator, game.layout(), 1, 1, game.player_id, origin, 0);
    defer site.deinit(std.testing.allocator);
    try game.world.?.applyBlueprintChanges(&.{.{ .instance = site }});

    game.enterBlueprintCapture();
    game.blueprint_tool.selection.setAnchor(game.layout(), coordinates.fromWorld(&test_layout, .{ 0, 0, 1 }).?, fixture.camera.position);
    game.buildBlueprintRenderInstances();
    // Cached miniatures are separate; the site rails precede the capture rails.
    try std.testing.expectEqual(@as(usize, 24), game.blueprint_render_instances.items.len);
    try std.testing.expectEqual(@as(?u32, 12), game.blueprint_selection_frame_start);
    for (game.blueprint_render_instances.items[12..]) |rail| try std.testing.expectEqual(@as(u32, 1), rail.material[1]);

    game.leaveBlueprintTool();
    game.buildBlueprintRenderInstances();
    try std.testing.expectEqual(@as(usize, 12), game.blueprint_render_instances.items.len);
    try std.testing.expectEqual(null, game.blueprint_selection_frame_start);
    game.blueprint_tool.mode = .preview;
    game.blueprint_tool.preview = .{ .definition_id = saved.id, .origin = origin, .generation = 1 };
    game.buildBlueprintRenderInstances();
    try std.testing.expectEqual(@as(usize, 24), game.blueprint_render_instances.items.len);
    try std.testing.expectEqual(saved.id, game.blueprint_render_preview.?.definition_id);
    try std.testing.expectEqual(null, game.blueprint_selection_frame_start);
}

test "large blueprint preview collection borrows local geometry and keeps only dynamic rails" {
    var fixture: StreamingTest = .{};
    fixture.init();
    defer fixture.deinit();
    const game = &fixture.game;
    const allocator = std.testing.allocator;
    var saved: @import("blueprint_runtime.zig").SavedDefinition = .{
        .id = 1,
        .owner = game.player_id,
        .name = try allocator.dupe(u8, "Dense preview"),
        .definition = .{ .size = .{ 100, 100, 32 }, .cells = try allocator.alloc(voxel_chunk_module.BlockType, 320_000), .target_count = 320_000 },
    };
    defer saved.deinit(allocator);
    @memset(@constCast(saved.definition.cells), .planks);
    try game.world.?.applyBlueprintChanges(&.{.{ .definition = saved }});
    const cells = game.world.?.blueprints.definitions.get(saved.id).?.definition.cells;
    game.blueprint_tool.mode = .preview;
    game.blueprint_tool.preview = .{ .definition_id = saved.id, .origin = .{ 31, 31, 31 }, .generation = 7 };
    for (0..4) |rotation| {
        game.blueprint_tool.preview.?.rotation = @intCast(rotation);
        game.blueprint_tool.preview.?.origin = .{ @as(u32, @intCast(rotation)) + 31, 31, 31 };
        fixture.camera.updatePosition(.{ @as(f64, @floatFromInt(rotation)) * 32, 0, 0 });
        game.buildBlueprintRenderInstances();
        const source = game.blueprint_render_preview.?;
        try std.testing.expectEqual(@as(usize, 12), game.blueprint_render_instances.items.len);
        try std.testing.expectEqual(cells.ptr, source.cells.ptr);
        try std.testing.expectEqual(@as(u32, 320_000), source.target_count);
        try std.testing.expectEqual(@as(u64, 7), source.generation);
        try std.testing.expectEqual(rotation, source.rotation);
        try std.testing.expectEqualDeep(game.blueprint_tool.preview.?.origin, source.origin);
        try std.testing.expectEqual(null, game.blueprint_selection_frame_start);
    }
    game.blueprint_tool.preview.?.origin = null;
    game.buildBlueprintRenderInstances();
    try std.testing.expectEqual(@as(usize, 0), game.blueprint_render_instances.items.len);
    try std.testing.expectEqual(null, game.blueprint_render_preview.?.origin);
    try std.testing.expectEqual(cells.ptr, game.blueprint_render_preview.?.cells.ptr);
    game.leaveBlueprintTool();
    try std.testing.expectEqual(null, game.blueprint_render_preview);
    game.buildBlueprintRenderInstances();
    try std.testing.expectEqual(null, game.blueprint_render_preview);
    try std.testing.expectEqual(@as(usize, 0), game.blueprint_render_instances.items.len);
}

test "capture previews an unconfirmed anchor at thirty metres and rechecks it on click" {
    var fixture: StreamingTest = .{};
    fixture.init();
    defer fixture.deinit();
    const game = &fixture.game;
    const coordinates = @import("block_coordinates.zig");
    try game.world.?.insertChunk(test_layout.origin_chunk, WorldChunk.initEmpty());
    try game.world.?.insertChunk(test_layout.origin_chunk - ChunkCoords{ 0, 1, 0 }, WorldChunk.initEmpty());
    try game.world.?.insertChunk(test_layout.origin_chunk + ChunkCoords{ 0, 1, 0 }, WorldChunk.initEmpty());
    fixture.camera.updatePosition(.{ 0, 0, 0 });
    const backing = coordinates.fromWorld(&test_layout, .{ 0, 31, 0 }).?;
    const target = coordinates.fromWorld(&test_layout, .{ 0, 30, 0 }).?;
    game.world.?.setBlockUnchecked(backing, .stone);
    try std.testing.expectEqual(null, try block_targeting.findTarget(&game.world.?, fixture.camera.position, fixture.camera.forwardDirection(), .putting));
    try std.testing.expect(handleUIKeyPress(game, .{ .key = .z, .mods = .{} }));
    game.buildBlueprintRenderInstances();
    try std.testing.expectEqual(@as(usize, 12), game.blueprint_render_instances.items.len);
    try std.testing.expectEqual(@as(?u32, 0), game.blueprint_selection_frame_start);
    // The frame surrounds the adjacent placement cell, not its backing block.
    try std.testing.expectApproxEqAbs(@as(f32, 30.0 - 0.035 / 2.0), game.blueprint_render_instances.items[0].position[1], 0.00001);
    try std.testing.expectEqual(.anchor, game.blueprint_tool.selection.stage);
    try std.testing.expectEqual(null, game.blueprint_tool.selection.anchor);
    try std.testing.expectEqual(null, game.blueprint_tool.selection.bounds);
    // Hovering has not started a selection: Escape still opens the menu.
    try std.testing.expect(handleUIKeyPress(game, .{ .key = .escape, .mods = .{} }));
    try std.testing.expectEqual(.menu, game.overlay);
    try std.testing.expect(handleUIKeyPress(game, .{ .key = .escape, .mods = .{} }));
    game.enterBlueprintCapture();

    fixture.camera.updatePosition(.{ 0, -0.000001, 0 });
    try std.testing.expectEqual(null, try block_targeting.findTargetWithReach(&game.world.?, fixture.camera.position, fixture.camera.forwardDirection(), .putting, 30));
    game.buildBlueprintRenderInstances();
    try std.testing.expectEqual(@as(usize, 0), game.blueprint_render_instances.items.len);
    try std.testing.expectEqual(null, game.blueprint_selection_frame_start);
    game.confirmBlueprintTool();
    try std.testing.expectEqual(.anchor, game.blueprint_tool.selection.stage);
    fixture.camera.updatePosition(.{ 0, 0, 0 });
    game.confirmBlueprintTool();
    try std.testing.expectEqual(.xy, game.blueprint_tool.selection.stage);
    try std.testing.expectEqualDeep(blueprint_capture.Cell{ target[0], target[1], target[2] }, game.blueprint_tool.selection.anchor.?);
    try std.testing.expectEqual([3]u32{ 1, 1, 1 }, game.blueprint_tool.selection.bounds.?.size());

    game.discardBlueprintDraft();
    game.buildBlueprintRenderInstances();
    try std.testing.expectEqual(@as(usize, 12), game.blueprint_render_instances.items.len);
    game.world.?.setBlockUnchecked(backing, .none);
    game.buildBlueprintRenderInstances();
    try std.testing.expectEqual(@as(usize, 0), game.blueprint_render_instances.items.len);
    game.confirmBlueprintTool();
    try std.testing.expectEqual(.anchor, game.blueprint_tool.selection.stage);
    game.world.?.setBlockUnchecked(backing, .stone);
    game.buildBlueprintRenderInstances();
    const nearer_backing = coordinates.fromWorld(&test_layout, .{ 0, 20, 0 }).?;
    const nearer_target = coordinates.fromWorld(&test_layout, .{ 0, 19, 0 }).?;
    game.world.?.setBlockUnchecked(nearer_backing, .stone);
    // Click before another render must use the new nearest target, not old preview.
    game.confirmBlueprintTool();
    try std.testing.expectEqualDeep(blueprint_capture.Cell{ nearer_target[0], nearer_target[1], nearer_target[2] }, game.blueprint_tool.selection.anchor.?);
}

test "same-height blueprint XY uses distant adjacent placement then absolute height" {
    var fixture: StreamingTest = .{};
    fixture.init();
    defer fixture.deinit();
    const game = &fixture.game;
    const coordinates = @import("block_coordinates.zig");
    try game.world.?.insertChunk(test_layout.origin_chunk, WorldChunk.initEmpty());
    try game.world.?.insertChunk(test_layout.origin_chunk + ChunkCoords{ 0, 1, 0 }, WorldChunk.initEmpty());
    game.player = PlayerController.init(std.testing.allocator, .{ 0.25, 0.25, 0 });
    game.player.?.applyCamera(&fixture.camera);
    game.enterBlueprintCapture();
    const anchor = coordinates.fromWorld(&test_layout, .{ 0, 0, 1 }).?;
    game.blueprint_tool.selection.setAnchor(&test_layout, anchor, fixture.camera.position);
    const first_backing = coordinates.fromWorld(&test_layout, .{ 0, 20, 1 }).?;
    game.world.?.setBlockUnchecked(first_backing, .stone);
    game.updateBlueprintRay();
    try std.testing.expect(game.blueprint_tool.selection.target_valid);
    try std.testing.expectEqual([3]u32{ 1, 20, 1 }, game.blueprint_tool.selection.bounds.?.size());
    try std.testing.expectEqual(null, try block_targeting.findTarget(&game.world.?, fixture.camera.position, fixture.camera.forwardDirection(), .putting));

    game.world.?.setBlockUnchecked(first_backing, .none);
    const distant_backing = coordinates.fromWorld(&test_layout, .{ 0, 30, 1 }).?;
    game.world.?.setBlockUnchecked(distant_backing, .stone);
    game.updateBlueprintRay();
    try std.testing.expect(game.blueprint_tool.selection.target_valid);
    try std.testing.expectEqual([3]u32{ 1, 30, 1 }, game.blueprint_tool.selection.bounds.?.size());
    const last_valid = game.blueprint_tool.selection.bounds.?;

    game.world.?.setBlockUnchecked(distant_backing, .none);
    const too_far = coordinates.fromWorld(&test_layout, .{ 0, 31, 1 }).?;
    game.world.?.setBlockUnchecked(too_far, .stone);
    game.updateBlueprintRay();
    try std.testing.expectEqual(blueprint_capture.TargetError.out_of_range, game.blueprint_tool.selection.target_error.?);
    try std.testing.expectEqualDeep(last_valid, game.blueprint_tool.selection.bounds.?);
    try std.testing.expect(!game.blueprint_tool.selection.confirmExtent());

    game.world.?.setBlockUnchecked(too_far, .none);
    game.updateBlueprintRay();
    try std.testing.expectEqual(blueprint_capture.TargetError.no_placement_target, game.blueprint_tool.selection.target_error.?);
    try std.testing.expectEqualDeep(last_valid, game.blueprint_tool.selection.bounds.?);
    try std.testing.expect(!game.blueprint_tool.selection.confirmExtent());

    const elevated_backing = coordinates.fromWorld(&test_layout, .{ 0, 20, 3 }).?;
    game.world.?.setBlockUnchecked(elevated_backing, .stone);
    game.player.?.pitch = @floatCast(std.math.atan((3.5 - fixture.camera.position[2]) / (20 - fixture.camera.position[1])));
    game.player.?.applyCamera(&fixture.camera);
    game.updateBlueprintRay();
    try std.testing.expect(game.blueprint_tool.selection.target_valid);
    try std.testing.expectEqual(@as(u32, 1), game.blueprint_tool.selection.bounds.?.size()[2]);
    game.confirmBlueprintTool();
    try std.testing.expectEqual(blueprint_capture.Stage.height, game.blueprint_tool.selection.stage);
    game.updateBlueprintRay();
    try std.testing.expect(game.blueprint_tool.selection.target_valid);
    try std.testing.expectEqual(@as(i64, anchor[2]) + 2, game.blueprint_tool.selection.bounds.?.max[2]);
    try std.testing.expectEqual(@as(u32, 3), game.blueprint_tool.selection.bounds.?.size()[2]);
    game.player.?.pitch = 0.2;
    game.player.?.applyCamera(&fixture.camera);
    game.updateBlueprintRay();
    try std.testing.expect(game.blueprint_tool.selection.target_valid);
    try std.testing.expect(game.blueprint_tool.selection.bounds.?.max[2] > anchor[2]);
}

const BlueprintCleanupFrameTest = struct {
    streaming: StreamingTest = .{},
    service: WorldDataService = undefined,
    client: world_data_service.Client = undefined,

    fn init(self: *@This()) !void {
        const a = std.testing.allocator;
        self.streaming.init();
        self.service = .{ .layout = &test_layout, .io = std.testing.io, .allocator = a, .worker = undefined, .worker_state = undefined };
        self.client = .{ .service = &self.service };
        errdefer self.deinit();
        self.streaming.game.world_client = &self.client;
        self.streaming.game.render_radius = 0;
        self.streaming.engine.paused = true;
        self.streaming.engine.gameplay_input_blocked = true;
        // Match GPU preflight's occupied-grid guard: actual updateWorld must
        // finish before touching the fixture's undefined graphics device.
        for (0..64) |_| _ = try self.streaming.grid.gpu_block_buffer_manager.occupyBlock(.{ .size_exponent = 6 });
        var mesh: voxel_chunk_module.ChunkSideData = .{};
        try mesh.blocks_grouped_by_side[0].append(a, .{ .coords = .{ 8, 8, 8 }, .block_type = .stone });
        self.streaming.grid.appendChunk(.{ .chunk_coords = .{ 0, 0, 0 }, .chunk_side_data = mesh });
    }

    fn deinit(self: *@This()) void {
        self.streaming.deinit();
        self.service.requests.items.deinit(std.testing.allocator);
        self.client.responses.items.deinit(std.testing.allocator);
        self.client.blueprint_results.items.deinit(std.testing.allocator);
    }

    fn frame(self: *@This()) !void {
        try std.testing.expectEqual(@as(usize, 0), self.client.responses.items.items.len);
        try std.testing.expectEqual(@as(usize, 0), self.streaming.game.chunk_packages.items.len);
        self.streaming.game.updateWorld();
        try std.testing.expectEqual(@as(usize, 0), self.client.responses.items.items.len);
        try std.testing.expectEqual(@as(usize, 0), self.streaming.game.chunk_packages.items.len);
    }
};

test "world update retires a completed client site without packages and ignores late replay" {
    const a = std.testing.allocator;
    const runtime = @import("blueprint_runtime.zig");
    var f: BlueprintCleanupFrameTest = .{};
    try f.init();
    defer f.deinit();
    const world = &f.streaming.game.world.?;
    var saved: runtime.SavedDefinition = .{ .id = 1, .owner = 1, .name = try a.dupe(u8, "Completed"), .definition = .{ .size = .{ 1, 1, 1 }, .cells = try a.dupe(voxel_chunk_module.BlockType, &.{.planks}), .target_count = 1 } };
    defer saved.deinit(a);
    try world.applyBlueprintChanges(&.{.{ .definition = saved }});
    var site = try world.blueprints.prepareInstance(a, &test_layout, 17, 1, 1, .{ 10, 10, 10 }, 0);
    defer site.deinit(a);
    try world.applyBlueprintChanges(&.{.{ .instance = site }});
    try world.applyBlueprintChanges(&.{.{ .fulfill = .{ .instance_id = 17, .cell_index = 0 } }});
    try std.testing.expect(!world.blueprints.instances.get(17).?.active);
    try std.testing.expectEqual(@as(usize, 1), world.blueprints.cleanup_queue.items.len);
    try std.testing.expectEqual(@as(u32, 1), world.blueprints.chunks.count());
    try f.frame();
    try std.testing.expectEqual(@as(u32, 0), world.blueprints.instances.count());
    try std.testing.expectEqual(@as(u32, 0), world.blueprints.chunks.count());
    try std.testing.expectEqual(@as(usize, 0), world.blueprints.cleanup_queue.items.len);
    try std.testing.expectEqual(@as(usize, 0), world.blueprints.cleanup_head);
    try std.testing.expectEqual(@as(u64, 17), world.blueprints.max_instance_id);
    try std.testing.expectEqual(@as(u32, 1), world.blueprints.definitions.count());
    const retired_revision = world.blueprints.revision;
    try world.applyBlueprintChanges(&.{ .{ .instance = site }, .{ .fulfill = .{ .instance_id = 17, .cell_index = 0 } } });
    try f.frame();
    try std.testing.expectEqual(retired_revision, world.blueprints.revision);
    try std.testing.expectEqual(@as(u32, 0), world.blueprints.instances.count());
    try std.testing.expectEqual(@as(u32, 0), world.blueprints.chunks.count());
    try std.testing.expectEqual(@as(usize, 0), world.blueprints.cleanup_queue.items.len);

    // A retained library alone must return ordinary edits to exactly the
    // physical-world validation path after the last site is reclaimed.
    try world.insertChunk(.{ 0, 0, 0 }, WorldChunk.initEmpty());
    const data = try world.chunks.getPtr(test_layout.encodeChunkCoords(.{ 0, 0, 0 })).?.tryEnsureData(a);
    for (0..4) |z| @memset(std.mem.asBytes(&data.blocks[z]), @intFromEnum(voxel_chunk_module.BlockType.stone));
    const operation: world_module.BlockOperation = .{ .block = .{ 10, 10, 4 }, .action = .{ .put = .planks } };
    var reads: usize = 0;
    world.physical_read_counter = &reads;
    var ordinary = std.testing.FailingAllocator.init(a, .{});
    const expected = world_module.validateEdit(ordinary.allocator(), world.reader(), &.{}, operation);
    const ordinary_reads = reads;
    try std.testing.expectEqual(world_module.OperationStatus.success, expected.status);
    try std.testing.expect(ordinary_reads > 1);
    reads = 0;
    var completed = std.testing.FailingAllocator.init(a, .{});
    const actual = world_module.validateCompletedEdit(completed.allocator(), world.reader(), &world.blueprints, &.{}, operation);
    try std.testing.expectEqualDeep(expected, actual);
    try std.testing.expectEqual(ordinary_reads, reads);
    try std.testing.expectEqual(ordinary.allocations, completed.allocations);
    try std.testing.expectEqual(ordinary.allocated_bytes, completed.allocated_bytes);
}

test "world update retires at most four footprint chunks while preserving a shared live site" {
    const a = std.testing.allocator;
    const runtime = @import("blueprint_runtime.zig");
    var f: BlueprintCleanupFrameTest = .{};
    try f.init();
    defer f.deinit();
    const world = &f.streaming.game.world.?;
    const cells = try a.alloc(voxel_chunk_module.BlockType, 129);
    @memset(cells, .none);
    cells[0] = .planks;
    cells[128] = .planks;
    var wide: runtime.SavedDefinition = .{ .id = 1, .owner = 1, .name = try a.dupe(u8, "Five chunks"), .definition = .{ .size = .{ 129, 1, 1 }, .cells = cells, .target_count = 2 } };
    defer wide.deinit(a);
    var small: runtime.SavedDefinition = .{ .id = 2, .owner = 1, .name = try a.dupe(u8, "Still live"), .definition = .{ .size = .{ 1, 1, 1 }, .cells = try a.dupe(voxel_chunk_module.BlockType, &.{.planks}), .target_count = 1 } };
    defer small.deinit(a);
    try world.applyBlueprintChanges(&.{ .{ .definition = wide }, .{ .definition = small } });
    var retired = try world.blueprints.prepareInstance(a, &test_layout, 1, 1, 1, .{ 31, 10, 10 }, 0);
    defer retired.deinit(a);
    var live = try world.blueprints.prepareInstance(a, &test_layout, 2, 2, 1, .{ 30, 10, 10 }, 0);
    defer live.deinit(a);
    try std.testing.expectEqual(@as(usize, 5), retired.box_chunks.len);
    try world.applyBlueprintChanges(&.{ .{ .instance = retired }, .{ .instance = live } });
    try world.applyBlueprintChanges(&.{ .{ .fulfill = .{ .instance_id = 1, .cell_index = 0 } }, .{ .fulfill = .{ .instance_id = 1, .cell_index = 128 } } });
    const revision = world.blueprints.revision;
    try f.frame();
    try std.testing.expectEqual(revision + 4, world.blueprints.revision);
    try std.testing.expectEqual(@as(usize, 4), world.blueprints.instances.get(1).?.cleanup_cursor);
    try std.testing.expectEqual(@as(u32, 2), world.blueprints.instances.count());
    try std.testing.expectEqual(@as(u32, 2), world.blueprints.chunks.count());
    const shared = world.blueprints.chunks.get(live.box_chunks[0]).?;
    try std.testing.expectEqualSlices(u64, &.{2}, shared.instances.items);
    try std.testing.expectEqual(@as(usize, 1), shared.targets.items.len);
    try std.testing.expectEqual(@as(u64, 2), world.blueprints.targetAt(live.origin).?.instance_id);
    try std.testing.expect(world.blueprints.instances.get(2).?.active);
    try f.frame();
    try std.testing.expectEqual(revision + 5, world.blueprints.revision);
    try std.testing.expect(world.blueprints.instances.get(1) == null);
    try std.testing.expectEqual(@as(u32, 1), world.blueprints.instances.count());
    try std.testing.expectEqual(@as(u32, 1), world.blueprints.chunks.count());
    try std.testing.expectEqual(@as(usize, 0), world.blueprints.cleanup_queue.items.len);
    try std.testing.expectEqual(@as(u64, 2), world.blueprints.targetAt(live.origin).?.instance_id);
    try world.applyBlueprintChanges(&.{.{ .fulfill = .{ .instance_id = 2, .cell_index = 0 } }});
    try f.frame();
    try std.testing.expectEqual(@as(u32, 0), world.blueprints.instances.count());
    try std.testing.expectEqual(@as(u32, 0), world.blueprints.chunks.count());
    try std.testing.expectEqual(@as(usize, 0), world.blueprints.cleanup_queue.items.len);
    try std.testing.expectEqual(@as(usize, 0), world.blueprints.cleanup_head);
    try std.testing.expectEqual(@as(u64, 2), world.blueprints.max_instance_id);
    try std.testing.expectEqual(@as(u32, 2), world.blueprints.definitions.count());
}

fn prepareMiniatureSite(fixture: *StreamingTest, width: u32) !void {
    const a = std.testing.allocator;
    const game = &fixture.game;
    const coords: ChunkCoords = .{ 1, 1, 1 };
    try fixture.subscribe(coords, 1, .blocks);
    try game.world.?.insertChunk(coords, WorldChunk.initEmpty());
    game.loadChunkIfNeeded(coords[0], coords[1], coords[2]);
    const name = try a.dupe(u8, "Miniature cache");
    const cells = a.alloc(voxel_chunk_module.BlockType, width) catch |err| {
        a.free(name);
        return err;
    };
    @memset(cells, .planks);
    var saved: @import("blueprint_runtime.zig").SavedDefinition = .{
        .id = 1,
        .owner = 1,
        .name = name,
        .definition = .{ .size = .{ width, 1, 1 }, .cells = cells, .target_count = width },
    };
    defer saved.deinit(a);
    try game.world.?.applyBlueprintChanges(&.{.{ .definition = saved }});
    var instance = try game.world.?.blueprints.prepareInstance(a, game.layout(), 1, 1, 1, .{ 40, 40, 40 }, 0);
    defer instance.deinit(a);
    try game.world.?.applyBlueprintChanges(&.{.{ .instance = instance }});
}

test "visual reconciliation dirties a later prediction invalidated in another chunk" {
    var fixture: StreamingTest = .{};
    fixture.init();
    defer fixture.deinit();
    const a = std.testing.allocator;
    const game = &fixture.game;
    const rejected_coords: ChunkCoords = .{ 1, 1, 1 };
    const later_coords: ChunkCoords = .{ 2, 1, 1 };
    const unrelated_coords: ChunkCoords = .{ 3, 1, 1 };
    for ([_]ChunkCoords{ rejected_coords, later_coords, unrelated_coords }, 1..) |coords, token| {
        try fixture.subscribe(coords, token, .blocks);
        try game.world.?.insertChunk(coords, WorldChunk.initEmpty());
        game.loadChunkIfNeeded(coords[0], coords[1], coords[2]);
    }
    const rejected_block = [3]u32{ 40, 40, 40 };
    const later_block = [3]u32{ 72, 40, 40 };
    game.world.?.setBlockUnchecked(rejected_block, .dirt);
    game.world.?.pending_operations.items[0].request_id = 1;
    game.world.?.setBlockUnchecked(later_block, .dirt);
    game.world.?.pending_operations.items[1].request_id = 2;
    try std.testing.expect(try game.world.?.isBlockSolid(later_block));

    var saved: @import("blueprint_runtime.zig").SavedDefinition = .{
        .id = 1,
        .owner = 1,
        .name = try a.dupe(u8, "Conflicting later prediction"),
        .definition = .{ .size = .{ 1, 1, 1 }, .cells = try a.dupe(voxel_chunk_module.BlockType, &.{.planks}), .target_count = 1 },
    };
    defer saved.deinit(a);
    try game.world.?.applyBlueprintChanges(&.{.{ .definition = saved }});
    var site = try game.world.?.blueprints.prepareInstance(a, game.layout(), 1, 1, 1, later_block, 0);
    defer site.deinit(a);
    game.dirty_chunk_ids.clearRetainingCapacity();
    game.miniature_dirty_chunks.clearRetainingCapacity();
    var package: world_data_service.ResponsePackage = .{};
    defer package.responses.deinit(a);
    defer {
        for (package.blueprint_changes.items) |*change| change.deinit(a);
        package.blueprint_changes.deinit(a);
    }
    try package.blueprint_changes.append(a, .{ .instance = try site.clone(a) });
    try package.responses.append(a, .{
        .coords = rejected_coords,
        .subscription_id = 1,
        .operation = .{ .request_id = 1, .status = .already_exists },
        .data = .acknowledgement,
    });
    try std.testing.expect(game.applyPackage(&package));
    // Publishing the authoritative site makes the later ordinary placement
    // invalid during rollback/replay, despite that chunk having no response.
    try std.testing.expect(!(try game.world.?.isBlockSolid(later_block)));
    try std.testing.expectEqual(@as(usize, 1), game.world.?.pending_operations.items.len);
    const later_id = game.layout().encodeChunkCoords(later_coords);
    try std.testing.expect(game.miniature_dirty_chunks.contains(later_id));
    try std.testing.expect(game.dirty_chunk_ids.contains(later_id));
    const unrelated_id = game.layout().encodeChunkCoords(unrelated_coords);
    try std.testing.expect(!game.miniature_dirty_chunks.contains(unrelated_id));
    try std.testing.expect(!game.dirty_chunk_ids.contains(unrelated_id));
}

test "visual miniature source follows prediction rejection and fulfillment" {
    var fixture: StreamingTest = .{};
    fixture.init();
    defer fixture.deinit();
    const game = &fixture.game;
    const world = &game.world.?;
    const a = std.testing.allocator;
    const coords: ChunkCoords = .{ 1, 1, 1 };
    const id = game.layout().encodeChunkCoords(coords);
    const cell: [3]u32 = .{ 40, 40, 40 };
    try world.insertChunk(coords, WorldChunk.initEmpty());
    try fixture.supportSandPlacement(cell);
    world.pending_operations.clearRetainingCapacity();
    game.loadChunkIfNeeded(coords[0], coords[1], coords[2]);
    const runtime = @import("blueprint_runtime.zig");
    var saved: runtime.SavedDefinition = .{
        .id = 1,
        .owner = game.player_id,
        .name = try a.dupe(u8, "Prediction"),
        .definition = .{ .size = .{ 2, 1, 1 }, .cells = try a.dupe(voxel_chunk_module.BlockType, &.{ .sand, .sand }), .target_count = 2 },
    };
    defer saved.deinit(a);
    try world.applyBlueprintChanges(&.{.{ .definition = saved }});
    var site = try world.blueprints.prepareInstance(a, game.layout(), 1, 1, game.player_id, cell, 0);
    defer site.deinit(a);
    try world.applyBlueprintChanges(&.{.{ .instance = site }});
    try std.testing.expectEqual(@as(usize, 2), (try game.collectMiniatureCells(id)).len);
    const operation: world_module.BlockOperation = .{ .block = cell, .action = .{ .put = .sand }, .blueprint = .{ .instance_id = 1, .cell_index = 0 } };
    try std.testing.expectEqual(.success, world.tryOperation(operation).status);
    world.pending_operations.items[0].request_id = 77;
    const predicted = try game.collectMiniatureCells(id);
    try std.testing.expectEqual(@as(usize, 1), predicted.len);
    try std.testing.expectEqual([3]u32{ 9, 8, 8 }, predicted[0].local);

    // Rejection immediately restores logical occupancy and queues both visual
    // representations; the next source must restore the predicted-away target.
    try fixture.apply(&.{.{ .coords = coords, .subscription_id = null, .operation = .{ .request_id = 77, .status = .constraint_violation }, .data = .acknowledgement }});
    try std.testing.expect(!try world.isBlockSolid(cell));
    try std.testing.expect(game.dirty_chunk_ids.contains(id));
    try std.testing.expect(game.miniature_dirty_chunks.contains(id));
    try std.testing.expectEqual(@as(usize, 2), (try game.collectMiniatureCells(id)).len);

    try std.testing.expectEqual(.success, world.tryOperation(operation).status);
    try world.applyBlueprintChanges(&.{.{ .fulfill = .{ .instance_id = 1, .cell_index = 0 } }});
    try std.testing.expectEqual(@as(usize, 1), (try game.collectMiniatureCells(id)).len);
}

const MiniatureUpdateTest = struct {
    const Record = struct { id: u32, revision: u64, count: usize };
    records: [32]Record = undefined,
    count: usize = 0,
    failed_id: ?u32 = null,

    fn replace(self: *MiniatureUpdateTest, id: u32, _: ChunkCoords, revision: u64, cells: []const blueprint_renderer.MiniatureCell) !void {
        if (self.failed_id == id) return error.OutOfMemory;
        self.records[self.count] = .{ .id = id, .revision = revision, .count = cells.len };
        self.count += 1;
    }
};

test "miniature cache resolves own changes once and reuses sources for camera and neighbor terrain" {
    var fixture: StreamingTest = .{};
    fixture.init();
    defer fixture.deinit();
    try prepareMiniatureSite(&fixture, 2);
    const game = &fixture.game;
    const coords: ChunkCoords = .{ 1, 1, 1 };
    const id = game.layout().encodeChunkCoords(coords);
    const camera_origin = @as(@Vector(3, f64), @floatFromInt(coords - game.layout().origin_chunk)) * @as(@Vector(3, f64), @splat(consts.CHUNK_SIZE));
    const neighbor: ChunkCoords = .{ 2, 1, 1 };
    try game.world.?.insertChunk(neighbor, WorldChunk.initEmpty());
    game.loadChunkIfNeeded(neighbor[0], neighbor[1], neighbor[2]);
    var updates: MiniatureUpdateTest = .{};
    game.drainChunkVisualsWithMiniaturesForTesting(&updates);
    try std.testing.expectEqual(@as(usize, 2), updates.count);
    try std.testing.expectEqual(@as(usize, 0), game.miniature_dirty_chunks.count());
    for (0..4) |frame| {
        fixture.camera.updatePosition(camera_origin + @Vector(3, f64){ @floatFromInt(frame), 0, 0 });
        game.buildBlueprintRenderInstances();
        game.markChunkDirtyIfLoaded(neighbor);
        game.drainChunkVisualsWithMiniaturesForTesting(&updates);
    }
    try std.testing.expectEqual(@as(usize, 2), updates.count);
    try std.testing.expectEqual(@as(usize, 12), game.blueprint_render_instances.items.len);
    // This source changes; only its face neighbor's terrain is invalidated.
    game.markChunksAroundBlockDirty(.{ 63, 40, 40 });
    try std.testing.expect(game.miniature_dirty_chunks.contains(id));
    try std.testing.expect(!game.miniature_dirty_chunks.contains(game.layout().encodeChunkCoords(neighbor)));
    game.drainChunkVisualsWithMiniaturesForTesting(&updates);
    try std.testing.expectEqual(@as(usize, 3), updates.count);
    try std.testing.expectEqual(id, updates.records[2].id);
    try std.testing.expectEqual(@as(usize, 2), updates.records[2].count);
}

test "miniature cache failures retain the latest source while shrinking chunks progress" {
    var fixture: StreamingTest = .{};
    fixture.init();
    defer fixture.deinit();
    // The twenty-fifth target crosses into the next chunk, giving it a live
    // miniature source that fulfillment must shrink to zero.
    try prepareMiniatureSite(&fixture, 25);
    const game = &fixture.game;
    const growing_id = game.layout().encodeChunkId(1, 1, 1);
    const shrinking: ChunkCoords = .{ 2, 1, 1 };
    const shrinking_id = game.layout().encodeChunkCoords(shrinking);
    try game.world.?.insertChunk(shrinking, WorldChunk.initEmpty());
    game.loadChunkIfNeeded(shrinking[0], shrinking[1], shrinking[2]);
    var updates: MiniatureUpdateTest = .{};
    game.drainChunkVisualsWithMiniaturesForTesting(&updates);
    try std.testing.expectEqual(@as(usize, 2), updates.count);
    game.markMiniatureChunkDirty(growing_id);
    try game.world.?.applyBlueprintChangesObserved(&.{.{ .fulfill = .{ .instance_id = 1, .cell_index = 24 } }}, .{
        .context = game,
        .instance_published = Game.observeBlueprintInstance,
        .fulfilled = Game.observeBlueprintFulfilled,
    });
    updates.failed_id = growing_id;
    game.drainChunkVisualsWithMiniaturesForTesting(&updates);
    try std.testing.expectEqual(@as(usize, 3), updates.count);
    try std.testing.expectEqual(shrinking_id, updates.records[2].id);
    try std.testing.expectEqual(@as(usize, 0), updates.records[2].count);
    try std.testing.expectEqual(@as(usize, 1), game.miniature_dirty_chunks.count());
    const failed_revision = game.miniature_dirty_chunks.get(growing_id).?;
    var package: world_data_service.ResponsePackage = .{};
    defer package.responses.deinit(game.allocator);
    defer {
        for (package.blueprint_changes.items) |*change| change.deinit(game.allocator);
        package.blueprint_changes.deinit(game.allocator);
    }
    try package.blueprint_changes.append(game.allocator, .{ .fulfill = .{ .instance_id = 1, .cell_index = 0 } });
    try std.testing.expect(game.applyPackage(&package));
    try std.testing.expect(game.miniature_dirty_chunks.get(growing_id).? != failed_revision);
    updates.failed_id = null;
    game.drainChunkVisualsWithMiniaturesForTesting(&updates);
    try std.testing.expectEqual(@as(usize, 4), updates.count);
    try std.testing.expectEqual(growing_id, updates.records[3].id);
    try std.testing.expectEqual(@as(usize, 23), updates.records[3].count);
    try std.testing.expectEqual(@as(usize, 0), game.miniature_dirty_chunks.count());
}

test "miniature cache accepts mesh-only fulfillment immediately without terrain publication waiting" {
    var fixture: StreamingTest = .{};
    fixture.init();
    defer fixture.deinit();
    try prepareMiniatureSite(&fixture, 1);
    const game = &fixture.game;
    const coords: ChunkCoords = .{ 1, 1, 1 };
    const id = game.layout().encodeChunkCoords(coords);
    var updates: MiniatureUpdateTest = .{};
    game.drainChunkVisualsWithMiniaturesForTesting(&updates);
    try fixture.subscribe(coords, 2, .mesh);
    try fixture.apply(&.{.{ .coords = coords, .subscription_id = 2, .chunk_revision = 1, .mesh_revision = 1, .data = .{ .mesh = .{} } }});
    try std.testing.expect(!game.world.?.hasChunk(coords));
    try std.testing.expect(game.miniature_dirty_chunks.contains(id));
    try std.testing.expectEqual(@as(usize, 1), fixture.grid.chunks_to_upload.items.len);
    game.drainChunkVisualsWithMiniaturesForTesting(&updates);
    try std.testing.expectEqual(@as(usize, 1), updates.records[1].count);
    var package: world_data_service.ResponsePackage = .{};
    defer package.responses.deinit(game.allocator);
    defer {
        for (package.blueprint_changes.items) |*change| change.deinit(game.allocator);
        package.blueprint_changes.deinit(game.allocator);
    }
    try package.blueprint_changes.append(game.allocator, .{ .fulfill = .{ .instance_id = 1, .cell_index = 0 } });
    try std.testing.expect(game.applyPackage(&package));
    game.drainChunkVisualsWithMiniaturesForTesting(&updates);
    try std.testing.expectEqual(@as(usize, 0), updates.records[2].count);
    try std.testing.expectEqual(@as(usize, 0), game.miniature_dirty_chunks.count());
}

test "miniature cache invalidates accepted snapshots and clears obligations on eviction" {
    var fixture: StreamingTest = .{};
    fixture.init();
    defer fixture.deinit();
    try prepareMiniatureSite(&fixture, 1);
    const game = &fixture.game;
    const coords: ChunkCoords = .{ 1, 1, 1 };
    const id = game.layout().encodeChunkCoords(coords);
    var updates: MiniatureUpdateTest = .{};
    game.drainChunkVisualsWithMiniaturesForTesting(&updates);
    try fixture.apply(&.{.{ .coords = coords, .subscription_id = 99, .chunk_revision = 1, .data = .{ .blocks = .{ .chunk = singleTestBlock(.{ 8, 8, 8 }, 1) } } }});
    try std.testing.expect(!game.miniature_dirty_chunks.contains(id));
    try fixture.apply(&.{.{ .coords = coords, .subscription_id = 1, .chunk_revision = 1, .data = .{ .blocks = .{ .chunk = singleTestBlock(.{ 8, 8, 8 }, 1) } } }});
    try std.testing.expect(game.miniature_dirty_chunks.contains(id));
    game.drainChunkVisualsWithMiniaturesForTesting(&updates);
    try std.testing.expectEqual(@as(usize, 0), updates.records[1].count);
    game.markMiniatureChunkDirty(id);
    game.removeChunkByIdIfNeeded(id);
    try std.testing.expect(!game.miniature_dirty_chunks.contains(id));
    game.loadChunkIfNeeded(coords[0], coords[1], coords[2]);
    try std.testing.expect(game.miniature_dirty_chunks.contains(id));
    game.drainChunkVisualsWithMiniaturesForTesting(&updates);
    try std.testing.expectEqual(@as(usize, 3), updates.count);
}

const ChunkVisualTestUpdater = struct {
    terrain_ids: [32]u32 = undefined,
    miniature_ids: [32]u32 = undefined,
    terrain_count: usize = 0,
    miniature_count: usize = 0,
    fail_terrain: ?u32 = null,
    fail_miniature: ?u32 = null,

    fn terrain(self: *ChunkVisualTestUpdater, id: u32) !void {
        self.terrain_ids[self.terrain_count] = id;
        self.terrain_count += 1;
        if (self.fail_terrain == id) return error.OutOfMemory;
    }

    fn replace(self: *ChunkVisualTestUpdater, id: u32, _: ChunkCoords, _: u64, _: []const blueprint_renderer.MiniatureCell) !void {
        self.miniature_ids[self.miniature_count] = id;
        self.miniature_count += 1;
        if (self.fail_miniature == id) return error.OutOfMemory;
    }
};

fn prepareBudgetedVisualChunks(fixture: *StreamingTest, count: usize) !void {
    for (0..count) |i| {
        const coords: ChunkCoords = .{ @intCast(i), 1, 1 };
        try fixture.subscribe(coords, i + 1, .blocks);
        try fixture.game.world.?.insertChunk(coords, singleTestBlock(.{ 8, 8, 8 }, 0));
        fixture.game.loadChunkIfNeeded(coords[0], coords[1], coords[2]);
    }
}

test "chunk visual budget starts four chunks immediately and preserves FIFO fairness" {
    var fixture: StreamingTest = .{};
    fixture.init();
    defer fixture.deinit();
    try prepareBudgetedVisualChunks(&fixture, 8);
    const game = &fixture.game;
    var updates: ChunkVisualTestUpdater = .{};
    try std.testing.expectEqual(@as(u64, 0), game.chunk_visuals.min_age_frames);
    game.processChunkVisuals(&updates, .{}, false);
    try std.testing.expectEqual(@as(usize, 4), updates.terrain_count);
    try std.testing.expectEqual(@as(usize, 4), updates.miniature_count);
    try std.testing.expectEqual(@as(usize, 4), game.chunk_visuals.count());
    for (0..4) |i| {
        const id = game.layout().encodeChunkId(i, 1, 1);
        try std.testing.expectEqual(id, updates.terrain_ids[i]);
        try std.testing.expectEqual(id, updates.miniature_ids[i]);
    }
    // A hot serviced chunk rejoins behind the four chunks still waiting.
    game.markChunksAroundBlockDirty(.{ 8, 40, 40 });
    game.processChunkVisuals(&updates, .{}, false);
    try std.testing.expectEqual(@as(usize, 8), updates.terrain_count);
    for (4..8) |i| try std.testing.expectEqual(game.layout().encodeChunkId(i, 1, 1), updates.terrain_ids[i]);
    try std.testing.expectEqual(@as(usize, 1), game.chunk_visuals.count());
    game.processChunkVisuals(&updates, .{}, false);
    try std.testing.expectEqual(@as(usize, 9), updates.terrain_count);
    try std.testing.expectEqual(@as(usize, 0), game.chunk_visuals.count());
    const head_checks = game.chunk_visuals.stats.head_checks;
    for (0..8) |_| game.processChunkVisuals(&updates, .{}, false);
    try std.testing.expectEqual(head_checks, game.chunk_visuals.stats.head_checks);
}

test "chunk visual time budget permits one whole chunk before a soft zero limit" {
    var fixture: StreamingTest = .{};
    fixture.init();
    defer fixture.deinit();
    try prepareBudgetedVisualChunks(&fixture, 2);
    var updates: ChunkVisualTestUpdater = .{};
    fixture.game.processChunkVisuals(&updates, .{ .max_elapsed_ns = 0 }, false);
    try std.testing.expectEqual(@as(usize, 1), updates.terrain_count);
    try std.testing.expectEqual(@as(usize, 1), updates.miniature_count);
    try std.testing.expectEqual(@as(usize, 1), fixture.game.chunk_visuals.count());
}

test "chunk visual retries visit each initial item once and complete sources independently" {
    var fixture: StreamingTest = .{};
    fixture.init();
    defer fixture.deinit();
    try prepareBudgetedVisualChunks(&fixture, 3);
    const game = &fixture.game;
    const failed_id = game.layout().encodeChunkId(0, 1, 1);
    const unlimited: chunk_visual_queue.FrameBudget = .{ .max_items = std.math.maxInt(u32), .max_elapsed_ns = std.math.maxInt(u64) };
    var updates: ChunkVisualTestUpdater = .{ .fail_miniature = failed_id };
    game.processChunkVisuals(&updates, unlimited, false);
    try std.testing.expectEqual(@as(usize, 3), updates.terrain_count);
    try std.testing.expectEqual(@as(usize, 3), updates.miniature_count);
    try std.testing.expectEqual(@as(usize, 1), game.chunk_visuals.count());
    try std.testing.expect(!game.dirty_chunk_ids.contains(failed_id));
    try std.testing.expect(game.miniature_dirty_chunks.contains(failed_id));
    updates.fail_miniature = null;
    game.processChunkVisuals(&updates, unlimited, false);
    try std.testing.expectEqual(@as(usize, 3), updates.terrain_count);
    try std.testing.expectEqual(@as(usize, 4), updates.miniature_count);
    try std.testing.expectEqual(@as(usize, 0), game.chunk_visuals.count());

    game.markChunksAroundBlockDirty(.{ 8, 40, 40 });
    updates.fail_terrain = failed_id;
    game.processChunkVisuals(&updates, unlimited, false);
    try std.testing.expect(game.dirty_chunk_ids.contains(failed_id));
    try std.testing.expect(!game.miniature_dirty_chunks.contains(failed_id));
    try std.testing.expectEqual(@as(usize, 4), updates.terrain_count);
    try std.testing.expectEqual(@as(usize, 5), updates.miniature_count);
    updates.fail_terrain = null;
    game.processChunkVisuals(&updates, unlimited, false);
    try std.testing.expectEqual(@as(usize, 5), updates.terrain_count);
    try std.testing.expectEqual(@as(usize, 5), updates.miniature_count);
    try std.testing.expectEqual(@as(usize, 0), game.chunk_visuals.count());
}

test "chunk visual stale subscriptions refresh at the tail and eviction cancels work" {
    var fixture: StreamingTest = .{};
    fixture.init();
    defer fixture.deinit();
    try prepareBudgetedVisualChunks(&fixture, 3);
    const game = &fixture.game;
    const refreshed_id = game.layout().encodeChunkId(0, 1, 1);
    const canceled_id = game.layout().encodeChunkId(1, 1, 1);
    try fixture.subscribe(.{ 0, 1, 1 }, 99, .blocks);
    var updates: ChunkVisualTestUpdater = .{};
    game.processChunkVisuals(&updates, .{ .max_items = 1 }, false);
    try std.testing.expectEqual(@as(usize, 0), updates.terrain_count);
    try std.testing.expectEqual(@as(usize, 0), updates.miniature_count);
    try std.testing.expectEqual(@as(usize, 3), game.chunk_visuals.count());
    game.removeChunkByIdIfNeeded(canceled_id);
    try std.testing.expect(!game.chunk_visuals.contains(canceled_id));
    try std.testing.expect(!game.dirty_chunk_ids.contains(canceled_id));
    try std.testing.expect(!game.miniature_dirty_chunks.contains(canceled_id));
    game.processChunkVisuals(&updates, .{}, false);
    try std.testing.expectEqual(@as(usize, 2), updates.terrain_count);
    try std.testing.expectEqual(game.layout().encodeChunkId(2, 1, 1), updates.terrain_ids[0]);
    try std.testing.expectEqual(refreshed_id, updates.terrain_ids[1]);
    try std.testing.expectEqual(@as(usize, 0), game.chunk_visuals.count());
}

test "chunk visual budget leaves received service mesh uploads direct" {
    var fixture: StreamingTest = .{};
    fixture.init();
    defer fixture.deinit();
    const game = &fixture.game;
    for (0..8) |i| {
        const coords: ChunkCoords = .{ @intCast(i), 1, 1 };
        try fixture.subscribe(coords, i + 1, .mesh);
        try fixture.apply(&.{.{ .coords = coords, .subscription_id = i + 1, .mesh_revision = 1, .data = .{ .mesh = .{} } }});
    }
    try std.testing.expectEqual(@as(usize, 8), fixture.grid.chunks_to_upload.items.len);
    try std.testing.expectEqual(@as(u64, 0), game.chunk_visuals.stats.taken);
    var updates: ChunkVisualTestUpdater = .{};
    game.processChunkVisuals(&updates, .{}, false);
    try std.testing.expectEqual(@as(usize, 0), updates.terrain_count);
    try std.testing.expectEqual(@as(usize, 4), updates.miniature_count);
    try std.testing.expectEqual(@as(usize, 4), game.chunk_visuals.count());
    try std.testing.expectEqual(@as(usize, 8), fixture.grid.chunks_to_upload.items.len);
}

test "chunk visual terrain allocation failure preserves queued geometry while miniatures complete" {
    var fixture: StreamingTest = .{};
    fixture.init();
    defer fixture.deinit();
    try prepareBudgetedVisualChunks(&fixture, 1);
    const game = &fixture.game;
    game.drainChunkVisualsForTesting();
    const id = game.layout().encodeChunkId(0, 1, 1);
    const old_faces = fixture.grid.chunks_to_upload.items[0].chunk_side_data.blocks_grouped_by_side[0].items.ptr;
    game.world.?.chunks.getPtr(id).?.changeType(.{ 8, 8, 8 }, .dirt);
    game.markChunksAroundBlockDirty(.{ 8, 40, 40 });
    var failing = std.testing.FailingAllocator.init(std.testing.allocator, .{ .fail_index = 0 });
    const Updater = struct {
        game: *Game,
        fn terrain(self: @This(), chunk_id: u32) !void {
            try self.game.rebuildTerrainChunk(chunk_id);
        }
        fn replace(_: @This(), _: u32, _: ChunkCoords, _: u64, _: []const blueprint_renderer.MiniatureCell) !void {}
    };
    game.allocator = failing.allocator();
    game.processChunkVisuals(Updater{ .game = game }, .{}, false);
    game.allocator = std.testing.allocator;
    try std.testing.expect(failing.has_induced_failure);
    try std.testing.expectEqual(old_faces, fixture.grid.chunks_to_upload.items[0].chunk_side_data.blocks_grouped_by_side[0].items.ptr);
    try std.testing.expectEqual(voxel_chunk_module.RenderMaterial.stone, fixture.grid.chunks_to_upload.items[0].chunk_side_data.blocks_grouped_by_side[0].items[0].block_type);
    try std.testing.expect(game.dirty_chunk_ids.contains(id));
    try std.testing.expect(!game.miniature_dirty_chunks.contains(id));
    game.drainChunkVisualsForTesting();
    try std.testing.expectEqual(voxel_chunk_module.RenderMaterial.dirt, fixture.grid.chunks_to_upload.items[0].chunk_side_data.blocks_grouped_by_side[0].items[0].block_type);
    try std.testing.expectEqual(@as(usize, 0), game.chunk_visuals.count());
}
