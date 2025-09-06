const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    // Create a module for the pgm library.
    const lib = b.addModule("pgm", .{
        .root_source_file = b.path("src/pgm.zig"),
        .target = target,
        .optimize = optimize,
    });

    // Create a test executable for the library.
    const lib_tests = b.addTest(.{
        .root_module = lib,
        .target = target,
        .optimize = optimize,
    });

    // Create a run step to run the tests.
    const test_step = b.step("test", "Run library tests");
    test_step.dependOn(&b.addRunArtifact(lib_tests).step);
}
