//! Shared client/service blueprint display-name validation.
const std = @import("std");
pub const NameError = error{ InvalidUtf8, EmptyName, NameTooLong, InvalidNameCharacter };
fn whitespace(codepoint: u21) bool {
    return switch (codepoint) {
        9...13, 32, 0x85, 0xa0, 0x1680, 0x2000...0x200a, 0x2028, 0x2029, 0x202f, 0x205f, 0x3000 => true,
        else => false,
    };
}
/// Returns a borrowed, trimmed UTF-8 name; duplicate display names are allowed.
pub fn checkedName(bytes: []const u8) NameError![]const u8 {
    const view = std.unicode.Utf8View.init(bytes) catch return error.InvalidUtf8;
    var iterator = view.iterator();
    var start: ?usize = null;
    var end: usize = 0;
    while (iterator.nextCodepointSlice()) |sequence| {
        const cp = std.unicode.utf8Decode(sequence) catch return error.InvalidUtf8;
        if (cp < 32 or (cp >= 127 and cp <= 159) or cp == 0x2028 or cp == 0x2029) return error.InvalidNameCharacter;
        const offset = iterator.i - sequence.len;
        if (!whitespace(cp)) {
            if (start == null) start = offset;
            end = iterator.i;
        }
    }
    const name = bytes[(start orelse return error.EmptyName)..end];
    if (name.len > 400) return error.NameTooLong;
    iterator = (std.unicode.Utf8View.init(name) catch unreachable).iterator();
    var count: usize = 0;
    while (iterator.nextCodepoint()) |cp| {
        if (cp < 32 or (cp >= 127 and cp <= 159) or cp == 0x2028 or cp == 0x2029) return error.InvalidNameCharacter;
        count += 1;
        if (count > 100) return error.NameTooLong;
    }
    return name;
}
