const std = @import("std");
const Tokenizer = @import("tokenizer.zig").Tokenizer;
const Token = @import("tokenizer.zig").Token;
const TokenWithPos = @import("tokenizer.zig").TokenWithPos;
const ir = @import("ir.zig");
const errors = @import("errors.zig");

const Value = ir.Value;
const Entry = ir.Entry;
const Annotation = ir.Annotation;
const BruDocument = ir.BruDocument;

/// Parser that converts a token stream into a BruDocument IR.
pub const Parser = struct {
    tokenizer: Tokenizer,
    arena: std.mem.Allocator,
    current: ?TokenWithPos = null,
    comments: std.ArrayListUnmanaged([]const u8) = .empty,

    pub fn init(arena: std.mem.Allocator, source: []const u8) Parser {
        return .{
            .tokenizer = Tokenizer.init(source),
            .arena = arena,
        };
    }

    /// Advance to next token.
    fn advance(self: *Parser) errors.ParseError!?TokenWithPos {
        self.current = try self.tokenizer.next();
        return self.current;
    }

    /// Skip newlines, return next non-newline token.
    fn skipNewlines(self: *Parser) errors.ParseError!?TokenWithPos {
        while (true) {
            const tok = try self.advance();
            if (tok == null) return null;
            if (tok.?.token != .newline) return tok;
        }
    }

    /// Skip newlines and comments, collecting comments.
    fn skipNewlinesAndComments(self: *Parser) errors.ParseError!?TokenWithPos {
        while (true) {
            const tok = try self.advance();
            if (tok == null) return null;
            if (tok.?.token == .newline) continue;
            if (tok.?.token == .comment) {
                self.comments.append(self.arena, tok.?.lexeme) catch return error.UnexpectedToken;
                continue;
            }
            return tok;
        }
    }

    /// Parse entire document into a BruDocument.
    pub fn parseDocument(self: *Parser) errors.ParseError!BruDocument {
        var entries: std.ArrayListUnmanaged(Entry) = .empty;

        while (true) {
            const tok = try self.skipNewlinesAndComments();
            if (tok == null) break;
            if (tok.?.token == .eof) break;

            if (tok.?.token != .string and tok.?.token != .annotation) {
                return error.UnexpectedToken;
            }

            if (tok.?.token == .annotation) {
                self.comments.append(self.arena, tok.?.lexeme) catch return error.UnexpectedToken;
                continue;
            }

            const block_name_start = tok.?.lexeme;

            // Check for block qualifier (e.g., "body:json", "auth:bearer")
            const next_tok = try self.advance();
            var block_name: []const u8 = block_name_start;

            var is_array_block = false;

            if (next_tok != null and next_tok.?.token == .colon) {
                const qual_tok = try self.advance();
                if (qual_tok == null or (qual_tok.?.token != .string and qual_tok.?.token != .number)) {
                    return error.UnexpectedToken;
                }
                block_name = std.fmt.allocPrint(self.arena, "{s}:{s}", .{ block_name_start, qual_tok.?.lexeme }) catch return error.UnexpectedToken;
                const after_qual = try self.skipNewlines();
                if (after_qual == null or (after_qual.?.token != .l_brace and after_qual.?.token != .l_bracket)) {
                    return error.UnexpectedToken;
                }
                is_array_block = after_qual.?.token == .l_bracket;
            } else if (next_tok != null and (next_tok.?.token == .l_brace or next_tok.?.token == .l_bracket)) {
                is_array_block = next_tok.?.token == .l_bracket;
            } else if (next_tok != null and next_tok.?.token == .newline) {
                const brace_tok = try self.skipNewlines();
                if (brace_tok == null or (brace_tok.?.token != .l_brace and brace_tok.?.token != .l_bracket)) {
                    return error.UnexpectedToken;
                }
                is_array_block = brace_tok.?.token == .l_bracket;
            } else {
                return error.UnexpectedToken;
            }

            const value = if (is_array_block)
                try self.parseArray()
            else
                try self.parseBlockContent(block_name);
            const entry = Entry.init(block_name, value).withLine(tok.?.line);
            entries.append(self.arena, entry) catch return error.UnexpectedToken;
        }

        return BruDocument.init(self.arena, entries.toOwnedSlice(self.arena) catch return error.UnexpectedToken);
    }

    /// Parse the content inside a block { ... }
    fn parseBlockContent(self: *Parser, block_name: []const u8) errors.ParseError!Value {
        if (isMultistringBlock(block_name)) {
            return try self.parseMultistringContent();
        }
        return try self.parseMultimapContent();
    }

    /// Parse key-value pairs inside a block until }
    fn parseMultimapContent(self: *Parser) errors.ParseError!Value {
        var entries: std.ArrayListUnmanaged(Entry) = .empty;
        var pending_annotations: std.ArrayListUnmanaged(Annotation) = .empty;

        while (true) {
            const tok = try self.skipNewlines();
            if (tok == null) return error.UnclosedBlock;

            switch (tok.?.token) {
                .r_brace => break,
                .eof => return error.UnclosedBlock,
                .comment => {
                    self.comments.append(self.arena, tok.?.lexeme) catch {};
                    continue;
                },
                .annotation => {
                    const ann = try self.parseAnnotationValue(tok.?.lexeme);
                    pending_annotations.append(self.arena, ann) catch return error.UnexpectedToken;
                    continue;
                },
                .tilde => {
                    const key_tok = try self.advance();
                    if (key_tok == null or key_tok.?.token != .string) {
                        return error.UnexpectedToken;
                    }
                    const colon_tok = try self.advance();
                    if (colon_tok == null or colon_tok.?.token != .colon) {
                        return error.MissingColon;
                    }
                    const value = try self.parseValue();
                    var entry = Entry.init(key_tok.?.lexeme, value)
                        .withLine(tok.?.line)
                        .asDisabled();
                    if (pending_annotations.items.len > 0) {
                        entry = entry.withAnnotations(pending_annotations.toOwnedSlice(self.arena) catch return error.UnexpectedToken);
                        pending_annotations = .empty;
                    }
                    entries.append(self.arena, entry) catch return error.UnexpectedToken;
                },
                .string, .number => {
                    const key = tok.?.lexeme;
                    const colon_tok = try self.advance();
                    if (colon_tok == null or colon_tok.?.token != .colon) {
                        return error.MissingColon;
                    }
                    const value = try self.parseValue();
                    var entry = Entry.init(key, value).withLine(tok.?.line);
                    if (pending_annotations.items.len > 0) {
                        entry = entry.withAnnotations(pending_annotations.toOwnedSlice(self.arena) catch return error.UnexpectedToken);
                        pending_annotations = .empty;
                    }
                    entries.append(self.arena, entry) catch return error.UnexpectedToken;
                },
                else => return error.UnexpectedToken,
            }
        }

        return Value{ .multimap = entries.toOwnedSlice(self.arena) catch return error.UnexpectedToken };
    }

    /// Parse multistring content (everything between { and } as raw text).
    /// The closing } must be at the start of a line (with optional leading spaces).
    fn parseMultistringContent(self: *Parser) errors.ParseError!Value {
        var content: std.ArrayListUnmanaged(u8) = .empty;

        // Skip the newline right after {
        if (self.tokenizer.pos < self.tokenizer.source.len and self.tokenizer.source[self.tokenizer.pos] == '\n') {
            self.tokenizer.pos += 1;
            self.tokenizer.line += 1;
            self.tokenizer.column = 1;
        }

        while (self.tokenizer.pos < self.tokenizer.source.len) {
            // At start of each line, check if it's the closing }
            const line_start = self.tokenizer.pos;
            var indent: usize = 0;
            while (self.tokenizer.pos < self.tokenizer.source.len and self.tokenizer.source[self.tokenizer.pos] == ' ') {
                self.tokenizer.pos += 1;
                self.tokenizer.column += 1;
                indent += 1;
            }

            // Check for closing brace at indent 0 (the block-closing })
            if (indent == 0 and self.tokenizer.pos < self.tokenizer.source.len and self.tokenizer.source[self.tokenizer.pos] == '}') {
                self.tokenizer.pos += 1;
                self.tokenizer.column += 1;
                break;
            }

            // Not closing brace - rewind and strip up to 2 spaces of indentation
            self.tokenizer.pos = line_start;
            self.tokenizer.column -= indent;
            const strip = @min(indent, 2);
            self.tokenizer.pos += strip;
            self.tokenizer.column += strip;

            // Read the rest of the line
            while (self.tokenizer.pos < self.tokenizer.source.len) {
                const c = self.tokenizer.source[self.tokenizer.pos];
                if (c == '\n') {
                    content.append(self.arena, '\n') catch return error.UnexpectedToken;
                    self.tokenizer.pos += 1;
                    self.tokenizer.line += 1;
                    self.tokenizer.column = 1;
                    break;
                }
                if (c == '\r') {
                    self.tokenizer.pos += 1;
                    continue;
                }
                content.append(self.arena, c) catch return error.UnexpectedToken;
                self.tokenizer.pos += 1;
                self.tokenizer.column += 1;
            }
        }

        var slice = content.toOwnedSlice(self.arena) catch return error.UnexpectedToken;
        if (slice.len > 0 and slice[slice.len - 1] == '\n') {
            slice = slice[0 .. slice.len - 1];
        }

        return Value{ .multistring = slice };
    }

    /// Parse a value after a colon. For simple values, reads the rest of the line.
    fn parseValue(self: *Parser) errors.ParseError!Value {
        const tok = try self.advance();
        if (tok == null) return Value{ .null = {} };

        return switch (tok.?.token) {
            .null => Value{ .null = {} },
            .bool_true => Value{ .bool = true },
            .bool_false => Value{ .bool = false },
            .number => blk: {
                // Check if there's more on this line (e.g. after a number)
                const rest = self.readRestOfLine();
                if (rest.len > 0) {
                    const full = std.fmt.allocPrint(self.arena, "{s}{s}", .{ tok.?.lexeme, rest }) catch
                        break :blk Value{ .number = tok.?.lexeme };
                    break :blk Value{ .string = full };
                }
                break :blk Value{ .number = tok.?.lexeme };
            },
            .string => blk: {
                const first = stripQuotes(tok.?.lexeme);
                // If the string was quoted, return it as-is (don't read rest of line)
                if (tok.?.lexeme.len >= 2 and (tok.?.lexeme[0] == '"' or tok.?.lexeme[0] == '\'')) {
                    break :blk Value{ .string = first };
                }
                // Unquoted string: read rest of line to capture values like URLs
                const rest = self.readRestOfLine();
                if (rest.len > 0) {
                    const full = std.fmt.allocPrint(self.arena, "{s}{s}", .{ first, rest }) catch
                        break :blk Value{ .string = first };
                    break :blk Value{ .string = full };
                }
                break :blk Value{ .string = first };
            },
            .l_bracket => try self.parseArray(),
            .l_brace => blk: {
                // Check if this is a template variable {{...}} - treat as string value
                if (self.tokenizer.pos < self.tokenizer.source.len and
                    self.tokenizer.source[self.tokenizer.pos] == '{')
                {
                    const rest = self.readRestOfLine();
                    const full = std.fmt.allocPrint(self.arena, "{{{s}", .{rest}) catch
                        break :blk Value{ .string = "{" };
                    break :blk Value{ .string = full };
                }
                break :blk try self.parseMultimapContent();
            },
            .newline, .eof => Value{ .null = {} },
            .triple_quote => try self.parseTripleQuotedString(),
            else => blk: {
                // For annotations or other tokens appearing as values, read rest of line
                const rest = self.readRestOfLine();
                if (rest.len > 0) {
                    const full = std.fmt.allocPrint(self.arena, "{s}{s}", .{ tok.?.lexeme, rest }) catch
                        break :blk Value{ .string = tok.?.lexeme };
                    break :blk Value{ .string = full };
                }
                break :blk Value{ .string = tok.?.lexeme };
            },
        };
    }

    /// Read the rest of the current line from the tokenizer's raw source.
    /// Returns the remaining text (including leading space) until newline.
    fn readRestOfLine(self: *Parser) []const u8 {
        const start = self.tokenizer.pos;
        while (self.tokenizer.pos < self.tokenizer.source.len) {
            const c = self.tokenizer.source[self.tokenizer.pos];
            if (c == '\n' or c == '\r') break;
            self.tokenizer.pos += 1;
            self.tokenizer.column += 1;
        }
        const rest = self.tokenizer.source[start..self.tokenizer.pos];
        // Trim trailing whitespace
        var end = rest.len;
        while (end > 0 and (rest[end - 1] == ' ' or rest[end - 1] == '\t')) {
            end -= 1;
        }
        return rest[0..end];
    }

    /// Parse an array [value, value, ...]
    fn parseArray(self: *Parser) errors.ParseError!Value {
        var items: std.ArrayListUnmanaged(Value) = .empty;

        while (true) {
            const tok = try self.skipNewlines();
            if (tok == null) return error.UnclosedBlock;

            switch (tok.?.token) {
                .r_bracket => break,
                .eof => return error.UnclosedBlock,
                .comment => continue,
                .null => items.append(self.arena, Value{ .null = {} }) catch return error.UnexpectedToken,
                .bool_true => items.append(self.arena, Value{ .bool = true }) catch return error.UnexpectedToken,
                .bool_false => items.append(self.arena, Value{ .bool = false }) catch return error.UnexpectedToken,
                .number => items.append(self.arena, Value{ .number = tok.?.lexeme }) catch return error.UnexpectedToken,
                .string => items.append(self.arena, Value{ .string = stripQuotes(tok.?.lexeme) }) catch return error.UnexpectedToken,
                .l_bracket => {
                    const nested = try self.parseArray();
                    items.append(self.arena, nested) catch return error.UnexpectedToken;
                },
                .l_brace => {
                    const nested = try self.parseMultimapContent();
                    items.append(self.arena, nested) catch return error.UnexpectedToken;
                },
                else => return error.UnexpectedToken,
            }

            // Optional comma separator
            const sep = try self.advance();
            if (sep != null and sep.?.token == .r_bracket) break;
        }

        return Value{ .array = items.toOwnedSlice(self.arena) catch return error.UnexpectedToken };
    }

    /// Parse triple-quoted string content.
    fn parseTripleQuotedString(self: *Parser) errors.ParseError!Value {
        var content: std.ArrayListUnmanaged(u8) = .empty;

        while (self.tokenizer.pos < self.tokenizer.source.len) {
            if (self.tokenizer.pos + 2 < self.tokenizer.source.len and
                self.tokenizer.source[self.tokenizer.pos] == '"' and
                self.tokenizer.source[self.tokenizer.pos + 1] == '"' and
                self.tokenizer.source[self.tokenizer.pos + 2] == '"')
            {
                self.tokenizer.pos += 3;
                self.tokenizer.column += 3;
                return Value{ .multistring = content.toOwnedSlice(self.arena) catch return error.UnexpectedToken };
            }

            const c = self.tokenizer.source[self.tokenizer.pos];
            if (c == '\n') {
                content.append(self.arena, '\n') catch return error.UnexpectedToken;
                self.tokenizer.pos += 1;
                self.tokenizer.line += 1;
                self.tokenizer.column = 1;
            } else if (c == '\r') {
                self.tokenizer.pos += 1;
            } else {
                content.append(self.arena, c) catch return error.UnexpectedToken;
                self.tokenizer.pos += 1;
                self.tokenizer.column += 1;
            }
        }
        return error.InvalidMultistring;
    }

    /// Parse an annotation and its optional arguments.
    fn parseAnnotationValue(self: *Parser, lexeme: []const u8) errors.ParseError!Annotation {
        const name = lexeme[1..]; // strip @

        // Check if followed by (
        var check_pos = self.tokenizer.pos;
        while (check_pos < self.tokenizer.source.len and self.tokenizer.source[check_pos] == ' ') {
            check_pos += 1;
        }

        if (check_pos >= self.tokenizer.source.len or self.tokenizer.source[check_pos] != '(') {
            return Annotation.noArgs(name);
        }

        // Skip to past the (
        self.tokenizer.column += (check_pos - self.tokenizer.pos) + 1;
        self.tokenizer.pos = check_pos + 1;

        var args: std.ArrayListUnmanaged(Value) = .empty;

        while (true) {
            const tok = try self.advance();
            if (tok == null) return error.InvalidAnnotation;

            switch (tok.?.token) {
                .string => {
                    args.append(self.arena, Value{ .string = stripQuotes(tok.?.lexeme) }) catch return error.InvalidAnnotation;
                },
                .number => {
                    args.append(self.arena, Value{ .number = tok.?.lexeme }) catch return error.InvalidAnnotation;
                },
                .bool_true => {
                    args.append(self.arena, Value{ .bool = true }) catch return error.InvalidAnnotation;
                },
                .bool_false => {
                    args.append(self.arena, Value{ .bool = false }) catch return error.InvalidAnnotation;
                },
                .null => {
                    args.append(self.arena, Value{ .null = {} }) catch return error.InvalidAnnotation;
                },
                else => {
                    if (tok.?.lexeme.len > 0 and tok.?.lexeme[0] == ')') break;
                    continue;
                },
            }
        }

        return Annotation.init(name, args.toOwnedSlice(self.arena) catch return error.InvalidAnnotation);
    }
};

