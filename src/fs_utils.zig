const std = @import("std");

/// Information about a validated path.
pub const PathInfo = struct {
    absolute: []const u8,
    is_file: bool,
    is_dir: bool,

    pub fn deinit(self: PathInfo, allocator: std.mem.Allocator) void {
        allocator.free(self.absolute);
    }
};

pub const FsError = error{
    FileNotFound,
    PermissionDenied,
    InvalidPath,
    DirectoryCreationFailed,
};

/// Validate that a path exists and determine if it's a file or directory.
pub fn validatePath(allocator: std.mem.Allocator, path: []const u8) (FsError || std.posix.RealPathError)!PathInfo {
    const absolute = std.fs.cwd().realpathAlloc(allocator, path) catch |err| {
        return switch (err) {
            error.FileNotFound => error.FileNotFound,
            error.AccessDenied => error.PermissionDenied,
            else => error.InvalidPath,
        };
    };
    errdefer allocator.free(absolute);

    const stat = std.fs.cwd().statFile(path) catch {
        // If statFile fails, try opening as directory
        var dir = std.fs.cwd().openDir(path, .{}) catch {
            return PathInfo{ .absolute = absolute, .is_file = false, .is_dir = false };
        };
        dir.close();
        return PathInfo{ .absolute = absolute, .is_file = false, .is_dir = true };
    };

    return PathInfo{
        .absolute = absolute,
        .is_file = stat.kind == .file,
        .is_dir = stat.kind == .directory,
    };
}

/// Validate that a file has a .bru extension.
pub fn hasBruExtension(path: []const u8) bool {
    return std.mem.endsWith(u8, path, ".bru");
}

/// Resolve the output path for a converted file.
/// Replaces .bru extension with .yml and optionally places in output_dir.
pub fn resolveOutputPath(
    allocator: std.mem.Allocator,
    input: []const u8,
    output_dir: ?[]const u8,
    base_dir: ?[]const u8,
) ![]const u8 {
    // Replace .bru with .yml
    const stem = if (std.mem.endsWith(u8, input, ".bru"))
        input[0 .. input.len - 4]
    else
        input;

    const yml_name = try std.fmt.allocPrint(allocator, "{s}.yml", .{stem});

    if (output_dir == null) {
        return yml_name;
    }

    defer allocator.free(yml_name);

    // Get the filename portion or relative path
    const base = base_dir orelse "";
    var relative: []const u8 = undefined;

    if (base.len > 0 and std.mem.startsWith(u8, yml_name, base)) {
        relative = yml_name[base.len..];
        // Strip leading separator
        if (relative.len > 0 and (relative[0] == '/' or relative[0] == '\\')) {
            relative = relative[1..];
        }
    } else {
        // Just use the filename
        relative = std.fs.path.basename(yml_name);
    }

    return std.fmt.allocPrint(allocator, "{s}/{s}", .{ output_dir.?, relative });
}

/// Check if a file is a folder.bru or collection.bru file (collection/folder config).
pub fn isFolderBru(path: []const u8) bool {
    const basename = std.fs.path.basename(path);
    return std.mem.eql(u8, basename, "folder.bru") or
        std.mem.eql(u8, basename, "collection.bru");
}

/// Check if a file is a collection.bru file (outputs as opencollection.yml).
pub fn isCollectionBru(path: []const u8) bool {
    const basename = std.fs.path.basename(path);
    return std.mem.eql(u8, basename, "collection.bru");
}

/// Create directory structure for an output path.
pub fn ensureOutputDir(path: []const u8) !void {
    if (std.fs.path.dirname(path)) |dir| {
        std.fs.cwd().makePath(dir) catch |err| {
            return switch (err) {
                error.AccessDenied => error.AccessDenied,
                else => err,
            };
        };
    }
}

