const std = @import("std");
const zglfw = @import("zglfw");

pub const KeyParams = struct {
    key: zglfw.Key,
    mods: zglfw.Mods,
};

pub const CursorCapture = enum { while_left_button, always };

pub fn InputController(comptime Context: type) type {
    return struct {
        pub const Callbacks = struct {
            context: *Context,
            on_key_press: ?*const (fn (context: *Context, key_params: KeyParams) void) = null,
            on_key_release: ?*const (fn (context: *Context, key_params: KeyParams) void) = null,
        };

        const Self = @This();

        var instance: ?*Self = null;

        allocator: std.mem.Allocator,
        window: *zglfw.Window,

        callbacks: Callbacks,

        // keyboard
        pressed_keys: std.AutoHashMap(zglfw.Key, void),
        release_queue: std.AutoHashMap(zglfw.Key, void),
        pressed_this_frame: std.AutoHashMapUnmanaged(zglfw.Key, void) = .empty,

        // mouse
        cursor_position: [2]f32,
        cursor_position_delta: [2]f32 = .{ 0, 0 },
        cursor_left_button_pressed: bool = false,
        cursor_right_button_pressed: bool = false,
        cursor_capture: CursorCapture = .while_left_button,
        cursor_captured: bool = false,
        focused: bool = true,
        focus_changed: bool = false,

        last_update_time: f64 = 0.0, // seconds

        pub fn init(
            allocator: std.mem.Allocator,
            window: *zglfw.Window,
            callbacks: Callbacks,
        ) !*Self {
            const input_controller = try allocator.create(Self);

            input_controller.* = .{
                .allocator = allocator,
                .window = window,

                .callbacks = callbacks,

                .pressed_keys = std.AutoHashMap(zglfw.Key, void).init(allocator),
                .release_queue = std.AutoHashMap(zglfw.Key, void).init(allocator),

                .cursor_position = getCursorPosition(window),
            };

            Self.instance = input_controller;

            return input_controller;
        }

        pub fn deinit(input_controller: *Self) void {
            if (Self.instance == input_controller) {
                _ = input_controller.window.setKeyCallback(null);
                Self.instance = null;
            }
            input_controller.pressed_keys.deinit();
            input_controller.release_queue.deinit();
            input_controller.pressed_this_frame.deinit(input_controller.allocator);
            input_controller.allocator.destroy(input_controller);
        }

        pub fn listenWindowEvents(input_controller: *Self) void {
            _ = input_controller.window.setKeyCallback(Self.onKeyCallback);
        }

        fn onKeyCallback(
            _: *zglfw.Window,
            key: zglfw.Key,
            _: i32,
            action: zglfw.Action,
            mods: zglfw.Mods,
        ) callconv(.c) void {
            if (Self.instance) |input_controller| {
                if (action == .press or action == .repeat) {
                    input_controller.pressed_keys.put(key, {}) catch |err| {
                        std.debug.print("InputController: failed {}\n", .{err});
                        return;
                    };
                    _ = input_controller.release_queue.remove(key);
                } else {
                    _ = input_controller.release_queue.put(key, {}) catch |err| {
                        std.debug.print("InputController: failed {}\n", .{err});
                        return;
                    };
                }

                if (action == .press) {
                    input_controller.pressed_this_frame.put(input_controller.allocator, key, {}) catch |err| {
                        std.debug.print("InputController: failed {}\n", .{err});
                        return;
                    };
                    if (input_controller.callbacks.on_key_press) |callback| {
                        callback(
                            input_controller.callbacks.context,
                            .{
                                .key = key,
                                .mods = mods,
                            },
                        );
                    }
                } else if (action == .release) {
                    if (input_controller.callbacks.on_key_release) |callback| {
                        callback(
                            input_controller.callbacks.context,
                            .{
                                .key = key,
                                .mods = mods,
                            },
                        );
                    }
                }
            } else {
                std.debug.print("InputController: instance is not found\n", .{});
            }
        }

        pub fn updateMouseState(input_controller: *Self, time_sec: f64) !void {
            const window = input_controller.window;
            const focused = window.getAttribute(.focused);
            input_controller.focus_changed = focused != input_controller.focused;
            input_controller.focused = focused;
            if (!focused) {
                input_controller.pressed_keys.clearRetainingCapacity();
                input_controller.release_queue.clearRetainingCapacity();
                input_controller.pressed_this_frame.clearRetainingCapacity();
            }
            input_controller.last_update_time = time_sec;
            input_controller.cursor_left_button_pressed = focused and window.getMouseButton(.left) != .release;
            input_controller.cursor_right_button_pressed = focused and window.getMouseButton(.right) != .release;
            const capture = focused and (input_controller.cursor_capture == .always or input_controller.cursor_left_button_pressed);
            const capture_changed = capture != input_controller.cursor_captured;
            if (capture_changed) {
                try window.setInputMode(.cursor, if (capture) zglfw.Cursor.Mode.disabled else zglfw.Cursor.Mode.normal);
                if (zglfw.rawMouseMotionSupported()) try window.setInputMode(.raw_mouse_motion, capture);
                input_controller.cursor_captured = capture;
            }
            const new_position = getCursorPosition(window);
            input_controller.cursor_position_delta = if (capture_changed or input_controller.focus_changed or !focused)
                .{ 0, 0 }
            else
                .{ new_position[0] - input_controller.cursor_position[0], new_position[1] - input_controller.cursor_position[1] };
            input_controller.cursor_position = new_position;
        }

        pub fn flushQueue(input_controller: *Self) void {
            var iterator = input_controller.release_queue.iterator();
            while (iterator.next()) |entry| {
                const key = entry.key_ptr.*;
                _ = input_controller.pressed_keys.remove(key);
            }
            input_controller.release_queue.clearRetainingCapacity();
            input_controller.pressed_this_frame.clearRetainingCapacity();
        }

        pub fn isKeyPressed(input_controller: *const Self, key: zglfw.Key) bool {
            return input_controller.pressed_keys.contains(key) and !input_controller.release_queue.contains(key);
        }

        pub fn wasKeyPressed(input_controller: *const Self, key: zglfw.Key) bool {
            return input_controller.pressed_this_frame.contains(key);
        }
    };
}

