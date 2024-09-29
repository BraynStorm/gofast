const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const exe = b.addExecutable(.{
        .name = "gofast",
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
    });
    const exe_tests = b.addTest(.{
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
    });
    const httpz = b.dependency("httpz", .{
        .target = target,
        .optimize = optimize,
    });

    exe.root_module.addImport("httpz", httpz.module("httpz"));
    b.installArtifact(exe);

    const run_cmd = b.addRunArtifact(exe);
    const run_tests = b.addRunArtifact(exe_tests);

    run_cmd.step.dependOn(b.getInstallStep());
    b.step("run", "Run GOFAST").dependOn(&run_cmd.step);

    if (b.args) |args| {
        run_cmd.addArgs(args);
    }

    const test_step = b.step("test", "Test GOFAST");
    test_step.dependOn(&run_tests.step);
}
