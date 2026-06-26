const std = @import("std");
const zglfw = @import("zglfw");

pub const KeyParams = struct {
    key: zglfw.Key,
    mods: zglfw.Mods,
};

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

        // mouse
        cursor_position: [2]f32,
        cursor_position_delta: [2]f32 = .{ 0, 0 },
        cursor_left_button_pressed: bool = false,
        cursor_right_button_pressed: bool = false,

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
            input_controller.pressed_keys.deinit();
            input_controller.release_queue.deinit();
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

        pub fn updateMouseState(input_controller: *Self) !void {
            const window = input_controller.window;

            const new_position = getCursorPosition(window);

            const delta: [2]f32 = .{
                new_position[0] - input_controller.cursor_position[0],
                new_position[1] - input_controller.cursor_position[1],
            };

            if (delta[0] < -35 or delta[0] > 35 or delta[1] < -35 or delta[1] > 35) {
                input_controller.cursor_position_delta = .{ 0, 0 };
            } else {
                input_controller.cursor_position_delta = delta;
            }

            input_controller.cursor_position = new_position;

            const cursor_left_button_pressed = window.getMouseButton(.left) != .release;
            const cursor_right_button_pressed = window.getMouseButton(.right) != .release;

            if (input_controller.cursor_left_button_pressed != cursor_left_button_pressed) {
                input_controller.cursor_left_button_pressed = cursor_left_button_pressed;

                if (cursor_left_button_pressed) {
                    try window.setInputMode(.cursor, zglfw.Cursor.Mode.disabled);
                } else {
                    try window.setInputMode(.cursor, zglfw.Cursor.Mode.normal);
                }
            }

            input_controller.cursor_right_button_pressed = cursor_right_button_pressed;

            // if (input_controller.cursor_left_button_pressed) {
            //     std.debug.print("new_position x {d:5.0}, y {d:5.0}\n", .{ new_position[0], new_position[1] });
            // }
        }

        pub fn flushQueue(input_controller: *Self) void {
            var iterator = input_controller.release_queue.iterator();
            while (iterator.next()) |entry| {
                const key = entry.key_ptr.*;
                _ = input_controller.pressed_keys.remove(key);
            }
            input_controller.release_queue.clearRetainingCapacity();
        }

        pub fn isKeyPressed(input_controller: *const Self, key: zglfw.Key) bool {
            return input_controller.pressed_keys.getKey(key) != null;
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
