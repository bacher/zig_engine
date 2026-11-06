//! Blueprint tool lifecycle. World reads, service submission, and drawing stay in Game.
//! This controller owns drafts and request generations without a Game or graphics context.
const std = @import("std");
const WorldLayout = @import("engine").WorldLayout;
const blueprint = @import("blueprint.zig");
const blueprint_capture = @import("blueprint_capture.zig");
const consts = @import("consts.zig");
const protocol = @import("blueprint_result.zig");

pub const BlueprintTool = struct {
    /// Blueprint actions latch presses without block inventories or timed transfers.
    pub const Press = struct {
        pub const Source = enum { key, mouse };
        requested: ?Source = null,
        key_down: bool = false,
        mouse_down: bool = false,

        pub fn press(self: *Press, source: Source) void {
            const was_down = self.key_down or self.mouse_down;
            switch (source) {
                .key => self.key_down = true,
                .mouse => self.mouse_down = true,
            }
            if (!was_down) self.requested = source;
        }

        pub fn loseFocus(self: *Press) void {
            self.requested = null;
            self.key_down = false;
            self.mouse_down = false;
        }
    };
    pub const ResultContext = struct { now: f64, persistent: bool, status_duration: f64 };
    pub const Mode = enum { none, capture, preview };
    pub const Action = enum { other, escape, capture, chooser, name, rotate, interact, control, map };
    /// The application performs these effects after the controller's state transition.
    pub const Effect = enum { unhandled, consumed, reset_inputs, capture, chooser, menu, control };
    pub const Publication = struct { definition_present: bool = false, max_instance_id: ?u64 = null };
    budgets: blueprint_capture.Budgets = .{},
    mode: Mode = .none,
    chooser_open: bool = false,
    selection: blueprint_capture.Selection = .{},
    press: Press = .{},
    helper: ?*blueprint_capture.Helper = null,
    candidate: ?blueprint.CertifiedDefinition = null,
    diagnostics: ?blueprint.Diagnostics = null,
    source_chunks: std.ArrayList(u32) = .empty,
    results: std.ArrayList(protocol.Result) = .empty,
    save: ?struct { request_id: u64, generation: u64 } = null,
    apply: ?struct { request_id: u64, generation: u64 } = null,
    preview: ?struct { definition_id: u64, rotation: u2 = 0, origin: ?[3]u32 = null, generation: u64, rejection: ?protocol.Rejection = null } = null,
    preview_generation: u64 = 0,
    name: [404:0]u8 = @splat(0),
    name_focus: bool = false,
    error_message: ?[]const u8 = null,
    status: ?[]const u8 = null,
    status_expires_at: f64 = 0,
    copy_ns: u64 = 0,
    snapshot_bytes: usize = 0,
    source_peak: usize = 0,

    pub fn deinit(self: *BlueprintTool, allocator: std.mem.Allocator) void {
        self.stopCapture(allocator);
        self.source_chunks.deinit(allocator);
        self.results.deinit(allocator);
    }

    pub fn stopCapture(self: *BlueprintTool, allocator: std.mem.Allocator) void {
        if (self.helper) |helper| helper.destroy();
        self.helper = null;
        if (self.candidate) |*candidate| candidate.deinit(allocator);
        self.candidate = null;
        self.source_chunks.clearRetainingCapacity();
    }

    pub fn enterCapture(self: *BlueprintTool, allocator: std.mem.Allocator) void {
        self.mode = .capture;
        self.resetDraft(allocator);
    }

    pub fn canOpenChooser(self: *const BlueprintTool) bool {
        return !self.chooser_open and self.mode != .preview and (self.mode != .capture or self.selection.stage == .anchor);
    }

    pub fn openChooser(self: *BlueprintTool) void {
        self.chooser_open = true;
        self.press.loseFocus();
    }

    pub fn cancelChooser(self: *BlueprintTool) void {
        self.chooser_open = false;
        self.press.loseFocus();
    }

    /// The application has already checked that this definition belongs to the player.
    pub fn select(self: *BlueprintTool, allocator: std.mem.Allocator, definition_id: u64) void {
        if (!self.chooser_open) return;
        self.chooser_open = false;
        self.mode = .preview;
        self.preview_generation +%= 1;
        self.preview = .{ .definition_id = definition_id, .generation = self.preview_generation };
        self.resetDraft(allocator);
    }

    pub fn canRetarget(self: *const BlueprintTool) bool {
        return self.apply == null or (self.preview != null and self.apply.?.generation != self.preview.?.generation);
    }

    pub fn rotate(self: *BlueprintTool) void {
        if (!self.canRetarget()) return;
        if (self.preview) |*preview| preview.rotation +%= 1;
        self.clearPreviewRejection();
    }

    pub fn beginNaming(self: *BlueprintTool) bool {
        if (self.selection.stage != .ready or self.candidate == null) return false;
        self.selection.stage = .naming;
        self.name = @splat(0);
        self.name_focus = true;
        self.error_message = null;
        self.press.loseFocus();
        return true;
    }

    pub fn handleAction(self: *BlueprintTool, allocator: std.mem.Allocator, action: Action, overlay_open: bool) Effect {
        if (self.chooser_open) {
            switch (action) {
                .escape, .chooser => {
                    self.cancelChooser();
                    return .reset_inputs;
                },
                .control => {
                    self.leave(allocator);
                    return .control;
                },
                else => return .consumed,
            }
        }
        if (self.mode == .capture and self.selection.stage == .naming) {
            if (action == .escape) {
                self.resetDraft(allocator);
                return .reset_inputs;
            }
            return .consumed;
        }
        if (overlay_open) return if (action == .capture or action == .chooser) .consumed else .unhandled;
        if (self.mode == .none) return switch (action) {
            .capture => .capture,
            .chooser => .chooser,
            else => .unhandled,
        };
        switch (action) {
            .capture, .map => {
                if (action == .capture and self.mode == .capture) {
                    self.leave(allocator);
                    return .reset_inputs;
                }
                return .consumed;
            },
            .escape => {
                if (self.mode == .capture) {
                    if (self.selection.stage == .anchor) {
                        self.leave(allocator);
                        return .menu;
                    }
                    self.resetDraft(allocator);
                } else self.leave(allocator);
                return .reset_inputs;
            },
            .chooser => {
                if (self.mode == .capture) return if (self.selection.stage == .anchor) .chooser else .consumed;
                self.leave(allocator);
                return .reset_inputs;
            },
            .name => {
                if (self.mode != .capture) return .unhandled;
                return if (self.beginNaming()) .reset_inputs else .consumed;
            },
            .rotate => {
                if (self.mode != .preview) return .unhandled;
                self.rotate();
                return .consumed;
            },
            .interact => {
                self.press.press(.key);
                return .consumed;
            },
            .control => {
                self.leave(allocator);
                return .control;
            },
            .other => return .unhandled,
        }
    }

    pub fn nameForSave(self: *BlueprintTool) ?[]const u8 {
        const name = blueprint_capture.checkedName(std.mem.sliceTo(&self.name, 0)) catch |err| {
            self.error_message = switch (err) {
                error.EmptyName => "Enter a nonempty blueprint name.",
                error.NameTooLong => "Blueprint names may contain at most 100 Unicode characters and 400 UTF-8 bytes.",
                else => "Blueprint names cannot contain line breaks or control characters.",
            };
            return null;
        };
        if (self.save != null) {
            self.error_message = "The previous blueprint save is still pending.";
            return null;
        }
        return name;
    }

    /// Called only after service submission successfully took the candidate's ownership.
    pub fn didSubmitSave(self: *BlueprintTool, request_id: u64, now: f64) void {
        self.candidate = null;
        self.save = .{ .request_id = request_id, .generation = self.selection.generation };
        self.setStatus(now, "Saving blueprint...", std.math.inf(f64));
        self.selection.stage = .validating;
        self.error_message = null;
    }

    pub fn didSubmitApply(self: *BlueprintTool, request_id: u64, generation: u64, now: f64) void {
        self.apply = .{ .request_id = request_id, .generation = generation };
        self.clearPreviewRejection();
        self.error_message = null;
        self.setStatus(now, "Checking blueprint destination...", std.math.inf(f64));
    }

    pub fn controlsBlocked(self: *const BlueprintTool) bool {
        return self.chooser_open or (self.mode == .capture and self.selection.stage == .naming);
    }

    pub fn setStatus(self: *BlueprintTool, now: f64, message: []const u8, duration: f64) void {
        self.status = message;
        self.status_expires_at = now + duration;
    }

    pub fn statusMessage(self: *const BlueprintTool, now: f64) ?[]const u8 {
        if (now >= self.status_expires_at) return null;
        return self.status;
    }

    pub fn resetDraft(self: *BlueprintTool, allocator: std.mem.Allocator) void {
        self.selection.budgets = self.budgets;
        self.selection.reset();
        self.source_chunks.clearRetainingCapacity();
        if (self.helper) |helper| helper.cancelJob();
        if (self.candidate) |*candidate| candidate.deinit(allocator);
        self.candidate = null;
        self.diagnostics = null;
        self.error_message = null;
        self.name = @splat(0);
        self.press.loseFocus();
    }

    pub fn leave(self: *BlueprintTool, allocator: std.mem.Allocator) void {
        self.chooser_open = false;
        self.mode = .none;
        self.preview = null;
        self.resetDraft(allocator);
    }

    pub fn prepareSource(self: *BlueprintTool, allocator: std.mem.Allocator, layout: *const WorldLayout) void {
        const box = self.selection.bounds orelse return;
        const size = box.size();
        if (size[0] > blueprint_capture.horizontalLimit(layout) or size[1] > blueprint_capture.horizontalLimit(layout) or (box.volume() catch self.budgets.max_cells + 1) > self.budgets.max_cells) {
            self.error_message = "Blueprint selection exceeds its size or resource budget.";
            self.selection.stage = .invalid;
            return;
        }
        self.source_chunks.clearRetainingCapacity();
        var ids: std.AutoHashMapUnmanaged(u32, void) = .empty;
        defer ids.deinit(allocator);
        const low = @divFloor(box.min, @as(blueprint_capture.Cell, @splat(consts.CHUNK_SIZE)));
        const high = @divFloor(box.max, @as(blueprint_capture.Cell, @splat(consts.CHUNK_SIZE)));
        var z = low[2];
        while (z <= high[2]) : (z += 1) {
            var y = low[1];
            while (y <= high[1]) : (y += 1) {
                var x = low[0];
                while (x <= high[0]) : (x += 1) {
                    const coords = layout.normalizeChunkCoords(.{ @intCast(x), @intCast(y), @intCast(z) }) orelse {
                        self.error_message = "Blueprint selection is outside the world.";
                        self.selection.stage = .invalid;
                        return;
                    };
                    const id = layout.encodeChunkCoords(coords);
                    ids.put(allocator, id, {}) catch {
                        self.error_message = "Not enough memory to retain capture source chunks.";
                        self.selection.stage = .invalid;
                        return;
                    };
                    if (ids.count() > self.budgets.max_source_chunks) {
                        self.error_message = "Blueprint source chunk retention budget exceeded.";
                        self.selection.stage = .invalid;
                        return;
                    }
                }
            }
        }
        self.source_chunks.ensureTotalCapacity(allocator, ids.count()) catch {
            self.error_message = "Not enough memory to retain capture source chunks.";
            self.selection.stage = .invalid;
            return;
        };
        var iterator = ids.keyIterator();
        while (iterator.next()) |id| self.source_chunks.appendAssumeCapacity(id.*);
    }

    pub fn pollCapture(self: *BlueprintTool, allocator: std.mem.Allocator) void {
        if (self.helper) |helper| if (helper.takeResult()) |output| {
            var result = output;
            defer result.deinit(allocator);
            if (self.mode == .capture and result.generation == self.selection.generation and self.selection.stage == .validating) {
                if (result.failed) {
                    self.error_message = "Blueprint validation ran out of resources.";
                    self.selection.stage = .invalid;
                } else if (result.output) |compiled| switch (compiled) {
                    .valid => |candidate| {
                        self.candidate = candidate;
                        result.output = null;
                        self.selection.stage = .ready;
                    },
                    .invalid => |diagnostics| {
                        self.diagnostics = diagnostics;
                        self.selection.stage = .invalid;
                    },
                    .cancelled => self.selection.stage = .invalid,
                };
            }
        };
    }

    pub fn clearPreviewRejection(self: *BlueprintTool) void {
        if (self.preview) |*preview| {
            if (preview.rejection == null) return;
            preview.rejection = null;
            self.error_message = null;
        }
    }

    pub fn updatePreviewOrigin(self: *BlueprintTool, origin: ?[3]u32) void {
        if (self.preview) |*preview| {
            if (!std.meta.eql(preview.origin, origin)) self.clearPreviewRejection();
            preview.origin = origin;
        }
    }

    fn blueprintApplicationMessage(result: protocol.Result) []const u8 {
        if (result.status == .success) return "Blueprint site created.";
        if (result.rejection) |rejection| return switch (rejection.code) {
            .invalid_definition => "This blueprint is unavailable or invalid. Select it again.",
            .bounds => "The blueprint extends beyond the buildable world bounds.",
            .overlap => "The blueprint overlaps an unfinished construction site.",
            .occupied => "A required blueprint cell is already occupied. Clear it or move the blueprint.",
            .immutable => "A required blueprint cell cannot be changed.",
            .missing_data => "Blueprint application needs loaded destination data. Try again.",
            .foundation => "The blueprint needs a stable 3x3x3 platform beneath each bottom-layer block.",
            .composition => "The blueprint conflicts with construction rules at this destination.",
            .budget_exceeded => "Blueprint destination checking exceeded its resource budget.",
        };
        return switch (result.status) {
            .missing_data => "Blueprint application needs loaded destination data. Try again.",
            .resource_exhausted => "Blueprint application exceeded its resource budget.",
            .stale => "The destination changed during admission. Try again.",
            else => "Blueprint application was rejected. Try another destination.",
        };
    }

    pub fn resultReady(self: *const BlueprintTool, result: protocol.Result, published: Publication) bool {
        if (result.status != .success) return true;
        if (result.kind == .save) {
            const pending = self.save orelse return true;
            if (pending.request_id != result.request_id) return true;
            if (result.definition_id == null) return true;
            return published.definition_present;
        }
        const pending = self.apply orelse return true;
        if (pending.request_id != result.request_id) return true;
        const id = result.instance_id orelse return true;
        // Completed instances may already have had their indexes retired.
        return if (published.max_instance_id) |max_id| max_id >= id else false;
    }

    /// Returns true when the application must clear held input after a reset/exit.
    pub fn acceptResult(self: *BlueprintTool, allocator: std.mem.Allocator, result: protocol.Result, context: ResultContext) bool {
        if (result.kind == .save) {
            if (self.save) |save| if (save.request_id == result.request_id) {
                self.save = null;
                self.setStatus(context.now, if (result.status == .success)
                    (if (!context.persistent) "Blueprint added for this session only." else "Blueprint added to your library. Included in the next world save.")
                else if (result.status == .resource_exhausted)
                    "Blueprint library capacity was reached; this blueprint was not saved."
                else
                    "Blueprint save was rejected; no blueprint was published.", context.status_duration);
                if (self.mode == .capture and self.selection.generation == save.generation) {
                    if (result.status == .success) {
                        self.resetDraft(allocator);
                        return true;
                    } else {
                        // The service consumed the candidate; this draft has no job
                        // left to validate. Keep the rejection until an explicit reset.
                        self.selection.stage = .invalid;
                        self.error_message = self.status;
                    }
                }
            };
        } else if (self.apply) |apply| if (apply.request_id == result.request_id) {
            self.apply = null;
            self.setStatus(context.now, blueprintApplicationMessage(result), context.status_duration);
            if (self.mode == .preview and self.preview != null and self.preview.?.generation == apply.generation) {
                if (result.status == .success) {
                    self.leave(allocator);
                    return true;
                } else {
                    self.preview.?.rejection = result.rejection;
                    self.error_message = self.status;
                }
            }
        };
        return false;
    }
};

