//! Save selection is explicit: opening never creates or replaces a missing world.
const std = @import("std");
pub const Mode = enum { open, create, ephemeral };
pub const Options = struct {
    mode: Mode = .open,
    path: []const u8 = "saves/default",
    player_id: u64 = 1,
    help: bool = false,
};
pub const usage =
    \\Usage: zig_engine_voxel_app [--world PATH | --create-world PATH | --ephemeral] [--player-id ID]
    \\  --world PATH         Open an existing world (default: saves/default).
    \\  --create-world PATH  Create a new world; never overwrite an existing save.
    \\  --ephemeral          Run without persistence; all changes are lost on exit.
    \\  --player-id ID       Local u64 player identity (default: 1; no Steam login yet).
    \\Paths are relative to the directory from which the application was launched.
    \\
;
pub fn parse(args: []const []const u8) !Options {
    var result: Options = .{};
    var selected = false;
    var identity = false;
    var i: usize = 0;
    while (i < args.len) : (i += 1) {
        const arg = args[i];
        if (std.mem.eql(u8, arg, "--help")) {
            result.help = true;
        } else if (std.mem.eql(u8, arg, "--ephemeral")) {
            if (selected) return error.ConflictingWorldOptions;
            selected = true;
            result.mode = .ephemeral;
        } else if (std.mem.eql(u8, arg, "--world") or std.mem.eql(u8, arg, "--create-world")) {
            if (selected) return error.ConflictingWorldOptions;
            selected = true;
            i += 1;
            if (i == args.len or args[i].len == 0 or std.mem.indexOfScalar(u8, args[i], 0) != null) return error.MissingWorldPath;
            result.path = args[i];
            result.mode = if (std.mem.eql(u8, arg, "--world")) .open else .create;
        } else if (std.mem.eql(u8, arg, "--player-id")) {
            if (identity) return error.DuplicatePlayerIdentity;
            identity = true;
            i += 1;
            if (i == args.len) return error.MissingPlayerIdentity;
            result.player_id = std.fmt.parseInt(u64, args[i], 10) catch return error.InvalidPlayerIdentity;
        } else return error.UnknownArgument;
    }
    return result;
}

test "opening never implies creation and world modes cannot be combined" {
    try std.testing.expectEqual(Mode.open, (try parse(&.{})).mode);
    const create = try parse(&.{ "--create-world", "new-world", "--player-id", "18446744073709551615" });
    try std.testing.expectEqual(Mode.create, create.mode);
    try std.testing.expectEqual(std.math.maxInt(u64), create.player_id);
    try std.testing.expectError(error.ConflictingWorldOptions, parse(&.{ "--world", "saved", "--create-world", "saved" }));
    try std.testing.expectError(error.ConflictingWorldOptions, parse(&.{ "--ephemeral", "--world", "saved" }));
    try std.testing.expectError(error.MissingWorldPath, parse(&.{"--world"}));
    try std.testing.expectError(error.InvalidPlayerIdentity, parse(&.{ "--player-id", "18446744073709551616" }));
}
