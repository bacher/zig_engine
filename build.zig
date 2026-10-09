const std = @import("std");

pub fn build(b: *std.Build) void {
    // Standard target options allows the person running `zig build` to choose
    // what target to build for. Here we do not override the defaults, which
    // means any target is allowed, and the default is native. Other options
    // for restricting supported target set are available.
    const target = b.standardTargetOptions(.{});

    // Standard optimization options allow the person running `zig build` to select
    // between Debug, ReleaseSafe, ReleaseFast, and ReleaseSmall. Here we do not
    // set a preferred release mode, allowing the user to decide how to optimize.
    const optimize = b.standardOptimizeOption(.{});

    // Each application compiles an engine module with its own static topology.
    const engine_lib = createEngineLibrary(b, target, optimize, "engine", "src/demo_app/engine_config.zig");
    const voxel_engine_lib = createEngineLibrary(b, target, optimize, "engine_wrapped", "src/voxel_app/engine_config.zig");
    const engines = [_]*std.Build.Step.Compile{ engine_lib, voxel_engine_lib };
    for (engines) |library| b.installArtifact(library);

    // debug app

    const demo_exe = b.addExecutable(.{
        .name = "zig_engine_demo_app",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/demo_app/main.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });

    demo_exe.root_module.linkLibrary(engine_lib);
    demo_exe.root_module.addImport("engine", engine_lib.root_module);

    // voxel app

    const voxel_exe = b.addExecutable(.{
        .name = "zig_engine_voxel_app",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/voxel_app/main.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });

    voxel_exe.root_module.linkLibrary(voxel_engine_lib);
    voxel_exe.root_module.addImport("engine", voxel_engine_lib.root_module);

    // Deps start

    const zglfw = b.dependency("zglfw", .{
        .target = target,
        .optimize = optimize,
    });
    for (engines) |library| library.root_module.addImport("zglfw", zglfw.module("root"));
    for (engines) |library| library.root_module.linkLibrary(zglfw.artifact("glfw"));

    for (engines) |library| @import("zgpu").addLibraryPathsTo(library);
    const zgpu = b.dependency("zgpu", .{
        .target = target,
        .optimize = optimize,
    });
    for (engines) |library| library.root_module.addImport("zgpu", zgpu.module("root"));
    for (engines) |library| library.root_module.linkLibrary(zgpu.artifact("zdawn"));

    const zgui = b.dependency("zgui", .{
        .target = target,
        .optimize = optimize,
        .backend = .glfw_wgpu,
    });
    for (engines) |library| library.root_module.addImport("zgui", zgui.module("root"));
    for (engines) |library| library.root_module.linkLibrary(zgui.artifact("imgui"));

    const zmath = b.dependency("zmath", .{
        .target = target,
        .optimize = optimize,
    });
    for (engines) |library| library.root_module.addImport("zmath", zmath.module("root"));
    demo_exe.root_module.addImport("zmath", zmath.module("root"));
    voxel_exe.root_module.addImport("zmath", zmath.module("root"));

    const zstbi = b.dependency("zstbi", .{
        .target = target,
        .optimize = optimize,
    });
    for (engines) |library| library.root_module.addImport("zstbi", zstbi.module("root"));

    // GLTF loader
    const gltf_loader_module = b.dependency("gltf_loader", .{
        .target = target,
        .optimize = optimize,
    }).module("root");
    gltf_loader_module.addImport("zstbi", zstbi.module("root"));

    for (engines) |library| library.root_module.addImport("gltf_loader", gltf_loader_module);
    demo_exe.root_module.addImport("gltf_loader", gltf_loader_module);
    voxel_exe.root_module.addImport("gltf_loader", gltf_loader_module);

    // Local modules

    const debug_module = b.addModule("debug", .{
        .root_source_file = b.path("src/modules/debug/debug.zig"),
    });
    debug_module.addImport("zmath", zmath.module("root"));
    demo_exe.root_module.addImport("debug", debug_module);
    voxel_exe.root_module.addImport("debug", debug_module);

    // Deps end

    const content_path_name = "content";
    const install_content_step = b.addInstallDirectory(.{
        .source_dir = b.path(content_path_name),
        .install_dir = .{ .custom = "" },
        .install_subdir = b.pathJoin(&.{ "bin", content_path_name }),
    });

    // Demo app options
    const exe_options = b.addOptions();
    demo_exe.root_module.addOptions("build_options", exe_options);
    exe_options.addOption([]const u8, "content_dir", content_path_name);
    demo_exe.step.dependOn(&install_content_step.step);

    // Voxel app options
    const voxel_exe_options = b.addOptions();
    voxel_exe.root_module.addOptions("build_options", voxel_exe_options);
    voxel_exe_options.addOption([]const u8, "content_dir", content_path_name);
    voxel_exe.step.dependOn(&install_content_step.step);

    // This declares intent for the executable to be installed into the
    // standard location when the user invokes the "install" step (the default
    // step when running `zig build`).
    b.installArtifact(demo_exe);
    b.installArtifact(voxel_exe);

    // This *creates* a Run step in the build graph, to be executed when another
    // step is evaluated that depends on it. The next line below will establish
    // such a dependency.
    const run_cmd = b.addRunArtifact(demo_exe);
    const run_voxel_cmd = b.addRunArtifact(voxel_exe);

    // By making the run step depend on the install step, it will be run from the
    // installation directory rather than directly from within the cache directory.
    // This is not necessary, however, if the application depends on other installed
    // files, this ensures they will be present and in the expected location.
    run_cmd.step.dependOn(b.getInstallStep());
    run_voxel_cmd.step.dependOn(b.getInstallStep());

    // This allows the user to pass arguments to the application in the build
    // command itself, like this: `zig build run -- arg1 arg2 etc`
    if (b.args) |args| {
        run_cmd.addArgs(args);
    }

    const run_step = b.step("run", "Run the demo app");
    run_step.dependOn(&run_cmd.step);

    const run_voxel_step = b.step("run_voxel", "Run the voxel app");
    run_voxel_step.dependOn(&run_voxel_cmd.step);

    const exe_unit_tests = b.addTest(.{
        .root_module = demo_exe.root_module,
    });
    exe_unit_tests.root_module.addImport("zmath", zmath.module("root"));

    const voxel_exe_unit_tests = b.addTest(.{
        .root_module = voxel_exe.root_module,
    });

    const engine_utils_unit_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/engine/utils.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "zmath", .module = zmath.module("root") },
                .{ .name = "debug", .module = debug_module },
            },
        }),
    });

    const space_tree_unit_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/engine/space_tree.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "zmath", .module = zmath.module("root") },
                .{ .name = "debug", .module = debug_module },
            },
        }),
    });

    const dynamic_slot_buffer_manager_unit_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/engine/voxel/DynamicSlotBufferManager.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });

    const voxel_utils_unit_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/engine/voxel/voxel_utils.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });

    const slot_buffer_manager_unit_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/engine/voxel/SlotBufferManager.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });

    const run_exe_unit_tests = b.addRunArtifact(exe_unit_tests);
    const voxel_grid_unit_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/engine/voxel_tests.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "zgpu", .module = zgpu.module("root") },
                .{ .name = "zmath", .module = zmath.module("root") },
            },
        }),
    });
    const run_voxel_grid_unit_tests = b.addRunArtifact(voxel_grid_unit_tests);
    const run_voxel_exe_unit_tests = b.addRunArtifact(voxel_exe_unit_tests);
    const run_engine_utils_unit_tests = b.addRunArtifact(engine_utils_unit_tests);
    const run_space_tree_unit_tests = b.addRunArtifact(space_tree_unit_tests);
    const run_dynamic_slot_buffer_manager_unit_tests = b.addRunArtifact(dynamic_slot_buffer_manager_unit_tests);
    const run_voxel_utils_unit_tests = b.addRunArtifact(voxel_utils_unit_tests);
    const run_slot_buffer_manager_unit_tests = b.addRunArtifact(slot_buffer_manager_unit_tests);

    const test_step = b.step("test", "Run unit tests for both application wrapping modes");
    const gpu_test_step = b.step("test-gpu", "Validate world pipelines and coordinate arithmetic for both compiled wrapping modes with headless Dawn");
    for (engines) |library| {
        const engine_config = library.root_module.import_table.get("engine_config").?;
        const render_coordinates_tests = b.addTest(.{
            .root_module = b.createModule(.{
                .root_source_file = b.path("src/engine/render_coordinates_tests.zig"),
                .target = target,
                .optimize = optimize,
                .imports = &.{
                    .{ .name = "engine_config", .module = engine_config },
                    .{ .name = "zmath", .module = zmath.module("root") },
                    .{ .name = "debug", .module = debug_module },
                },
            }),
        });
        test_step.dependOn(&b.addRunArtifact(render_coordinates_tests).step);
        const hierarchy_tests = b.addTest(.{ .root_module = library.root_module });
        test_step.dependOn(&b.addRunArtifact(hierarchy_tests).step);

        // GPU checks are explicit so CPU tests work without a graphics adapter.
        const world_shader_tests = b.addTest(.{
            .root_module = b.createModule(.{
                .root_source_file = b.path("src/engine/world_shader_tests.zig"),
                .target = target,
                .optimize = optimize,
                .imports = &.{
                    .{ .name = "engine_config", .module = engine_config },
                    .{ .name = "zgpu", .module = zgpu.module("root") },
                    .{ .name = "zglfw", .module = zglfw.module("root") },
                    .{ .name = "zgui", .module = zgui.module("root") },
                    .{ .name = "zstbi", .module = zstbi.module("root") },
                    .{ .name = "gltf_loader", .module = gltf_loader_module },
                    .{ .name = "zmath", .module = zmath.module("root") },
                    .{ .name = "debug", .module = debug_module },
                },
            }),
        });
        @import("zgpu").addLibraryPathsTo(world_shader_tests);
        world_shader_tests.root_module.linkLibrary(library);
        gpu_test_step.dependOn(&b.addRunArtifact(world_shader_tests).step);
    }
    test_step.dependOn(&run_voxel_grid_unit_tests.step);
    test_step.dependOn(&run_exe_unit_tests.step);
    test_step.dependOn(&run_voxel_exe_unit_tests.step);
    test_step.dependOn(&run_engine_utils_unit_tests.step);
    test_step.dependOn(&run_space_tree_unit_tests.step);
    test_step.dependOn(&run_dynamic_slot_buffer_manager_unit_tests.step);
    test_step.dependOn(&run_voxel_utils_unit_tests.step);
    test_step.dependOn(&run_slot_buffer_manager_unit_tests.step);
}

/// Inject application topology into the engine itself, including its library/test roots.
fn createEngineLibrary(
    b: *std.Build,
    target: std.Build.ResolvedTarget,
    optimize: std.builtin.OptimizeMode,
    name: []const u8,
    config_path: []const u8,
) *std.Build.Step.Compile {
    const engine_config = b.createModule(.{ .root_source_file = b.path(config_path) });
    return b.addLibrary(.{
        .linkage = .static,
        .name = name,
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/engine/root.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{.{ .name = "engine_config", .module = engine_config }},
        }),
    });
}
