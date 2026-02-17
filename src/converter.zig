const std = @import("std");
const parser = @import("parser.zig");
const transformer = @import("transformer.zig");
const yaml_emitter = @import("yaml_emitter.zig");
const fs_utils = @import("fs_utils.zig");
const cli_mod = @import("cli.zig");

pub const ConvertOptions = struct {
    keep_comments: bool = false,
    verbose: bool = false,
    dry_run: bool = false,
    delete_original: bool = false,
    output_dir: ?[]const u8 = null,
    base_dir: ?[]const u8 = null,
};

pub const ConversionResult = struct {
    input_path: []const u8,
    output_path: ?[]const u8 = null,
    success: bool,
    error_msg: ?[]const u8 = null,
    skipped: bool = false,
};

pub const BatchResult = struct {
    total: usize,
    succeeded: usize,
    failed: usize,
    skipped: usize,
    results: []const ConversionResult,
};

/// Convert a single .bru file to .yml.
pub fn convertFile(
    allocator: std.mem.Allocator,
    input_path: []const u8,
    options: ConvertOptions,
) ConversionResult {
    // Read input file
    const input_content = std.fs.cwd().readFileAlloc(allocator, input_path, 10 * 1024 * 1024) catch |err| {
        return ConversionResult{
            .input_path = input_path,
            .success = false,
            .error_msg = switch (err) {
                error.FileNotFound => "File not found",
                error.AccessDenied => "Permission denied",
                else => "Failed to read file",
            },
        };
    };
    defer allocator.free(input_content);

    // Parse
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const arena_alloc = arena.allocator();

    const doc = parser.parse(arena_alloc, input_content) catch {
        return ConversionResult{
            .input_path = input_path,
            .success = false,
            .error_msg = "Parse error",
        };
    };

    // Transform
    const oc_request = transformer.transform(arena_alloc, doc) catch {
        return ConversionResult{
            .input_path = input_path,
            .success = false,
            .error_msg = "Transform error",
        };
    };

    // Emit YAML
    const yaml_output = yaml_emitter.emit(allocator, oc_request, .{
        .include_comments = options.keep_comments,
    }) catch {
        return ConversionResult{
            .input_path = input_path,
            .success = false,
            .error_msg = "YAML emit error",
        };
    };
    defer allocator.free(yaml_output);

    // Resolve output path
    const output_path = fs_utils.resolveOutputPath(
        allocator,
        input_path,
        options.output_dir,
        options.base_dir,
    ) catch {
        return ConversionResult{
            .input_path = input_path,
            .success = false,
            .error_msg = "Failed to resolve output path",
        };
    };

    if (options.dry_run) {
        return ConversionResult{
            .input_path = input_path,
            .output_path = output_path,
            .success = true,
            .skipped = true,
        };
    }

    // Ensure output directory exists
    fs_utils.ensureOutputDir(output_path) catch {
        return ConversionResult{
            .input_path = input_path,
            .output_path = output_path,
            .success = false,
            .error_msg = "Failed to create output directory",
        };
    };

    // Write output
    const file = std.fs.cwd().createFile(output_path, .{}) catch {
        return ConversionResult{
            .input_path = input_path,
            .output_path = output_path,
            .success = false,
            .error_msg = "Failed to create output file",
        };
    };
    defer file.close();

    file.writeAll(yaml_output) catch {
        return ConversionResult{
            .input_path = input_path,
            .output_path = output_path,
            .success = false,
            .error_msg = "Failed to write output",
        };
    };

    // Verify
    if (!fs_utils.verifyYaml(yaml_output)) {
        return ConversionResult{
            .input_path = input_path,
            .output_path = output_path,
            .success = false,
            .error_msg = "YAML verification failed",
        };
    }

    // Delete original if requested
    if (options.delete_original) {
        std.fs.cwd().deleteFile(input_path) catch {};
    }

    return ConversionResult{
        .input_path = input_path,
        .output_path = output_path,
        .success = true,
    };
}

/// Convert all .bru files in a directory.
pub fn convertBatch(
    allocator: std.mem.Allocator,
    path: []const u8,
    options: ConvertOptions,
    writer: anytype,
) !BatchResult {
    var results: std.ArrayListUnmanaged(ConversionResult) = .empty;

    // Check if it's a single file
    if (fs_utils.hasBruExtension(path)) {
        const result = convertFile(allocator, path, options);
        results.append(allocator, result) catch {};
        logResult(writer, result, options.verbose);
    } else {
        // Directory - walk for .bru files
        const files = try fs_utils.walkBruFiles(allocator, path);
        defer {
            for (files) |f| allocator.free(f);
            allocator.free(files);
        }

        if (files.len == 0) {
            try writer.print("No .bru files found in {s}\n", .{path});
        }

        var batch_options = options;
        batch_options.base_dir = path;

        for (files) |file_path| {
            const result = convertFile(allocator, file_path, batch_options);
            logResult(writer, result, options.verbose);
            results.append(allocator, result) catch {};
        }
    }

    // Aggregate results
    var succeeded: usize = 0;
    var failed: usize = 0;
    var skipped: usize = 0;
    for (results.items) |r| {
        if (r.skipped) {
            skipped += 1;
        } else if (r.success) {
            succeeded += 1;
        } else {
            failed += 1;
        }
    }

    const total = results.items.len;

    // Summary
    if (total > 1 or options.verbose) {
        try writer.print("\n{d} file(s) processed: {d} succeeded, {d} failed", .{ total, succeeded, failed });
        if (skipped > 0) {
            try writer.print(", {d} skipped (dry-run)", .{skipped});
        }
        try writer.writeAll("\n");
    }

    return BatchResult{
        .total = total,
        .succeeded = succeeded,
        .failed = failed,
        .skipped = skipped,
        .results = results.toOwnedSlice(allocator) catch &.{},
    };
}

