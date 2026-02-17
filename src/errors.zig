const std = @import("std");
const builtin = @import("builtin");

/// Error set for all Bru format parsing failures.
pub const ParseError = error{
    UnclosedBlock,
    InvalidMultistring,
    InvalidAnnotation,
    CommentAfterValue,
    InvalidNumber,
    UnexpectedToken,
    MissingColon,
    DuplicateBlock,
    InvalidIndentation,
    UnterminatedString,
};

/// Error set for file I/O operations.
pub const IoError = error{
    FileNotFound,
    PermissionDenied,
    InvalidPath,
    ReadFailure,
    WriteFailure,
    DirectoryCreationFailed,
};

/// Error set for IR to OpenCollection transformation.
pub const TransformError = error{
    MissingRequiredField,
    InvalidFieldValue,
    ConflictingBlocks,
    UnsupportedFeature,
    AnnotationResolutionFailed,
};

/// Error set for output validation.
pub const VerifyError = error{
    InvalidYamlSyntax,
    MalformedOutput,
    SchemaValidationFailed,
};

/// Combined error set for the entire conversion pipeline.
pub const ConversionErrorSet = ParseError || IoError || TransformError || VerifyError;

/// Source location information for error reporting.
pub const DiagnosticInfo = struct {
    file_path: []const u8,
    line: usize,
    column: usize,
    message: []const u8,
    source_line: ?[]const u8 = null,

    pub fn init(file_path: []const u8, line: usize, column: usize, message: []const u8) DiagnosticInfo {
        return .{
            .file_path = file_path,
            .line = line,
            .column = column,
            .message = message,
        };
    }

    pub fn withSourceLine(self: DiagnosticInfo, source_line: []const u8) DiagnosticInfo {
        var copy = self;
        copy.source_line = source_line;
        return copy;
    }
};

/// Tagged union wrapping all error categories with diagnostic information.
pub const ConversionError = union(enum) {
    parse: struct {
        err: ParseError,
        diagnostic: DiagnosticInfo,
    },
    io: struct {
        err: IoError,
        diagnostic: DiagnosticInfo,
    },
    transform: struct {
        err: TransformError,
        diagnostic: DiagnosticInfo,
    },
    verify: struct {
        err: VerifyError,
        diagnostic: DiagnosticInfo,
    },

    pub fn fromParse(err: ParseError, diagnostic: DiagnosticInfo) ConversionError {
        return .{ .parse = .{ .err = err, .diagnostic = diagnostic } };
    }

    pub fn fromIo(err: IoError, diagnostic: DiagnosticInfo) ConversionError {
        return .{ .io = .{ .err = err, .diagnostic = diagnostic } };
    }

    pub fn fromTransform(err: TransformError, diagnostic: DiagnosticInfo) ConversionError {
        return .{ .transform = .{ .err = err, .diagnostic = diagnostic } };
    }

    pub fn fromVerify(err: VerifyError, diagnostic: DiagnosticInfo) ConversionError {
        return .{ .verify = .{ .err = err, .diagnostic = diagnostic } };
    }

    pub fn getDiagnostic(self: ConversionError) DiagnosticInfo {
        return switch (self) {
            .parse => |p| p.diagnostic,
            .io => |i| i.diagnostic,
            .transform => |t| t.diagnostic,
            .verify => |v| v.diagnostic,
        };
    }
};

/// Format a ConversionError into a user-friendly error message.
/// Caller owns the returned slice and must free it with the same allocator.
pub fn formatError(allocator: std.mem.Allocator, err: ConversionError) ![]const u8 {
    const diag = err.getDiagnostic();
    const err_name = switch (err) {
        .parse => |p| @errorName(p.err),
        .io => |i| @errorName(i.err),
        .transform => |t| @errorName(t.err),
        .verify => |v| @errorName(v.err),
    };

    if (diag.source_line) |source_line| {
        // Build caret line: spaces up to column, then ^
        const caret_buf = try allocator.alloc(u8, diag.column);
        defer allocator.free(caret_buf);
        @memset(caret_buf[0 .. diag.column -| 1], ' ');
        if (diag.column > 0) {
            caret_buf[diag.column - 1] = '^';
        }

        return std.fmt.allocPrint(allocator, "error: {s}:{d}:{d}: {s} ({s})\n  {s}\n  {s}", .{
            diag.file_path,
            diag.line,
            diag.column,
            diag.message,
            err_name,
            source_line,
            caret_buf,
        });
    }

    return std.fmt.allocPrint(allocator, "error: {s}:{d}:{d}: {s} ({s})", .{
        diag.file_path,
        diag.line,
        diag.column,
        diag.message,
        err_name,
    });
}

