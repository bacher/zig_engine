const std = @import("std");
const Geography = @import("current/generation_geography.zig").Geography;
const env = @import("current/world_environment.zig");
const hash = @import("current/generation_hash.zig");
const Perlin = @import("current/perlin_noise.zig").PerlinNoise;
const width: u32 = 65536;
const height: u32 = 32768;
const depth: u32 = 1024;
const side: usize = 512;
const seed: u64 = 12345;
const variants = [_][]const u8{ "legacy", "current", "A32_8", "B48_12", "C40_10" };
const Site = struct { label: []const u8, x: u32, y: u32 };
const Start = struct { variant: []const u8, block: ?[3]u32 };

fn oldHeight(x: i64, y: u32) u16 {
    const canonical = hash.wrappedX(x, width);
    const xf: f64 = @floatFromInt(canonical);
    const yf: f64 = @floatFromInt(y);
    const noise = Perlin.init(seed);
    var frequency: f64 = 1.0 / 192.0;
    var amplitude: f64 = 1.0;
    var value: f64 = 0.0;
    var sum: f64 = 0.0;
    for (0..4) |_| {
        const period = @max(1.0, @round(@as(f64, @floatFromInt(width)) * frequency));
        value += noise.sample2DPeriodicX(xf * (period / @as(f64, @floatFromInt(width))), yf * frequency, @intFromFloat(period)) * amplitude;
        sum += amplitude;
        frequency *= 2.0;
        amplitude *= 0.5;
    }
    return @intFromFloat(std.math.clamp(@round(512.0 + value / sum * 48.0), 1.0, depth));
}

fn candidateHeight(g: *const Geography, e: env.ColumnEnvironment, x: i64, y: u32, hills_span: i64, detail_span: i64) u16 {
    if (e.water_present) return @intCast(e.terrain_height);
    const cx = hash.wrappedX(x, width);
    const broad = hash.field2(hash.mix(g.seed ^ 0x5445525241494e), cx, y, width, @max(64, height / 16));
    const hills = hash.field2(hash.mix(g.seed ^ 0x48494c4c53), cx, y, width, 192);
    const detail = hash.field2(hash.mix(g.seed ^ 0x44455441494c), cx, y, width, 64);
    const land_height = 1 + @divTrunc((broad + 65535) * 48 + (hills + 65535) * hills_span + (detail + 65535) * detail_span, 131070);
    const coast_ramp: i64 = @intCast(@min(65535, @as(u64, e.coast_distance) * 65535 / 96));
    const uplift = @divTrunc(@as(i64, e.mountain_strength) * 320, 65535);
    const elevation = @divTrunc(land_height * coast_ramp, 65535) + uplift;
    return @intCast(std.math.clamp(@as(i64, g.sea_level) + @max(1, elevation), 3, depth - 12));
}

fn variantHeight(g: *const Geography, e: env.ColumnEnvironment, x: i64, y: u32, variant: usize) u16 {
    return switch (variant) {
        0 => oldHeight(x, y),
        1 => @intCast(e.terrain_height),
        2 => candidateHeight(g, e, x, y, 32, 8),
        3 => candidateHeight(g, e, x, y, 48, 12),
        4 => candidateHeight(g, e, x, y, 40, 10),
        else => unreachable,
    };
}

fn findStart(g: *const Geography, climate: env.ClimateField, variant: usize, local_filter: bool) ?[3]u32 {
    for (g.owners, 0..) |owner, i| {
        if (owner == 0) continue;
        const x: u32 = @intCast(i % g.macro_width * 128 + 64);
        const y: u32 = @intCast(i / g.macro_width * 128 + 64);
        const e = g.atWithClimate(climate, x, y);
        if (e.climate != .temperate or e.relief != .lowland or e.vegetation != .meadow or e.coast_distance < 128 or e.surface_cover != .soil) continue;
        const h = variantHeight(g, e, x, y, variant);
        var safe = true;
        for ([_][2]i32{ .{ -64, 0 }, .{ 64, 0 }, .{ 0, -64 }, .{ 0, 64 } }) |offset| {
            const nx = @as(i64, x) + offset[0];
            const ny: u32 = @intCast(@as(i64, y) + offset[1]);
            const near = g.atWithClimate(climate, nx, ny);
            const nh = variantHeight(g, near, nx, ny, variant);
            if (near.water_present or near.landmass_id != owner or (!local_filter and @abs(@as(i64, nh) - h) > 4)) safe = false;
        }
        if (local_filter) for ([_][2]i32{ .{ -1, 0 }, .{ 1, 0 }, .{ 0, -1 }, .{ 0, 1 } }) |direction| {
            var previous = h;
            for (1..5) |distance| {
                const nx = @as(i64, x) + @as(i64, direction[0]) * @as(i64, @intCast(distance));
                const ny: u32 = @intCast(@as(i64, y) + @as(i64, direction[1]) * @as(i64, @intCast(distance)));
                const near = g.atWithClimate(climate, nx, ny);
                const nh = variantHeight(g, near, nx, ny, variant);
                if (near.water_present or near.landmass_id != owner or @abs(@as(i64, nh) - h) > 1 or @abs(@as(i64, nh) - previous) > 1) safe = false;
                previous = nh;
            }
        };
        if (safe) return .{ x, y, h };
    }
    return null;
}

