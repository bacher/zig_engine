//! Shared immutable-floor validation. Callers validate the whole write set before
//! publishing blocks, metadata, inventory, or revisions.
const rules = @import("block_rules.zig");
const BlockType = rules.BlockType;

pub const CanonicalFloor = struct {
    context: *const anyopaque,
    immutable_at: *const fn (*const anyopaque, [3]u32) bool,

    pub fn contains(self: CanonicalFloor, block: [3]u32) bool {
        return self.immutable_at(self.context, block);
    }
};

pub const Write = struct { block: [3]u32, material: BlockType };

/// Generation/restoration write original storage directly; runtime mutation may
/// neither change existing deeprock nor introduce it at another coordinate.
pub fn allowsMaterialChange(existing: BlockType, replacement: BlockType) bool {
    return existing != .deeprock and replacement != .deeprock;
}

pub fn validateWrites(reader: rules.Reader, writes: []const Write) ?rules.Failure {
    for (writes) |write| {
        const cell: rules.Cell = .{ write.block[0], write.block[1], write.block[2] };
        if (write.material == .deeprock or reader.isImmutable(cell))
            return .{ .reason = .immutable_cell, .subject = cell };
        if (reader.mutation_allowed) |check| if (check(reader.context, write.block, write.material)) |failure| return failure;
    }
    return null;
}

test "owner mutation guard covers every write in a prepared indirect plan" {
    const std = @import("std");
    const Fixture = struct {
        calls: usize = 0,
        fn read(_: *anyopaque, _: [3]u32) ?BlockType {
            return .none;
        }
        fn allow(raw: *anyopaque, block: [3]u32, _: BlockType) ?rules.Failure {
            const self: *@This() = @ptrCast(@alignCast(raw));
            self.calls += 1;
            return if (block[0] == 11) .{ .reason = .would_invalidate_structure, .subject = .{ block[0], block[1], block[2] } } else null;
        }
    };
    var fixture: Fixture = .{};
    const reader: rules.Reader = .{ .layout = &@import("test_world.zig").layout, .context = &fixture, .block_at = Fixture.read, .mutation_allowed = Fixture.allow };
    const failure = validateWrites(reader, &.{ .{ .block = .{ 10, 10, 10 }, .material = .planks }, .{ .block = .{ 11, 10, 10 }, .material = .none } }).?;
    try std.testing.expectEqual(rules.Reason.would_invalidate_structure, failure.reason);
    try std.testing.expectEqual(@as(usize, 2), fixture.calls);
    try std.testing.expectEqual(@as(i64, 11), failure.subject[0]);
}
