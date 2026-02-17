const std = @import("std");

pub const version = "0.0.0";

pub const CliArgs = struct {
    path: ?[]const u8 = null,
    recursive: bool = false,
    delete: bool = false,
    output_dir: ?[]const u8 = null,
    dry_run: bool = false,
    verbose: bool = false,
    keep_comments: bool = false,
    reverse: bool = false,
    show_help: bool = false,
    show_version: bool = false,
};

pub const CliError = error{
    PathRequired,
    UnknownFlag,
    MissingValue,
    InvalidValue,
};

/// Parse command-line argument slices (excluding program name).
pub fn parseArgs(args: []const []const u8) CliError!CliArgs {
    var result = CliArgs{};
    var i: usize = 0;

    while (i < args.len) : (i += 1) {
        const arg = args[i];

        if (arg.len == 0) continue;

        if (arg[0] != '-') {
            // Positional argument
            result.path = arg;
            continue;
        }

        if (arg.len >= 2 and arg[0] == '-' and arg[1] == '-') {
            // Long flag
            if (std.mem.eql(u8, arg, "--recursive")) {
                result.recursive = true;
            } else if (std.mem.eql(u8, arg, "--delete")) {
                result.delete = true;
            } else if (std.mem.eql(u8, arg, "--dry-run")) {
                result.dry_run = true;
            } else if (std.mem.eql(u8, arg, "--verbose")) {
                result.verbose = true;
            } else if (std.mem.eql(u8, arg, "--keep-comments")) {
                result.keep_comments = true;
            } else if (std.mem.eql(u8, arg, "--reverse")) {
                result.reverse = true;
            } else if (std.mem.eql(u8, arg, "--help")) {
                result.show_help = true;
            } else if (std.mem.eql(u8, arg, "--version")) {
                result.show_version = true;
            } else if (std.mem.eql(u8, arg, "--output")) {
                i += 1;
                if (i >= args.len) return error.MissingValue;
                result.output_dir = args[i];
            } else if (std.mem.startsWith(u8, arg, "--output=")) {
                const val = arg["--output=".len..];
                if (val.len == 0) return error.MissingValue;
                result.output_dir = val;
            } else {
                return error.UnknownFlag;
            }
        } else {
            // Short flag(s) - may be combined like -rdv
            const flags = arg[1..];
            for (flags, 0..) |ch, fi| {
                switch (ch) {
                    'r' => result.recursive = true,
                    'd' => result.delete = true,
                    'v' => result.verbose = true,
                    'h' => result.show_help = true,
                    'o' => {
                        // -o takes a value
                        if (fi + 1 < flags.len) {
                            // Rest of combined flag is the value: -opath
                            result.output_dir = arg[1 + fi + 1 ..];
                            break;
                        }
                        i += 1;
                        if (i >= args.len) return error.MissingValue;
                        result.output_dir = args[i];
                    },
                    else => return error.UnknownFlag,
                }
            }
        }
    }

    return result;
}

/// Validate parsed args - ensure required fields are present.
pub fn validate(args: CliArgs) CliError!CliArgs {
    if (args.show_help or args.show_version) return args;
    if (args.path == null) return error.PathRequired;
    return args;
}

pub fn printHelp(writer: anytype) !void {
    try writer.writeAll(
        \\Usage: bru2oc [options] <path>
        \\
        \\Convert Bruno (.bru) files to OpenCollection (.yml) format.
        \\
        \\Arguments:
        \\  <path>              Path to .bru file or directory
        \\
        \\Options:
        \\  -r, --recursive     Recursively process directories
        \\  -d, --delete        Delete original .bru files after conversion
        \\  -o, --output <dir>  Output directory (default: in-place)
        \\  --dry-run           Show what would be done without making changes
        \\  -v, --verbose       Show detailed progress
        \\  --keep-comments     Preserve comments in YAML output
        \\  --reverse           Reverse: convert .yml to .bru
        \\  -h, --help          Show this help message
        \\  --version           Show version
        \\
        \\Examples:
        \\  bru2oc ./request.bru
        \\  bru2oc -r ./bruno-collection
        \\  bru2oc -rd -o ./output ./input
        \\
    );
}

pub fn printVersion(writer: anytype) !void {
    try writer.print("bru2oc version {s}\n", .{version});
}

// ── Tests ──────────────────────────────────────────────────────────────

test "default args" {
    const args = try parseArgs(&.{});
    try std.testing.expectEqual(@as(?[]const u8, null), args.path);
    try std.testing.expectEqual(false, args.recursive);
    try std.testing.expectEqual(false, args.delete);
    try std.testing.expectEqual(false, args.dry_run);
    try std.testing.expectEqual(false, args.verbose);
}

test "positional path" {
    const args = try parseArgs(&.{"./test.bru"});
    try std.testing.expectEqualStrings("./test.bru", args.path.?);
}

test "long flags" {
    const args = try parseArgs(&.{ "--recursive", "--delete", "--verbose", "--dry-run", "--keep-comments", "./path" });
    try std.testing.expect(args.recursive);
    try std.testing.expect(args.delete);
    try std.testing.expect(args.verbose);
    try std.testing.expect(args.dry_run);
    try std.testing.expect(args.keep_comments);
    try std.testing.expectEqualStrings("./path", args.path.?);
}

test "short flags" {
    const args = try parseArgs(&.{ "-r", "-d", "-v", "./path" });
    try std.testing.expect(args.recursive);
    try std.testing.expect(args.delete);
    try std.testing.expect(args.verbose);
}

test "combined short flags" {
    const args = try parseArgs(&.{ "-rdv", "./path" });
    try std.testing.expect(args.recursive);
    try std.testing.expect(args.delete);
    try std.testing.expect(args.verbose);
}

test "output flag with separate value" {
    const args = try parseArgs(&.{ "--output", "./out", "./path" });
    try std.testing.expectEqualStrings("./out", args.output_dir.?);
}

test "output flag with equals" {
    const args = try parseArgs(&.{ "--output=./out", "./path" });
    try std.testing.expectEqualStrings("./out", args.output_dir.?);
}

test "short -o flag" {
    const args = try parseArgs(&.{ "-o", "./out", "./path" });
    try std.testing.expectEqualStrings("./out", args.output_dir.?);
}

test "help flag" {
    const args = try parseArgs(&.{"--help"});
    try std.testing.expect(args.show_help);
}

test "version flag" {
    const args = try parseArgs(&.{"--version"});
    try std.testing.expect(args.show_version);
}

test "unknown flag error" {
    try std.testing.expectError(error.UnknownFlag, parseArgs(&.{"--unknown"}));
}

test "missing output value" {
    try std.testing.expectError(error.MissingValue, parseArgs(&.{"--output"}));
}

test "validate requires path" {
    const args = try parseArgs(&.{"-r"});
    try std.testing.expectError(error.PathRequired, validate(args));
}

test "validate allows help without path" {
    const args = try parseArgs(&.{"--help"});
    const validated = try validate(args);
    try std.testing.expect(validated.show_help);
}

test "printHelp produces output" {
    var buf: [2048]u8 = undefined;
    var stream = std.io.fixedBufferStream(&buf);
    try printHelp(stream.writer());
    const output = stream.getWritten();
    try std.testing.expect(std.mem.indexOf(u8, output, "Usage: bru2oc") != null);
}

test "printVersion produces output" {
    var buf: [256]u8 = undefined;
    var stream = std.io.fixedBufferStream(&buf);
    try printVersion(stream.writer());
    const output = stream.getWritten();
    try std.testing.expect(std.mem.indexOf(u8, output, "bru2oc version") != null);
}