/// Strip surrounding quotes from a string lexeme if present.
pub fn stripQuotes(s: []const u8) []const u8 {
    if (s.len >= 2) {
        if ((s[0] == '"' and s[s.len - 1] == '"') or
            (s[0] == '\'' and s[s.len - 1] == '\''))
        {
            return s[1 .. s.len - 1];
        }
    }
    return s;
}

/// Determine if a block name should be parsed as multistring content.
fn isMultistringBlock(name: []const u8) bool {
    const multistring_blocks = [_][]const u8{
        "body:json",
        "body:xml",
        "body:text",
        "body:graphql",
        "body:graphql:vars",
        "body:sparql",
        "body:form-urlencoded",
        "body:multipart-form",
        "script:pre-request",
        "script:post-response",
        "tests",
        "docs",
    };
    for (&multistring_blocks) |block| {
        if (std.mem.eql(u8, name, block)) return true;
    }
    return false;
}

/// Convenience: parse a complete Bru source string.
pub fn parse(arena: std.mem.Allocator, source: []const u8) errors.ParseError!BruDocument {
    var p = Parser.init(arena, source);
    return p.parseDocument();
}

// ── Tests ──────────────────────────────────────────────────────────────

test "parse primitive values" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    const source =
        \\meta {
        \\  name: hello
        \\  count: 42
        \\  pi: 3.14
        \\  enabled: true
        \\  debug: false
        \\  empty: null
        \\}
    ;

    const doc = try parse(alloc, source);
    const meta = doc.getFirst("meta").?;
    switch (meta.value) {
        .multimap => |entries| {
            try std.testing.expectEqual(@as(usize, 6), entries.len);
            try std.testing.expectEqualStrings("name", entries[0].key);
            try std.testing.expectEqualStrings("hello", entries[0].value.asString().?);
            try std.testing.expectEqualStrings("42", entries[1].value.asString().?);
            try std.testing.expectEqual(true, entries[3].value.asBool().?);
            try std.testing.expectEqual(false, entries[4].value.asBool().?);
            try std.testing.expect(entries[5].value.isNull());
        },
        else => return error.UnexpectedToken,
    }
}

