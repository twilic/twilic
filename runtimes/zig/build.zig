const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const lib_module = b.createModule(.{
        .root_source_file = b.path("src/lib.zig"),
        .target = target,
        .optimize = optimize,
    });

    const lib_tests = b.addTest(.{
        .root_module = lib_module,
    });
    const run_lib_tests = b.addRunArtifact(lib_tests);

    const integration_module = b.createModule(.{
        .root_source_file = b.path("tests/main.zig"),
        .target = target,
        .optimize = optimize,
    });
    integration_module.addImport("twilic", lib_module);

    const integration_tests = b.addTest(.{
        .root_module = integration_module,
    });
    const run_integration_tests = b.addRunArtifact(integration_tests);

    const test_step = b.step("test", "Run all tests");
    test_step.dependOn(&run_lib_tests.step);
    test_step.dependOn(&run_integration_tests.step);
}
