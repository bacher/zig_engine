// Keep shared generation settings within the test module's import root.
test {
    _ = @import("persistence/tests.zig");
    _ = @import("persistence/warehouses.zig");
    _ = @import("persistence/extraction_zones.zig");
}