test "parse disabled entries with tilde" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    const source =
        \\headers {
        \\  Content-Type: application/json
        \\  ~Authorization: Bearer token
        \\}
    ;

    const doc = try parse(alloc, source);
    const headers = doc.getFirst("headers").?;
    switch (headers.value) {
        .multimap => |entries| {
            try std.testing.expectEqual(@as(usize, 2), entries.len);
            try std.testing.expectEqual(false, entries[0].disabled);
            try std.testing.expectEqual(true, entries[1].disabled);
            try std.testing.expectEqualStrings("Authorization", entries[1].key);
        },
        else => return error.UnexpectedToken,
    }
}

test "parse block with qualifier" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    const source =
        \\auth:bearer {
        \\  token: abc123
        \\}
    ;

    const doc = try parse(alloc, source);
    const auth = doc.getFirst("auth:bearer").?;
    switch (auth.value) {
        .multimap => |entries| {
            try std.testing.expectEqual(@as(usize, 1), entries.len);
            try std.testing.expectEqualStrings("token", entries[0].key);
        },
        else => return error.UnexpectedToken,
    }
}

test "parse multistring block" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    const source =
        \\body:json {
        \\  {
        \\    "key": "value"
        \\  }
        \\}
    ;

    const doc = try parse(alloc, source);
    const body = doc.getFirst("body:json").?;
    switch (body.value) {
        .multistring => |s| {
            try std.testing.expect(std.mem.indexOf(u8, s, "\"key\"") != null);
        },
        else => return error.UnexpectedToken,
    }
}