fn logResult(writer: anytype, result: ConversionResult, verbose: bool) void {
    if (result.skipped) {
        writer.print("[dry-run] {s} -> {s}\n", .{
            result.input_path,
            result.output_path orelse "?",
        }) catch {};
    } else if (result.success) {
        if (verbose) {
            writer.print("[ok] {s} -> {s}\n", .{
                result.input_path,
                result.output_path orelse "?",
            }) catch {};
        }
    } else {
        writer.print("[error] {s}: {s}\n", .{
            result.input_path,
            result.error_msg orelse "unknown error",
        }) catch {};
    }
}

/// Run the full CLI application.
pub fn run(allocator: std.mem.Allocator, raw_args: []const []const u8) !u8 {
    var stderr_buf: [4096]u8 = undefined;
    var stderr = std.fs.File.stderr().writer(&stderr_buf);
    const stderr_writer = &stderr.interface;

    var stdout_buf: [4096]u8 = undefined;
    var stdout = std.fs.File.stdout().writer(&stdout_buf);
    const stdout_writer = &stdout.interface;

    const args = cli_mod.parseArgs(raw_args) catch {
        stderr_writer.writeAll("Error: invalid arguments. Use --help for usage.\n") catch {};
        stderr_writer.flush() catch {};
        return 1;
    };

    if (args.show_help) {
        cli_mod.printHelp(stdout_writer) catch {};
        stdout_writer.flush() catch {};
        return 0;
    }

    if (args.show_version) {
        cli_mod.printVersion(stdout_writer) catch {};
        stdout_writer.flush() catch {};
        return 0;
    }

    const validated = cli_mod.validate(args) catch {
        stderr_writer.writeAll("Error: path argument is required. Use --help for usage.\n") catch {};
        stderr_writer.flush() catch {};
        return 1;
    };

    const options = ConvertOptions{
        .keep_comments = validated.keep_comments,
        .verbose = validated.verbose,
        .dry_run = validated.dry_run,
        .delete_original = validated.delete,
        .output_dir = validated.output_dir,
    };

    const result = convertBatch(allocator, validated.path.?, options, stdout_writer) catch {
        stderr_writer.writeAll("Error: conversion failed\n") catch {};
        stderr_writer.flush() catch {};
        return 1;
    };

    stdout_writer.flush() catch {};

    if (result.failed > 0) return 1;
    return 0;
}

// ── Tests ──────────────────────────────────────────────────────────────

test "convertFile with test fixture" {
    const allocator = std.testing.allocator;

    // Create a temp file
    var tmp_dir = std.testing.tmpDir(.{});
    defer tmp_dir.cleanup();

    const bru_content =
        \\meta {
        \\  name: test
        \\}
        \\
        \\get {
        \\  url: https://example.com
        \\}
    ;

    tmp_dir.dir.writeFile(.{ .sub_path = "test.bru", .data = bru_content }) catch return;

    // Get the temp dir path
    const tmp_path = tmp_dir.dir.realpathAlloc(allocator, ".") catch return;
    defer allocator.free(tmp_path);

    const input_path = std.fmt.allocPrint(allocator, "{s}/test.bru", .{tmp_path}) catch return;
    defer allocator.free(input_path);

    const result = convertFile(allocator, input_path, .{});
    if (result.output_path) |op| allocator.free(op);

    try std.testing.expect(result.success);
}

test "convertFile dry-run" {
    const allocator = std.testing.allocator;

    var tmp_dir = std.testing.tmpDir(.{});
    defer tmp_dir.cleanup();

    const bru_content =
        \\meta {
        \\  name: dry-run-test
        \\}
        \\
        \\get {
        \\  url: https://example.com
        \\}
    ;

    tmp_dir.dir.writeFile(.{ .sub_path = "test.bru", .data = bru_content }) catch return;

    const tmp_path = tmp_dir.dir.realpathAlloc(allocator, ".") catch return;
    defer allocator.free(tmp_path);

    const input_path = std.fmt.allocPrint(allocator, "{s}/test.bru", .{tmp_path}) catch return;
    defer allocator.free(input_path);

    const result = convertFile(allocator, input_path, .{ .dry_run = true });
    if (result.output_path) |op| allocator.free(op);

    try std.testing.expect(result.success);
    try std.testing.expect(result.skipped);
}

test "convertFile missing file" {
    const allocator = std.testing.allocator;
    const result = convertFile(allocator, "/nonexistent/path/test.bru", .{});
    try std.testing.expect(!result.success);
    try std.testing.expectEqualStrings("File not found", result.error_msg.?);
}