test "blueprint results expire in real time while pending operations keep their status" {
    var tool: BlueprintTool = .{};
    defer tool.deinit(std.testing.allocator);
    var now: f64 = 0;
    tool.enterCapture(std.testing.allocator);
    tool.save = .{ .request_id = 77, .generation = tool.selection.generation };
    tool.setStatus(now, "Saving blueprint...", std.math.inf(f64));
    now = 100;
    try std.testing.expectEqualStrings("Saving blueprint...", tool.statusMessage(now).?);

    _ = tool.acceptResult(std.testing.allocator, .{ .request_id = 77, .kind = .save, .status = .success }, .{ .now = now, .persistent = false, .status_duration = 4 });
    try std.testing.expectEqualStrings("Blueprint added for this session only.", tool.statusMessage(now).?);
    try std.testing.expectEqual(null, tool.save);
    now += @as(f64, 4) - 0.01;
    try std.testing.expect(tool.statusMessage(now) != null);
    now = 100 + @as(f64, 4);
    try std.testing.expectEqual(null, tool.statusMessage(now));

    tool.apply = .{ .request_id = 78, .generation = 1 };
    tool.mode = .preview;
    tool.preview = .{ .definition_id = 1, .generation = 1 };
    _ = tool.acceptResult(std.testing.allocator, .{ .request_id = 78, .kind = .apply, .status = .stale }, .{ .now = now, .persistent = false, .status_duration = 4 });
    try std.testing.expect(tool.statusMessage(now) != null);
    now += @as(f64, 4);
    try std.testing.expectEqual(null, tool.statusMessage(now));
    // A rejected destination still explains the required retry in the active tool.
    try std.testing.expectEqualStrings("The destination changed during admission. Try again.", tool.error_message.?);
    try std.testing.expectEqual(.preview, tool.mode);
}