fn getCursorPosition(window: *zglfw.Window) [2]f32 {
    const position = window.getCursorPos();

    return .{
        @floatCast(position[0]),
        @floatCast(position[1]),
    };
}

pub const InputControllerGeneric = InputController(void);

test "press-release between frames keeps the press edge, ends held input, and repeats do not create edges" {
    var context: void = {};
    var input: InputControllerGeneric = .{
        .allocator = std.testing.allocator,
        .window = undefined,
        .callbacks = .{ .context = &context },
        .pressed_keys = std.AutoHashMap(zglfw.Key, void).init(std.testing.allocator),
        .release_queue = std.AutoHashMap(zglfw.Key, void).init(std.testing.allocator),
        .cursor_position = .{ 0, 0 },
    };
    defer input.pressed_keys.deinit();
    defer input.release_queue.deinit();
    defer input.pressed_this_frame.deinit(std.testing.allocator);
    InputControllerGeneric.instance = &input;
    defer InputControllerGeneric.instance = null;
    InputControllerGeneric.onKeyCallback(undefined, .escape, 0, .press, .{});
    InputControllerGeneric.onKeyCallback(undefined, .escape, 0, .release, .{});
    try std.testing.expect(input.wasKeyPressed(.escape));
    try std.testing.expect(!input.isKeyPressed(.escape));
    input.flushQueue();
    try std.testing.expect(!input.wasKeyPressed(.escape));
    InputControllerGeneric.onKeyCallback(undefined, .space, 0, .press, .{});
    input.flushQueue();
    InputControllerGeneric.onKeyCallback(undefined, .space, 0, .repeat, .{});
    try std.testing.expect(input.isKeyPressed(.space));
    try std.testing.expect(!input.wasKeyPressed(.space));
}
