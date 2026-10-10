const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const x402 = b.addModule("x402", .{
        .root_source_file = b.path("src/x402.zig"),
        .target = target,
        .optimize = optimize,
    });

    const tests = b.addTest(.{
        .root_module = x402,
    });
    const run_tests = b.addRunArtifact(tests);

    const test_step = b.step("test", "run library tests");
    test_step.dependOn(&run_tests.step);

    const bench_module = b.createModule(.{
        .root_source_file = b.path("bench/amount.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{.{ .name = "x402", .module = x402 }},
    });
    const bench = b.addExecutable(.{
        .name = "bench-amount",
        .root_module = bench_module,
    });
    const run_bench = b.addRunArtifact(bench);
    b.step("bench-amount", "Benchmark Amount validation").dependOn(&run_bench.step);

    const bench_tests = b.addTest(.{ .root_module = bench_module });
    test_step.dependOn(&b.addRunArtifact(bench_tests).step);
}