test "blueprint composition diagnostics survive late replies without leaking to another preview" {
    var tool: BlueprintTool = .{};
    defer tool.deinit(std.testing.allocator);
    const rejection: protocol.Rejection = .{ .code = .composition, .cell = .{ 8, 8, 70 }, .failure = .{
        .reason = .would_invalidate_structure,
        .cause = .horizontal_span,
        .subject = .{ 8, 8, 70 },
        .actual = 8,
        .limit = 6,
    } };
    const result: protocol.Result = .{ .request_id = 77, .kind = .apply, .status = .invalid, .rejection = rejection };
    tool.mode = .preview;
    tool.preview = .{ .definition_id = 1, .generation = 10 };
    tool.apply = .{ .request_id = 77, .generation = 10 };
    _ = tool.acceptResult(std.testing.allocator, result, .{ .now = 0, .persistent = false, .status_duration = 4 });
    try std.testing.expectEqualDeep(rejection, tool.preview.?.rejection.?);
    try std.testing.expectEqualStrings("The blueprint conflicts with construction rules at this destination.", tool.error_message.?);
    tool.apply = .{ .request_id = 77, .generation = 10 };
    tool.preview = .{ .definition_id = 2, .generation = 11 };
    tool.error_message = "New preview message";
    _ = tool.acceptResult(std.testing.allocator, result, .{ .now = 0, .persistent = false, .status_duration = 4 });
    try std.testing.expectEqual(null, tool.preview.?.rejection);
    try std.testing.expectEqualStrings("New preview message", tool.error_message.?);
    tool.leave(std.testing.allocator);
    tool.apply = .{ .request_id = 77, .generation = 10 };
    _ = tool.acceptResult(std.testing.allocator, result, .{ .now = 0, .persistent = false, .status_duration = 4 });
    try std.testing.expectEqual(.none, tool.mode);
    try std.testing.expectEqual(null, tool.preview);
    try std.testing.expectEqual(null, tool.error_message);
}

