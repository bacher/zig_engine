//! Bounded transient cell history for validating short player holds across snapshots.
const std = @import("std");

pub const History = struct {
    pub const capacity = 16;
    sequence: u64 = 0,
    recent: [capacity]u15 = @splat(0),

    pub fn record(self: *History, cell: u15) void {
        self.recent[self.sequence % capacity] = cell;
        self.sequence +%= 1;
    }

    pub fn unchangedSince(self: History, cell: u15, sequence: u64) bool {
        // Expired or reset history must never prove an old target unchanged.
        if (sequence > self.sequence or self.sequence - sequence > capacity) return false;
        var next = sequence;
        while (next < self.sequence) : (next += 1) {
            if (self.recent[next % capacity] == cell) return false;
        }
        return true;
    }
};

test "unrelated edits preserve a target while replacement and expired history invalidate it" {
    var history: History = .{};
    history.record(1);
    const start = history.sequence;
    for (0..History.capacity) |_| history.record(2);
    try std.testing.expect(history.unchangedSince(1, start));
    history.record(2);
    try std.testing.expect(!history.unchangedSince(1, start));
    const fresh = history.sequence;
    history.record(1); // Removal followed by replacing the same material is still a change.
    history.record(1);
    try std.testing.expect(!history.unchangedSince(1, fresh));
    try std.testing.expect(!History.unchangedSince(.{}, 1, fresh));
}
