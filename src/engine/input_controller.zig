const std = @import("std");
const zglfw = @import("zglfw");

pub const InputController = struct {
    var instance: ?*InputController = null;

    allocator: std.mem.Allocator,
    window: *zglfw.Window,

    // keyboard
    pressed_keys: std.AutoHashMap(zglfw.Key, void),
    release_queue: std.AutoHashMap(zglfw.Key, void),

    // mouse
    cursor_position: [2]f32,
    cursor_position_delta: [2]f32 = .{ 0, 0 },
    cursor_left_button_pressed: bool = false,
    cursor_right_button_pressed: bool = false,

    pub fn init(allocator: std.mem.Allocator, window: *zglfw.Window) !*InputController {
        const input_controller = try allocator.create(InputController);

        input_controller.* = .{
            .allocator = allocator,
            .window = window,
            .pressed_keys = std.AutoHashMap(zglfw.Key, void).init(allocator),
            .release_queue = std.AutoHashMap(zglfw.Key, void).init(allocator),

            .cursor_position = getCursorPosition(window),
        };

        InputController.instance = input_controller;

        return input_controller;
    }

    pub fn deinit(input_controller: *InputController) void {
        input_controller.pressed_keys.deinit();
        input_controller.release_queue.deinit();
        input_controller.allocator.destroy(input_controller);
    }

    pub fn listenWindowEvents(input_controller: *InputController) void {
        _ = input_controller.window.setKeyCallback(InputController.onKeyCallback);
    }

    fn onKeyCallback(
        _: *zglfw.Window,
        key: zglfw.Key,
        _: i32,
        action: zglfw.Action,
        _: zglfw.Mods,
    ) callconv(.C) void {
        if (InputController.instance) |input_controller| {
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
        } else {
            std.debug.print("InputController: instance is not found\n", .{});
        }
    }

    pub fn updateMouseState(input_controller: *InputController) void {
        const window = input_controller.window;

        const new_position = getCursorPosition(window);

        input_controller.cursor_position_delta = .{
            new_position[0] - input_controller.cursor_position[0],
            new_position[1] - input_controller.cursor_position[1],
        };

        input_controller.cursor_position = new_position;

        input_controller.cursor_left_button_pressed = window.getMouseButton(.left) != .release;
        input_controller.cursor_right_button_pressed = window.getMouseButton(.right) != .release;
    }

    pub fn flushQueue(input_controller: *InputController) void {
        var iterator = input_controller.release_queue.iterator();
        while (iterator.next()) |entry| {
            const key = entry.key_ptr.*;
            _ = input_controller.pressed_keys.remove(key);
        }
        input_controller.release_queue.clearRetainingCapacity();
    }

    pub fn isKeyPressed(input_controller: *const InputController, key: zglfw.Key) bool {
        return input_controller.pressed_keys.getKey(key) != null;
    }
};

fn getCursorPosition(window: *zglfw.Window) [2]f32 {
    const position = window.getCursorPos();

    return .{
        @floatCast(position[0]),
        @floatCast(position[1]),
    };
}
