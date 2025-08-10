const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const main = b.createModule(.{
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
    });

    // external deps.
    const oauth2 = b.dependency("oauth2", .{ .target = target, .optimize = optimize }).module("oauth2");
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
    }).module("zqlite");

    main.addCSourceFile(.{
        .file = b.path("embed/sqlite/sqlite3.c"),
        .flags = &[_][]const u8{"-std=c99"},
    });
    main.link_libc = true;

    main.addImport("zzz", zzz);
    main.addImport("websocket", ws);
    main.addImport("zqlite", zqlite);
    main.addImport("oauth2", oauth2);
    const embed = b.addModule("embed", .{
        .root_source_file = b.path("embed/module.zig"),
        .target = target,
        .optimize = optimize,
    });
    embed.addImport("zzz", zzz);
    main.addImport("embed", embed);
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
        .root_source_file = b.path("src/tests.zig"),
        .test_runner = .{ .path = b.path("test_runner.zig"), .mode = .simple },
        .target = target,
        .optimize = optimize,
    });
    // test deps
    tests.root_module.addImport("zzz", zzz);
    tests.root_module.addImport("websocket", ws);
    tests.root_module.addImport("zqlite", zqlite);
    tests.root_module.addImport("embed", embed);
    // add C/SQLite for db use in tests
    tests.root_module.addCSourceFile(.{
        .file = b.path("embed/sqlite/sqlite3.c"),
        .flags = &[_][]const u8{"-std=c99"},
    });
    tests.root_module.link_libc = true;
    const run_exe_unit_tests = b.addRunArtifact(tests);

    const test_step = b.step("test", "Run unit tests");
    test_step.dependOn(&run_exe_unit_tests.step);
}
