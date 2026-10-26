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
    }
    return null;
}
