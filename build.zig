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

    // const tracy = b.dependency("tracy", .{
    //     .target = target,
    //     .optimize = optimize,
    // });
    const httpz = b.dependency("httpz", .{
        .target = target,
        .optimize = optimize,
    });

    exe.root_module.addImport("httpz", httpz.module("httpz"));
    //TODO:
    //  Add a build flag to ENABLE this.
    //exe.root_module.addImport("zig_tracy", tracy.module("tracy"));

    // const sqlite3 = b.dependency("sqlite3", .{
    //     .target = target,
    //     .optimize = optimize,
    // });
    // exe.root_module.addCMacro("SQLITE_DEFAULT_FOREIGN_KEYS", "1");
    // exe.root_module.addCMacro("SQLITE_DQS", "0");
    // exe.addIncludePath(sqlite3.path(""));
    // exe.addCSourceFile(.{ .file = sqlite3.path("sqlite3.c") });
    // exe.linkLibC(); // sqlite needs it.

    b.installArtifact(exe);

    const run_cmd = b.addRunArtifact(exe);
    const run_tests = b.addRunArtifact(exe_tests);

    run_cmd.step.dependOn(b.getInstallStep());
    b.step("run", "Run the app").dependOn(&run_cmd.step);

    if (b.args) |args| {
        run_cmd.addArgs(args);
    }

    const test_step = b.step("test", "Run unit tests");
    test_step.dependOn(&run_tests.step);
}