/// Walk a directory recursively and collect all .bru file paths.
pub fn walkBruFiles(allocator: std.mem.Allocator, dir_path: []const u8) ![]const []const u8 {
    var result: std.ArrayListUnmanaged([]const u8) = .empty;

    var dir = std.fs.cwd().openDir(dir_path, .{ .iterate = true }) catch {
        return &.{};
    };
    defer dir.close();

    var walker = dir.walk(allocator) catch {
        return &.{};
    };
    defer walker.deinit();

    while (walker.next() catch null) |entry| {
        if (entry.kind == .file and std.mem.endsWith(u8, entry.basename, ".bru")) {
            const full_path = std.fmt.allocPrint(allocator, "{s}/{s}", .{ dir_path, entry.path }) catch continue;
            result.append(allocator, full_path) catch continue;
        }
    }

    return result.toOwnedSlice(allocator) catch &.{};
}

/// Basic YAML syntax verification.
pub fn verifyYaml(content: []const u8) bool {
    if (content.len == 0) return false;

    // Check for tab indentation (YAML forbids tabs)
    if (std.mem.indexOf(u8, content, "\t") != null) return false;

    // Must have at least one colon (key: value)
    if (std.mem.indexOf(u8, content, ":") == null) return false;

    // Check for consistent indentation (multiples of 2), skipping literal block content
    var iter = std.mem.splitScalar(u8, content, '\n');
    var in_block_scalar = false;
    var block_scalar_indent: usize = 0;
    while (iter.next()) |line| {
        if (line.len == 0) {
            // Empty lines don't end block scalars
            continue;
        }
        // Count leading spaces
        var spaces: usize = 0;
        for (line) |c| {
            if (c == ' ') {
                spaces += 1;
            } else {
                break;
            }
        }
        // Skip comment lines and empty content lines
        if (spaces == line.len) continue;
        if (line[spaces] == '#') continue;
        // Detect end of block scalar (line with equal or less indent than the key)
        if (in_block_scalar) {
            if (spaces <= block_scalar_indent) {
                in_block_scalar = false;
            } else {
                // Inside block scalar content — skip indentation check
                continue;
            }
        }
        // Indent should be multiple of 2
        if (spaces % 2 != 0) return false;
        // Detect start of literal block scalar (line ending with | or |-)
        const trimmed = std.mem.trimRight(u8, line, " ");
        if (trimmed.len > 0 and (trimmed[trimmed.len - 1] == '|' or
            (trimmed.len >= 2 and trimmed[trimmed.len - 2] == '|' and trimmed[trimmed.len - 1] == '-')))
        {
            in_block_scalar = true;
            block_scalar_indent = spaces;
        }
    }

    return true;
}

// ── Tests ──────────────────────────────────────────────────────────────

test "hasBruExtension" {
    try std.testing.expect(hasBruExtension("request.bru"));
    try std.testing.expect(hasBruExtension("/path/to/file.bru"));
    try std.testing.expect(!hasBruExtension("file.yml"));
    try std.testing.expect(!hasBruExtension("file.txt"));
    try std.testing.expect(!hasBruExtension("bru"));
}

test "resolveOutputPath in-place" {
    const alloc = std.testing.allocator;
    const result = try resolveOutputPath(alloc, "test.bru", null, null);
    defer alloc.free(result);
    try std.testing.expectEqualStrings("test.yml", result);
}

test "resolveOutputPath with output dir" {
    const alloc = std.testing.allocator;
    const result = try resolveOutputPath(alloc, "/project/api/users.bru", "/out", "/project");
    defer alloc.free(result);
    try std.testing.expectEqualStrings("/out/api/users.yml", result);
}

test "resolveOutputPath non-bru extension" {
    const alloc = std.testing.allocator;
    const result = try resolveOutputPath(alloc, "test.txt", null, null);
    defer alloc.free(result);
    try std.testing.expectEqualStrings("test.txt.yml", result);
}

test "verifyYaml valid" {
    const yaml =
        \\info:
        \\  name: test
        \\http:
        \\  method: GET
        \\  url: https://example.com
    ;
    try std.testing.expect(verifyYaml(yaml));
}

test "verifyYaml empty" {
    try std.testing.expect(!verifyYaml(""));
}

test "verifyYaml with tabs" {
    try std.testing.expect(!verifyYaml("info:\n\tname: test"));
}

test "verifyYaml no colon" {
    try std.testing.expect(!verifyYaml("just some text\nwithout colons"));
}

test "verifyYaml odd indentation" {
    try std.testing.expect(!verifyYaml("info:\n   name: test"));
}
