const std = @import("std");
const yaml_parser = @import("yaml_parser.zig");
const bru_emitter = @import("bru_emitter.zig");
const fs_utils = @import("fs_utils.zig");

pub const ReverseConvertOptions = struct {
    verbose: bool = false,
    dry_run: bool = false,
    delete_original: bool = false,
    output_dir: ?[]const u8 = null,
};

pub const ConversionResult = struct {
    input_path: []const u8,
    output_path: ?[]const u8 = null,
    success: bool,
    error_msg: ?[]const u8 = null,
    skipped: bool = false,
};

/// Convert a single .yml file to .bru.
pub fn convertFile(
    allocator: std.mem.Allocator,
    input_path: []const u8,
    options: ReverseConvertOptions,
) ConversionResult {
    // Read input
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

    // Parse YAML
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();

    const req = yaml_parser.parse(arena.allocator(), input_content) catch {
        return ConversionResult{
            .input_path = input_path,
            .success = false,
            .error_msg = "YAML parse error",
        };
    };

    // Emit Bru
    const bru_output = bru_emitter.emit(allocator, req) catch {
        return ConversionResult{
            .input_path = input_path,
            .success = false,
            .error_msg = "Bru emit error",
        };
    };
    defer allocator.free(bru_output);

    // Resolve output path: .yml -> .bru
    const output_path = resolveReversePath(allocator, input_path, options.output_dir) catch {
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

    file.writeAll(bru_output) catch {
        return ConversionResult{
            .input_path = input_path,
            .output_path = output_path,
            .success = false,
            .error_msg = "Failed to write output",
        };
    };

    if (options.delete_original) {
        std.fs.cwd().deleteFile(input_path) catch {};
    }

    return ConversionResult{
        .input_path = input_path,
        .output_path = output_path,
        .success = true,
    };
}

fn resolveReversePath(allocator: std.mem.Allocator, input_path: []const u8, output_dir: ?[]const u8) ![]const u8 {
    _ = output_dir;
    // Replace .yml extension with .bru
    if (std.mem.endsWith(u8, input_path, ".yml")) {
        return std.fmt.allocPrint(allocator, "{s}.bru", .{input_path[0 .. input_path.len - 4]});
    }
    if (std.mem.endsWith(u8, input_path, ".yaml")) {
        return std.fmt.allocPrint(allocator, "{s}.bru", .{input_path[0 .. input_path.len - 5]});
    }
    return std.fmt.allocPrint(allocator, "{s}.bru", .{input_path});
}

// ── Tests ──────────────────────────────────────────────────────────────

test "convertFile reverse: yml to bru" {
    const allocator = std.testing.allocator;

    var tmp_dir = std.testing.tmpDir(.{});
    defer tmp_dir.cleanup();

    const yaml_content =
        \\info:
        \\  name: test
        \\  type: http
        \\http:
        \\  method: get
        \\  url: https://example.com
    ;

    tmp_dir.dir.writeFile(.{ .sub_path = "test.yml", .data = yaml_content }) catch return;

    const tmp_path = tmp_dir.dir.realpathAlloc(allocator, ".") catch return;
    defer allocator.free(tmp_path);

    const input_path = std.fmt.allocPrint(allocator, "{s}/test.yml", .{tmp_path}) catch return;
    defer allocator.free(input_path);

    const result = convertFile(allocator, input_path, .{});
    if (result.output_path) |op| allocator.free(op);

    try std.testing.expect(result.success);
}

test "convertFile reverse: dry-run" {
    const allocator = std.testing.allocator;

    var tmp_dir = std.testing.tmpDir(.{});
    defer tmp_dir.cleanup();

    const yaml_content =
        \\info:
        \\  name: dry-test
        \\  type: http
        \\http:
        \\  method: get
        \\  url: https://example.com
    ;

    tmp_dir.dir.writeFile(.{ .sub_path = "test.yml", .data = yaml_content }) catch return;

    const tmp_path = tmp_dir.dir.realpathAlloc(allocator, ".") catch return;
    defer allocator.free(tmp_path);

    const input_path = std.fmt.allocPrint(allocator, "{s}/test.yml", .{tmp_path}) catch return;
    defer allocator.free(input_path);

    const result = convertFile(allocator, input_path, .{ .dry_run = true });
    if (result.output_path) |op| allocator.free(op);

    try std.testing.expect(result.success);
    try std.testing.expect(result.skipped);
}

test "convertFile reverse: missing file" {
    const allocator = std.testing.allocator;
    const result = convertFile(allocator, "/nonexistent/test.yml", .{});
    try std.testing.expect(!result.success);
    try std.testing.expectEqualStrings("File not found", result.error_msg.?);
}