test "parse script block" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    const source =
        \\script:pre-request {
        \\  const token = "abc";
        \\  console.log(token);
        \\}
    ;

    const doc = try parse(alloc, source);
    const script = doc.getFirst("script:pre-request").?;
    switch (script.value) {
        .multistring => |s| {
            try std.testing.expect(std.mem.indexOf(u8, s, "const token") != null);
        },
        else => return error.UnexpectedToken,
    }
}

test "parse comments are preserved" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    const source =
        \\# Top comment
        \\meta {
        \\  # Inside comment
        \\  name: test
        \\}
    ;

    const doc = try parse(alloc, source);
    try std.testing.expect(doc.getFirst("meta") != null);
}

test "parse multiple blocks" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    const source =
        \\meta {
        \\  name: test
        \\}
        \\
        \\get {
        \\  url: https://example.com
        \\}
        \\
        \\headers {
        \\  Accept: application/json
        \\}
    ;

    const doc = try parse(alloc, source);
    try std.testing.expect(doc.getFirst("meta") != null);
    try std.testing.expect(doc.getFirst("get") != null);
    try std.testing.expect(doc.getFirst("headers") != null);
    try std.testing.expectEqual(@as(usize, 3), doc.entries.len);
}

test "parse quoted string values" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    const source =
        \\meta {
        \\  name: "my request"
        \\}
    ;

    const doc = try parse(alloc, source);
    const meta = doc.getFirst("meta").?;
    switch (meta.value) {
        .multimap => |entries| {
            try std.testing.expectEqualStrings("my request", entries[0].value.asString().?);
        },
        else => return error.UnexpectedToken,
    }
}

test "unclosed block error" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    const source =
        \\meta {
        \\  name: test
    ;

    try std.testing.expectError(error.UnclosedBlock, parse(alloc, source));
}

test "stripQuotes" {
    try std.testing.expectEqualStrings("hello", stripQuotes("\"hello\""));
    try std.testing.expectEqualStrings("hello", stripQuotes("'hello'"));
    try std.testing.expectEqualStrings("hello", stripQuotes("hello"));
    try std.testing.expectEqualStrings("", stripQuotes("\"\""));
}

test "isMultistringBlock" {
    try std.testing.expect(isMultistringBlock("body:json"));
    try std.testing.expect(isMultistringBlock("script:pre-request"));
    try std.testing.expect(isMultistringBlock("tests"));
    try std.testing.expect(isMultistringBlock("docs"));
    try std.testing.expect(!isMultistringBlock("meta"));
    try std.testing.expect(!isMultistringBlock("headers"));
}
