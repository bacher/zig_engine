// Keep shared generation settings within the test module's import root.
test {
    _ = @import("persistence/tests.zig");
}