// ── Tests ──────────────────────────────────────────────────────────────

test "ParseError variants can be used in error unions" {
    const S = struct {
        fn mayFail(fail: bool) ParseError!u32 {
            if (fail) return error.UnclosedBlock;
            return 42;
        }
    };
    try std.testing.expectEqual(@as(u32, 42), try S.mayFail(false));
    try std.testing.expectError(error.UnclosedBlock, S.mayFail(true));
}

test "IoError variants propagate through error unions" {
    const S = struct {
        fn readFile(fail: bool) IoError![]const u8 {
            if (fail) return error.FileNotFound;
            return "content";
        }
    };
    try std.testing.expectError(error.FileNotFound, S.readFile(true));
    try std.testing.expectEqualStrings("content", try S.readFile(false));
}

test "error set composition with || operator" {
    const Combined = ParseError || IoError;
    const S = struct {
        fn process(mode: u8) Combined!void {
            if (mode == 1) return error.UnclosedBlock;
            if (mode == 2) return error.FileNotFound;
        }
    };
    try std.testing.expectError(error.UnclosedBlock, S.process(1));
    try std.testing.expectError(error.FileNotFound, S.process(2));
    try S.process(0);
}

test "DiagnosticInfo initialization" {
    const diag = DiagnosticInfo.init("test.bru", 10, 5, "unexpected token");
    try std.testing.expectEqualStrings("test.bru", diag.file_path);
    try std.testing.expectEqual(@as(usize, 10), diag.line);
    try std.testing.expectEqual(@as(usize, 5), diag.column);
    try std.testing.expectEqualStrings("unexpected token", diag.message);
    try std.testing.expectEqual(@as(?[]const u8, null), diag.source_line);
}

test "DiagnosticInfo with source line" {
    const diag = DiagnosticInfo.init("test.bru", 3, 8, "missing colon")
        .withSourceLine("  key value");
    try std.testing.expectEqualStrings("  key value", diag.source_line.?);
}

test "ConversionError tagged union variants" {
    const diag = DiagnosticInfo.init("file.bru", 1, 1, "test");

    const parse_err = ConversionError.fromParse(error.UnclosedBlock, diag);
    switch (parse_err) {
        .parse => |p| {
            try std.testing.expectEqual(error.UnclosedBlock, p.err);
            try std.testing.expectEqualStrings("file.bru", p.diagnostic.file_path);
        },
        else => return error.UnexpectedToken,
    }

    const io_err = ConversionError.fromIo(error.FileNotFound, diag);
    switch (io_err) {
        .io => |i| try std.testing.expectEqual(error.FileNotFound, i.err),
        else => return error.UnexpectedToken,
    }

    const transform_err = ConversionError.fromTransform(error.MissingRequiredField, diag);
    switch (transform_err) {
        .transform => |t| try std.testing.expectEqual(error.MissingRequiredField, t.err),
        else => return error.UnexpectedToken,
    }

    const verify_err = ConversionError.fromVerify(error.InvalidYamlSyntax, diag);
    switch (verify_err) {
        .verify => |v| try std.testing.expectEqual(error.InvalidYamlSyntax, v.err),
        else => return error.UnexpectedToken,
    }
}

test "ConversionError getDiagnostic" {
    const diag = DiagnosticInfo.init("a.bru", 5, 3, "msg");
    const err = ConversionError.fromParse(error.InvalidNumber, diag);
    const retrieved = err.getDiagnostic();
    try std.testing.expectEqual(@as(usize, 5), retrieved.line);
    try std.testing.expectEqual(@as(usize, 3), retrieved.column);
}

test "formatError without source line" {
    const allocator = std.testing.allocator;
    const diag = DiagnosticInfo.init("test.bru", 10, 5, "unclosed block");
    const err = ConversionError.fromParse(error.UnclosedBlock, diag);
    const msg = try formatError(allocator, err);
    defer allocator.free(msg);
    try std.testing.expectEqualStrings("error: test.bru:10:5: unclosed block (UnclosedBlock)", msg);
}

test "formatError with source line and caret" {
    const allocator = std.testing.allocator;
    const diag = DiagnosticInfo.init("test.bru", 3, 5, "missing colon")
        .withSourceLine("  key value");
    const err = ConversionError.fromParse(error.MissingColon, diag);
    const msg = try formatError(allocator, err);
    defer allocator.free(msg);

    // Verify the message contains the expected components
    try std.testing.expect(std.mem.indexOf(u8, msg, "error: test.bru:3:5: missing colon (MissingColon)") != null);
    try std.testing.expect(std.mem.indexOf(u8, msg, "  key value") != null);
    try std.testing.expect(std.mem.indexOf(u8, msg, "    ^") != null);
}
