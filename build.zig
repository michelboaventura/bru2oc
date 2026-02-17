const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    // Library module
    const mod = b.addModule("bru2oc", .{
        .root_source_file = b.path("src/root.zig"),
        .target = target,
    });

    // Main executable
    const exe = b.addExecutable(.{
        .name = "bru2oc",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/main.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "bru2oc", .module = mod },
            },
        }),
    });

    b.installArtifact(exe);

    // Run step
    const run_step = b.step("run", "Run the app");
    const run_cmd = b.addRunArtifact(exe);
    run_step.dependOn(&run_cmd.step);
    run_cmd.step.dependOn(b.getInstallStep());
    if (b.args) |args| {
        run_cmd.addArgs(args);
    }

    // Test step
    const mod_tests = b.addTest(.{ .root_module = mod });
    const run_mod_tests = b.addRunArtifact(mod_tests);
    const exe_tests = b.addTest(.{ .root_module = exe.root_module });
    const run_exe_tests = b.addRunArtifact(exe_tests);

    const test_step = b.step("test", "Run tests");
    test_step.dependOn(&run_mod_tests.step);
    test_step.dependOn(&run_exe_tests.step);

    // Cross-compilation targets
    const cross_step = b.step("cross", "Build for all release targets");

    const release_targets = [_]struct {
        query: std.Target.Query,
        name: []const u8,
    }{
        .{ .query = .{ .cpu_arch = .x86_64, .os_tag = .linux, .abi = .musl }, .name = "bru2oc-linux-x86_64" },
        .{ .query = .{ .cpu_arch = .aarch64, .os_tag = .linux, .abi = .musl }, .name = "bru2oc-linux-aarch64" },
        .{ .query = .{ .cpu_arch = .x86_64, .os_tag = .macos }, .name = "bru2oc-macos-x86_64" },
        .{ .query = .{ .cpu_arch = .aarch64, .os_tag = .macos }, .name = "bru2oc-macos-aarch64" },
        .{ .query = .{ .cpu_arch = .x86_64, .os_tag = .windows }, .name = "bru2oc-windows-x86_64.exe" },
        .{ .query = .{ .cpu_arch = .aarch64, .os_tag = .windows }, .name = "bru2oc-windows-aarch64.exe" },
    };

    for (&release_targets) |rt| {
        const cross_mod = b.addModule(rt.name, .{
            .root_source_file = b.path("src/root.zig"),
            .target = b.resolveTargetQuery(rt.query),
        });

        const cross_exe = b.addExecutable(.{
            .name = rt.name,
            .root_module = b.createModule(.{
                .root_source_file = b.path("src/main.zig"),
                .target = b.resolveTargetQuery(rt.query),
                .optimize = .ReleaseSafe,
                .imports = &.{
                    .{ .name = "bru2oc", .module = cross_mod },
                },
            }),
        });

        const install_step = b.addInstallArtifact(cross_exe, .{});
        cross_step.dependOn(&install_step.step);
    }
}
