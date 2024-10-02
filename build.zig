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
    const exe_benchmark = b.addExecutable(.{
        .name = "benchmark",
        .root_source_file = b.path("src/benchmark.zig"),
        .target = target,
        .optimize = optimize,
    });
    const httpz = b.dependency("httpz", .{
        .target = target,
        .optimize = optimize,
    });
    const benchmark = b.dependency("benchmark", .{
        .target = target,
        .optimize = optimize,
    });

    exe.root_module.addImport("httpz", httpz.module("httpz"));
    exe_benchmark.root_module.addImport("benchmark", benchmark.module("benchmark"));

    b.installArtifact(exe);

    const run_cmd = b.addRunArtifact(exe);
    const benchmark_cmd = b.addRunArtifact(exe_benchmark);
    const test_cmd = b.addRunArtifact(exe_tests);

    run_cmd.step.dependOn(b.getInstallStep());
    b.step("run", "Run GOFAST").dependOn(&run_cmd.step);
    b.step("bench", "Benchmark GOFAST").dependOn(&benchmark_cmd.step);
    b.step("test", "Test GOFAST").dependOn(&test_cmd.step);

    if (b.args) |args| {
        run_cmd.addArgs(args);
    }

    if (b.args) |args| {
        test_cmd.addArgs(args);
    }

    if (b.args) |args| {
        benchmark_cmd.addArgs(args);
    }
}
