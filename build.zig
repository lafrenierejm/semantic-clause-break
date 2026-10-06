const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const markz_dep = b.dependency("markz", .{ .target = target, .optimize = optimize });

    const exe = b.addExecutable(.{
        .name = "semantic-clause-break",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/main.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    exe.root_module.addImport("markz", markz_dep.module("markz"));
    b.installArtifact(exe);

    const run_cmd = b.addRunArtifact(exe);
    run_cmd.step.dependOn(b.getInstallStep());
    if (b.args) |args| {
        run_cmd.addArgs(args);
    }

    const run_step = b.step("run", "Run the app");
    run_step.dependOn(&run_cmd.step);

    const test_filters = b.option(
        []const []const u8,
        "test-filter",
        "Only run tests whose names contain this text (may be repeated)",
    ) orelse &.{};
    const test_step = b.step("test", "Run unit tests");
    // `zig build test` only reports totals. Run the installed binary directly
    // to see each skipped (or failed) spec test by name.
    const spec_tests_step = b.step("spec-tests", "Install the GFM spec test binary to zig-out/bin/spec_tests");

    const unit_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/main.zig"),
            .target = target,
            .optimize = optimize,
        }),
        .filters = test_filters,
    });
    unit_tests.root_module.addImport("markz", markz_dep.module("markz"));
    test_step.dependOn(&b.addRunArtifact(unit_tests).step);

    // The GFM spec tests are generated from the spec at build time, one per
    // example per mutation (see test/gen_spec_tests.zig), and built as their
    // own test binary with test/spec_check.zig providing the checks.
    if (b.lazyDependency("cmark_gfm", .{})) |cmark_gfm_dep| {
        const gen_spec_tests = b.addExecutable(.{
            .name = "gen_spec_tests",
            .root_module = b.createModule(.{
                .root_source_file = b.path("test/gen_spec_tests.zig"),
                .target = b.graph.host,
            }),
        });
        const run_gen_spec_tests = b.addRunArtifact(gen_spec_tests);
        run_gen_spec_tests.addFileArg(cmark_gfm_dep.path("test/spec.txt"));
        const generated = run_gen_spec_tests.addOutputFileArg("spec_tests.zig");

        // spec_check.zig lives outside src/, so it can't import reflow.zig by
        // path; expose it as a module instead.
        const reflow = b.createModule(.{
            .root_source_file = b.path("src/reflow.zig"),
            .target = target,
            .optimize = optimize,
        });
        reflow.addImport("markz", markz_dep.module("markz"));

        const spec_check = b.createModule(.{
            .root_source_file = b.path("test/spec_check.zig"),
            .target = target,
            .optimize = optimize,
        });
        spec_check.addImport("markz", markz_dep.module("markz"));
        spec_check.addImport("reflow", reflow);

        const spec_tests = b.addTest(.{
            .name = "spec-tests",
            .root_module = b.createModule(.{
                .root_source_file = generated,
                .target = target,
                .optimize = optimize,
            }),
            .filters = test_filters,
        });
        spec_tests.root_module.addImport("spec_check", spec_check);
        test_step.dependOn(&b.addRunArtifact(spec_tests).step);
        spec_tests_step.dependOn(&b.addInstallArtifact(spec_tests, .{}).step);
    }
}
