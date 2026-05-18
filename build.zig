const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});
    const name: []const u8 = "phage";
    _ = name;

    const colored_logger_mod = b.createModule(.{
        .root_source_file = b.path("src/compat/colored_logger.zig"),
        .target = target,
        .optimize = optimize,
    });
    const chameleon_mod = b.createModule(.{
        .root_source_file = b.path("src/compat/chameleon.zig"),
        .target = target,
        .optimize = optimize,
    });
    const mvzr_mod = b.createModule(.{
        .root_source_file = b.path("src/mvzr.zig"),
        .target = target,
        .optimize = optimize,
    });

    const lib_mod = b.createModule(.{
        .root_source_file = b.path("src/root.zig"),
        .target = target,
        .optimize = optimize,
    });
    addPhageImports(lib_mod, colored_logger_mod, chameleon_mod, mvzr_mod);

    const lib = b.addLibrary(.{
        .linkage = .static,
        .name = "phage",
        .root_module = lib_mod,
    });
    b.installArtifact(lib);

    const package_mod = b.addModule("phage", .{
        .root_source_file = b.path("src/root.zig"),
        .target = target,
        .optimize = optimize,
    });
    addPhageImports(package_mod, colored_logger_mod, chameleon_mod, mvzr_mod);

    const benchmark_mod = b.createModule(.{
        .root_source_file = b.path("src/benchmark.zig"),
        .target = target,
        .optimize = optimize,
    });
    benchmark_mod.addImport("phage", lib_mod);

    const benchmark_exe = b.addExecutable(.{
        .name = "phage-benchmark",
        .root_module = benchmark_mod,
    });
    b.installArtifact(benchmark_exe);

    const run_benchmark_cmd = b.addRunArtifact(benchmark_exe);
    run_benchmark_cmd.step.dependOn(b.getInstallStep());
    if (b.args) |args| {
        run_benchmark_cmd.addArgs(args);
    }
    const benchmark_step = b.step("benchmark", "Run the local Phage benchmark");
    benchmark_step.dependOn(&run_benchmark_cmd.step);

    const lib_unit_tests = b.addTest(.{
        .root_module = lib_mod,
        .test_runner = .{ .mode = .simple, .path = b.path("src/test_runner.zig") },
    });
    lib_unit_tests.root_module.addImport("phage", lib_mod);
    addPhageImports(lib_unit_tests.root_module, colored_logger_mod, chameleon_mod, mvzr_mod);
    const run_lib_unit_tests = b.addRunArtifact(lib_unit_tests);

    const benchmark_unit_tests = b.addTest(.{
        .root_module = benchmark_mod,
        .test_runner = .{ .mode = .simple, .path = b.path("src/test_runner.zig") },
    });
    benchmark_unit_tests.root_module.addImport("phage", lib_mod);
    const run_benchmark_unit_tests = b.addRunArtifact(benchmark_unit_tests);

    const compaction_tests_mod = b.createModule(.{
        .root_source_file = b.path("src/test_wal_compaction_correctness.zig"),
        .target = target,
        .optimize = optimize,
    });
    addPhageImports(compaction_tests_mod, colored_logger_mod, chameleon_mod, mvzr_mod);
    const compaction_unit_tests = b.addTest(.{
        .root_module = compaction_tests_mod,
        .test_runner = .{ .mode = .simple, .path = b.path("src/test_runner.zig") },
    });
    addPhageImports(compaction_unit_tests.root_module, colored_logger_mod, chameleon_mod, mvzr_mod);
    const run_compaction_unit_tests = b.addRunArtifact(compaction_unit_tests);

    const protocol_command_tests_mod = b.createModule(.{
        .root_source_file = b.path("src/protocol/command_execution_test.zig"),
        .target = target,
        .optimize = optimize,
    });
    protocol_command_tests_mod.addImport("phage", lib_mod);
    const protocol_command_tests = b.addTest(.{
        .root_module = protocol_command_tests_mod,
        .test_runner = .{ .mode = .simple, .path = b.path("src/test_runner.zig") },
    });
    const run_protocol_command_tests = b.addRunArtifact(protocol_command_tests);

    const server_runtime_tests_mod = b.createModule(.{
        .root_source_file = b.path("src/server/runtime.zig"),
        .target = target,
        .optimize = optimize,
    });
    const server_runtime_tests = b.addTest(.{
        .root_module = server_runtime_tests_mod,
        .test_runner = .{ .mode = .simple, .path = b.path("src/test_runner.zig") },
    });
    const run_server_runtime_tests = b.addRunArtifact(server_runtime_tests);

    const test_step = b.step("test", "Run unit tests");
    test_step.dependOn(&run_lib_unit_tests.step);
    test_step.dependOn(&run_benchmark_unit_tests.step);
    test_step.dependOn(&run_compaction_unit_tests.step);
    test_step.dependOn(&run_protocol_command_tests.step);
    test_step.dependOn(&run_server_runtime_tests.step);
}

fn addPhageImports(
    module: *std.Build.Module,
    colored_logger_mod: *std.Build.Module,
    chameleon_mod: *std.Build.Module,
    mvzr_mod: *std.Build.Module,
) void {
    module.addImport("colored_logger", colored_logger_mod);
    module.addImport("chameleon", chameleon_mod);
    module.addImport("mvzr", mvzr_mod);
}