test "modal blueprint actions reset drafts without forgetting outstanding requests" {
    const a = std.testing.allocator;
    var tool: BlueprintTool = .{};
    defer tool.deinit(a);
    tool.enterCapture(a);
    const generation = tool.selection.generation;
    tool.save = .{ .request_id = 77, .generation = generation -% 1 };
    tool.apply = .{ .request_id = 78, .generation = 10 };
    try std.testing.expectEqual(.chooser, tool.handleAction(a, .chooser, false));
    tool.openChooser();
    try std.testing.expect(tool.controlsBlocked());
    try std.testing.expectEqual(.consumed, tool.handleAction(a, .capture, false));
    try std.testing.expectEqual(.reset_inputs, tool.handleAction(a, .escape, false));
    try std.testing.expect(!tool.controlsBlocked());
    try std.testing.expectEqual(.capture, tool.mode);
    try std.testing.expectEqual(generation, tool.selection.generation);

    const compiled = try blueprint.compile(a, .{ .size = .{ 1, 1, 1 }, .cells = &.{.dirt} }, .{ .horizontal_limit = 127 });
    tool.candidate = compiled.valid;
    tool.selection.stage = .ready;
    try std.testing.expectEqual(.reset_inputs, tool.handleAction(a, .name, false));
    try std.testing.expect(tool.controlsBlocked());
    const selection = tool.selection;
    // The naming modal owns every gameplay/debug action until Escape.
    for (std.enums.values(BlueprintTool.Action)) |action| {
        if (action == .escape) continue;
        try std.testing.expectEqual(.consumed, tool.handleAction(a, action, false));
        try std.testing.expectEqualDeep(selection, tool.selection);
    }
    tool.press.press(.mouse);
    try std.testing.expectEqual(.reset_inputs, tool.handleAction(a, .escape, false));
    try std.testing.expectEqual(null, tool.candidate);
    try std.testing.expectEqual(null, tool.press.requested);
    try std.testing.expectEqual(.anchor, tool.selection.stage);
    try std.testing.expect(tool.selection.generation != generation);
    try std.testing.expectEqual(@as(u64, 77), tool.save.?.request_id);
    try std.testing.expectEqual(@as(u64, 78), tool.apply.?.request_id);
    try std.testing.expectEqual(.menu, tool.handleAction(a, .escape, false));
    try std.testing.expectEqual(.none, tool.mode);
    try std.testing.expect(!tool.controlsBlocked());
    try std.testing.expectEqual(.consumed, tool.handleAction(a, .capture, true));
}