fn inlandSite(g: *const Geography, climate: env.ClimateField, desired: env.ClimateId, label: []const u8) !Site {
    for (g.owners, 0..) |owner, i| {
        if (owner == 0 or g.coastal_distance[i] < 6) continue;
        const x: u32 = @intCast(i % g.macro_width * 128 + 64);
        const y: u32 = @intCast(i / g.macro_width * 128 + 64);
        if (y < 256 or y + 256 >= height) continue;
        const e = g.atWithClimate(climate, x, y);
        if (e.climate != desired or e.mountain_strength != 0 or !g.protectedBox(x, y, 256, 256, owner)) continue;
        var suitable = true;
        for ([_]i32{ -256, 0, 255 }) |dy| for ([_]i32{ -256, 0, 255 }) |dx| {
            const near = g.atWithClimate(climate, @as(i64, x) + dx, @intCast(@as(i64, y) + dy));
            if (near.climate != desired or near.mountain_strength != 0 or near.water_present) suitable = false;
        };
        if (suitable) return .{ .label = label, .x = x, .y = y };
    }
    return error.NoInlandSite;
}

fn writePatch(init: std.process.Init, a: std.mem.Allocator, g: *const Geography, climate: env.ClimateField, site: Site, dir: []const u8) !void {
    // Fixed 18-byte records: five LE u16 heights, four u8 land/climate/relief/owner,
    // LE u16 coast and mountain_strength. Row-major, local Y increasing.
    const bytes = try a.alloc(u8, side * side * 18);
    defer a.free(bytes);
    for (0..side) |ly| for (0..side) |lx| {
        const x = @as(i64, site.x) + @as(i64, @intCast(lx)) - 256;
        const y: u32 = @intCast(@as(i64, site.y) + @as(i64, @intCast(ly)) - 256);
        const e = g.atWithClimate(climate, x, y);
        const record = bytes[(ly * side + lx) * 18 ..][0..18];
        for (0..5) |v| std.mem.writeInt(u16, record[v * 2 ..][0..2], variantHeight(g, e, x, y, v), .little);
        record[10] = @intFromBool(!e.water_present);
        record[11] = @intFromEnum(e.climate);
        record[12] = @intFromEnum(e.relief);
        record[13] = e.landmass_id;
        std.mem.writeInt(u16, record[14..16], @intCast(e.coast_distance), .little);
        std.mem.writeInt(u16, record[16..18], e.mountain_strength, .little);
    };
    const path = try std.fmt.allocPrint(a, "{s}/{s}.bin", .{ dir, site.label });
    defer a.free(path);
    try std.Io.Dir.cwd().writeFile(init.io, .{ .sub_path = path, .data = bytes });
}

pub fn main(init: std.process.Init) !void {
    const a = init.gpa;
    const args = try init.minimal.args.toSlice(init.arena.allocator());
    const dir = if (args.len > 1) args[1] else "/private/tmp/terrain-tuning-probe/results";
    var g = try Geography.init(a, hash.stream(seed, .continents, 0), .{ width, height, depth }, .{});
    defer g.deinit(a);
    const climate = env.ClimateField{ .seed = hash.stream(seed, .climate, 0), .width = width, .height = height, .displacement = 96 };
    var sites: std.ArrayList(Site) = .empty;
    defer sites.deinit(a);
    try sites.append(a, .{ .label = "fixed_spawn", .x = 64, .y = 6592 });
    try sites.append(a, try inlandSite(&g, climate, .steppe, "inland_steppe"));
    try sites.append(a, try inlandSite(&g, climate, .temperate, "inland_temperate"));
    try sites.append(a, try inlandSite(&g, climate, .desert, "inland_desert"));
    var starts: [8]Start = undefined;
    for (1..5) |v| for (0..2) |local| {
        const block = findStart(&g, climate, v, local == 1);
        const label = try std.fmt.allocPrint(init.arena.allocator(), "{s}_{s}", .{ variants[v], if (local == 0) "old_filter" else "local_filter" });
        starts[(v - 1) * 2 + local] = .{ .variant = label, .block = block };
        if (v == 1 and local == 0) std.debug.assert(std.meta.eql(block.?, [3]u32{ 64, 6592, 429 }));
        if (block) |b| {
            var exists = false;
            for (sites.items) |site| if (site.x == b[0] and site.y == b[1]) {
                exists = true;
                break;
            };
            if (!exists) try sites.append(a, .{ .label = label, .x = b[0], .y = b[1] });
        }
    };
    for (sites.items) |site| try writePatch(init, a, &g, climate, site, dir);
    const metadata = try std.json.Stringify.valueAlloc(a, .{
        .seed = seed,
        .attempt = 0,
        .size_blocks = [3]u32{ width, height, depth },
        .side = side,
        .variants = variants,
        .sites = sites.items,
        .provisional_starts = starts,
        .layout = "row-major Y ascending; 18-byte records: legacy,current,A32_8,B48_12,C40_10 heights u16LE; land,climate,relief,owner u8; coast,mountain_strength u16LE",
        .legacy = "Exact default legacy 192-block/4-octave Perlin sampling; seed12345; amplitude48;base512; periods rounded per octave.",
        .candidates = "Same broad,land mask,coast,mountain as current. Hills unsigned field192 seed mix(geography.seed^0x48494c4c53); detail unsigned field64 with current detail seed. Spans32/8,48/12,40/10; one /131070 floor after weighted broad+hills+detail, then coast-ramp floor.",
        .selection = "Fixed current accepted spawn plus first macro center per steppe/temperate/desert with coarse distance>=6, protected512 patch, zero mountain at9 probes; provisional per-candidate findStart has old ±64 height<=4 filter or local filter retaining ±64 dry/owner plus cardinal distances1..4 center/step deltas<=1; deposit acceptance not run.",
    }, .{ .whitespace = .indent_2 });
    defer a.free(metadata);
    const path = try std.fmt.allocPrint(a, "{s}/metadata.json", .{dir});
    defer a.free(path);
    try std.Io.Dir.cwd().writeFile(init.io, .{ .sub_path = path, .data = metadata });
    std.debug.print("sites={d}; one geography preparation; output={s}\n", .{ sites.items.len, dir });
}
