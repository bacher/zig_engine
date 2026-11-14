//! Shared, typed construction identities. These values cross publication and
//! capture boundaries; they do not grant access to the owning mutable state.
pub const ObjectKind = enum(u8) { construction, warehouse };

pub const Identity = struct {
    world_session: u64,
    kind: ObjectKind = .construction,
    id: u64,
    lifetime: u64,

    pub fn eql(a: Identity, b: Identity) bool {
        return a.world_session == b.world_session and a.kind == b.kind and
            a.id == b.id and a.lifetime == b.lifetime;
    }
};

pub const Phase = enum(u8) { building, materializing, complete };
pub const StorageOwner = enum { simulation, world_data };

pub const CommandIdentity = struct {
    world_session: u64,
    client_session: u64,
    sequence: u64,
};

test "object type, session and registration lifetime isolate equal numeric IDs" {
    const std = @import("std");
    const first: Identity = .{ .world_session = 1, .id = 7, .lifetime = 7 };
    try std.testing.expect(first.eql(first));
    var other = first;
    other.kind = .warehouse;
    try std.testing.expect(!first.eql(other));
    other = first;
    other.lifetime += 1;
    try std.testing.expect(!first.eql(other));
    other = first;
    other.world_session += 1;
    try std.testing.expect(!first.eql(other));
}
