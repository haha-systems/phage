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

    // The ZeroMQ server is intentionally exposed through explicit build/run
    // steps rather than the default install step so core tests and native
    // benchmarks stay independent of a live network runtime. The zimq package
    // is pinned in build.zig.zon to a Zig 0.15-compatible revision.
    const zimq_dep = b.dependency("zimq", .{
        .target = target,
        .optimize = optimize,
    });
    const zimq_mod = zimq_dep.module("zimq");

    const server_mod = b.createModule(.{
        .root_source_file = b.path("src/zserver.zig"),
        .target = target,
        .optimize = optimize,
    });
    server_mod.addImport("phage", lib_mod);
    server_mod.addImport("zimq", zimq_mod);
    addPhageImports(server_mod, colored_logger_mod, chameleon_mod, mvzr_mod);

    const server_exe = b.addExecutable(.{
        .name = "phage-server",
        .root_module = server_mod,
    });
    const install_server = b.addInstallArtifact(server_exe, .{});

    const server_step = b.step("phage-server", "Build the ZeroMQ Phage server executable");
    server_step.dependOn(&install_server.step);

    const run_server_cmd = b.addRunArtifact(server_exe);
    if (b.args) |args| {
        run_server_cmd.addArgs(args);
    }
    const run_server_step = b.step("run-server", "Run the ZeroMQ Phage server; pass args after --");
    run_server_step.dependOn(&run_server_cmd.step);

    const server_smoke_mod = b.createModule(.{
        .root_source_file = b.path("src/server/smoke.zig"),
        .target = target,
        .optimize = optimize,
    });
    server_smoke_mod.addImport("zimq", zimq_mod);

    const server_smoke_exe = b.addExecutable(.{
        .name = "phage-server-smoke",
        .root_module = server_smoke_mod,
    });

    const run_server_smoke_cmd = b.addRunArtifact(server_smoke_exe);
    run_server_smoke_cmd.step.dependOn(&server_exe.step);
    run_server_smoke_cmd.addArg("--server-exe");
    run_server_smoke_cmd.addArtifactArg(server_exe);
    if (b.args) |args| {
        run_server_smoke_cmd.addArgs(args);
    }
    const server_smoke_step = b.step("server-smoke", "Run a live ZeroMQ smoke against the Phage server; pass args after --");
    server_smoke_step.dependOn(&run_server_smoke_cmd.step);

    const server_sustained_smoke_mod = b.createModule(.{
        .root_source_file = b.path("src/server/sustained_smoke.zig"),
        .target = target,
        .optimize = optimize,
    });
    server_sustained_smoke_mod.addImport("zimq", zimq_mod);

    const server_sustained_smoke_exe = b.addExecutable(.{
        .name = "phage-server-sustained-smoke",
        .root_module = server_sustained_smoke_mod,
    });

    const run_server_sustained_smoke_cmd = b.addRunArtifact(server_sustained_smoke_exe);
    run_server_sustained_smoke_cmd.step.dependOn(&server_exe.step);
    run_server_sustained_smoke_cmd.addArg("--server-exe");
    run_server_sustained_smoke_cmd.addArtifactArg(server_exe);
    if (b.args) |args| {
        run_server_sustained_smoke_cmd.addArgs(args);
    }
    const server_sustained_smoke_step = b.step("server-sustained-smoke", "Run a bounded multi-client sustained smoke against the Phage server; pass args after --");
    server_sustained_smoke_step.dependOn(&run_server_sustained_smoke_cmd.step);

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

    const server_config_tests_mod = b.createModule(.{
        .root_source_file = b.path("src/server/config.zig"),
        .target = target,
        .optimize = optimize,
    });
    const server_config_tests = b.addTest(.{
        .root_module = server_config_tests_mod,
        .test_runner = .{ .mode = .simple, .path = b.path("src/test_runner.zig") },
    });
    const run_server_config_tests = b.addRunArtifact(server_config_tests);

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
    test_step.dependOn(&run_server_config_tests.step);
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
