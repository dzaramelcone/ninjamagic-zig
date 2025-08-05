const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const main = b.createModule(.{
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
    });

    // External deps.
    const zzz = b.dependency("zzz", .{
        .target = target,
        .optimize = optimize,
    }).module("zzz");

    const ws = b.dependency("websocket", .{
        .target = target,
        .optimize = optimize,
    }).module("websocket");

    const zqlite = b.dependency("zqlite", .{
        .target = target,
        .optimize = optimize,
    });
    main.addImport("zqlite", zqlite.module("zqlite"));
    const default_sqlite3_build = [_][]const u8{"-std=c99"};
    main.addCSourceFile(.{
        .file = b.path("embed/sqlite/sqlite3.c"),
        .flags = &default_sqlite3_build,
    });
    main.link_libc = true;

    // Internal deps.
    const embed = b.addModule("embed", .{
        .root_source_file = b.path("embed/module.zig"),
        .target = target,
        .optimize = optimize,
    });

    const core = b.addModule("core", .{
        .root_source_file = b.path("src/core/module.zig"),
        .target = target,
        .optimize = optimize,
    });

    const net = b.addModule("net", .{
        .root_source_file = b.path("src/net/module.zig"),
        .target = target,
        .optimize = optimize,
    });

    const sys = b.addModule("sys", .{
        .root_source_file = b.path("src/sys/module.zig"),
        .target = target,
        .optimize = optimize,
    });

    embed.addImport("zzz", zzz);

    core.addImport("zzz", zzz);
    core.addImport("websocket", ws);

    net.addImport("zzz", zzz);
    net.addImport("websocket", ws);
    net.addImport("core", core);
    net.addImport("embed", embed);

    sys.addImport("core", core);
    sys.addImport("websocket", ws);

    main.addImport("zzz", zzz);
    main.addImport("websocket", ws);
    main.addImport("core", core);
    main.addImport("net", net);
    main.addImport("sys", sys);
    const exe = b.addExecutable(.{
        .name = "mud",
        .root_module = main,
    });
    b.installArtifact(exe);

    const run_cmd = b.addRunArtifact(exe);
    run_cmd.step.dependOn(b.getInstallStep());
    if (b.args) |args| {
        run_cmd.addArgs(args);
    }
    const run_step = b.step("run", "Run the app");
    run_step.dependOn(&run_cmd.step);

    const tests = b.addTest(.{
        .root_module = main,
        .test_runner = .{ .path = b.path("test_runner.zig"), .mode = .simple },
    });
    tests.root_module.addImport("core", core);
    tests.root_module.addImport("sys", sys);

    const run_exe_unit_tests = b.addRunArtifact(tests);

    const test_step = b.step("test", "Run unit tests");

    const core_tests = b.addTest(.{
        .root_module = core,
        .test_runner = .{ .path = b.path("test_runner.zig"), .mode = .simple },
    });
    const sys_tests = b.addTest(.{
        .root_module = sys,
        .test_runner = .{ .path = b.path("test_runner.zig"), .mode = .simple },
    });

    const run_core_tests = b.addRunArtifact(core_tests);
    const run_sys_tests = b.addRunArtifact(sys_tests);

    test_step.dependOn(&run_exe_unit_tests.step);
    test_step.dependOn(&run_core_tests.step);
    test_step.dependOn(&run_sys_tests.step);
}
