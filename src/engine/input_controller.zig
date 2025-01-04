const std = @import("std");
const zglfw = @import("zglfw");

pub const InputController = struct {
    var instance: ?*InputController = null;

    allocator: std.mem.Allocator,
    pressed_keys: std.AutoHashMap(zglfw.Key, void),
    release_queue: std.AutoHashMap(zglfw.Key, void),

    pub fn init(allocator: std.mem.Allocator) !*InputController {
        const input_controller = try allocator.create(InputController);

        input_controller.* = .{
            .allocator = allocator,
            .pressed_keys = std.AutoHashMap(zglfw.Key, void).init(allocator),
            .release_queue = std.AutoHashMap(zglfw.Key, void).init(allocator),
        };

        InputController.instance = input_controller;

        return input_controller;
    }

    pub fn deinit(input_controller: *InputController) void {
        input_controller.pressed_keys.deinit();
        input_controller.release_queue.deinit();
        input_controller.allocator.destroy(input_controller);
    }

    pub fn listenWindowEvents(input_controller: *InputController, window: *zglfw.Window) void {
        _ = input_controller;
        _ = window.setKeyCallback(InputController.onKeyCallback);
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
