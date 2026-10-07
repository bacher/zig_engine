//! Explicit fixture for existing voxel regressions; production uses per-world layouts.
pub const layout = @import("engine").WorldLayout.init(.{ .size_in_chunks = .{ 512, 256, 8 } }) catch unreachable;
