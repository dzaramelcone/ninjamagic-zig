const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const exe_mod = b.createModule(.{
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
    });

    // External deps.
    const zzz = b.dependency("zzz", .{
        .target = target,
        .optimize = optimize,
    }).module("zzz");
    exe_mod.addImport("zzz", zzz);

    const pg = b.dependency("pg", .{
        .target = target,
        .optimize = optimize,
    }).module("pg");
    exe_mod.addImport("pg", pg);

    const ws = b.dependency("websocket", .{
        .target = target,
        .optimize = optimize,
    }).module("websocket");
    exe_mod.addImport("websocket", ws);

    // Internal deps.
    const embed = b.addModule("embed", .{
        .root_source_file = b.path("embed/module.zig"),
    });
    embed.addImport("zzz", zzz);

    const core = b.addModule("core", .{
        .root_source_file = b.path("src/core/module.zig"),
    });

    core.addImport("zzz", zzz);
    core.addImport("pg", pg);
    core.addImport("websocket", ws);
    exe_mod.addImport("core", core);

    const net = b.addModule("net", .{
        .root_source_file = b.path("src/net/module.zig"),
    });
    net.addImport("zzz", zzz);
    net.addImport("pg", pg);
    net.addImport("websocket", ws);
    net.addImport("core", core);
    net.addImport("embed", embed);
    exe_mod.addImport("net", net);

    const exe = b.addExecutable(.{
        .name = "mud",
        .root_module = exe_mod,
    });
    b.installArtifact(exe);

    const run_cmd = b.addRunArtifact(exe);
    run_cmd.step.dependOn(b.getInstallStep());
    if (b.args) |args| {
        run_cmd.addArgs(args);
    }
    const run_step = b.step("run", "Run the app");
    run_step.dependOn(&run_cmd.step);
    const exe_unit_tests = b.addTest(.{
        .root_module = exe_mod,
    });
    const run_exe_unit_tests = b.addRunArtifact(exe_unit_tests);
    const test_step = b.step("test", "Run unit tests");
    test_step.dependOn(&run_exe_unit_tests.step);
}
