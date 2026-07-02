// re-export some deps
pub const zgpu = @import("zgpu");
pub const zgui = @import("zgui");
pub const zglfw = @import("zglfw");

pub const Engine = @import("./engine.zig").Engine;
pub const WindowContext = @import("./glue.zig").WindowContext;
pub const GameObject = @import("./game_object.zig").GameObject;
pub const GameObjectGroup = @import("./game_object_group.zig").GameObjectGroup;
pub const Scene = @import("./scene.zig").Scene;
pub const tube = @import("./shape_generation/tube.zig");
pub const utils = @import("./utils.zig");
