const std = @import("std");
const errors = @import("errors.zig");

pub const Token = enum {
    l_brace,
    r_brace,
    l_bracket,
    r_bracket,
    colon,
    string,
    number,
    bool_true,
    bool_false,
    null,
    newline,
    comment,
    annotation,
    triple_quote,
    tilde,
    eof,
};

pub const TokenWithPos = struct {
    token: Token,
    line: usize,
    column: usize,
    lexeme: []const u8,
};

pub const Tokenizer = struct {
    source: []const u8,
    pos: usize,
    line: usize,
    column: usize,

    pub fn init(source: []const u8) Tokenizer {
        return .{
            .source = source,
            .pos = 0,
            .line = 1,
            .column = 1,
        };
    }

    /// Advance position past whitespace (spaces and tabs only, not newlines).
    fn skipWhitespace(self: *Tokenizer) void {
        while (self.pos < self.source.len) {
            const c = self.source[self.pos];
            if (c == ' ' or c == '\t') {
                self.pos += 1;
                self.column += 1;
            } else if (c == '\r') {
                // Skip \r (handle as part of CRLF normalization lazily)
                self.pos += 1;
            } else {
                break;
            }
        }
    }

    fn peekChar(self: *Tokenizer) ?u8 {
        if (self.pos < self.source.len) return self.source[self.pos];
        return null;
    }

    fn advance(self: *Tokenizer) ?u8 {
        if (self.pos >= self.source.len) return null;
        const c = self.source[self.pos];
        self.pos += 1;
        if (c == '\n') {
            self.line += 1;
            self.column = 1;
        } else {
            self.column += 1;
        }
        return c;
    }

    /// Return the next token, or null at end-of-file.
    pub fn next(self: *Tokenizer) errors.ParseError!?TokenWithPos {
        self.skipWhitespace();

        if (self.pos >= self.source.len) {
            return TokenWithPos{
                .token = .eof,
                .line = self.line,
                .column = self.column,
                .lexeme = "",
            };
        }

        const start_line = self.line;
        const start_col = self.column;
        const start_pos = self.pos;
        const c = self.source[self.pos];

        switch (c) {
            '{' => {
                _ = self.advance();
                return tok(.l_brace, start_line, start_col, self.source[start_pos..self.pos]);
            },
            '}' => {
                _ = self.advance();
                return tok(.r_brace, start_line, start_col, self.source[start_pos..self.pos]);
            },
            '[' => {
                _ = self.advance();
                return tok(.l_bracket, start_line, start_col, self.source[start_pos..self.pos]);
            },
            ']' => {
                _ = self.advance();
                return tok(.r_bracket, start_line, start_col, self.source[start_pos..self.pos]);
            },
            ':' => {
                _ = self.advance();
                return tok(.colon, start_line, start_col, self.source[start_pos..self.pos]);
            },
            '~' => {
                _ = self.advance();
                return tok(.tilde, start_line, start_col, self.source[start_pos..self.pos]);
            },
            '\n' => {
                _ = self.advance();
                return tok(.newline, start_line, start_col, self.source[start_pos..self.pos]);
            },
            '#' => {
                return self.readComment(start_line, start_col, start_pos);
            },
            '@' => {
                return self.readAnnotation(start_line, start_col, start_pos);
            },
            '"' => {
                return self.readString(start_line, start_col, start_pos);
            },
            '\'' => {
                return self.readSingleQuotedString(start_line, start_col, start_pos);
            },
            else => {
                // Number, keyword (true/false/null), or unquoted string
                return self.readWord(start_line, start_col, start_pos);
            },
        }
    }

    fn readComment(self: *Tokenizer, start_line: usize, start_col: usize, start_pos: usize) errors.ParseError!?TokenWithPos {
        // Skip everything until end of line
        while (self.pos < self.source.len and self.source[self.pos] != '\n') {
            self.pos += 1;
            self.column += 1;
        }
        return tok(.comment, start_line, start_col, self.source[start_pos..self.pos]);
    }

    fn readAnnotation(self: *Tokenizer, start_line: usize, start_col: usize, start_pos: usize) errors.ParseError!?TokenWithPos {
        _ = self.advance(); // skip @
        // Read annotation name (alphanumeric + underscore + hyphen)
        while (self.pos < self.source.len) {
            const ch = self.source[self.pos];
            if (std.ascii.isAlphanumeric(ch) or ch == '_' or ch == '-') {
                self.pos += 1;
                self.column += 1;
            } else {
                break;
            }
        }
        if (self.pos == start_pos + 1) {
            // @ with no name
            return error.InvalidAnnotation;
        }
        return tok(.annotation, start_line, start_col, self.source[start_pos..self.pos]);
    }

    fn readString(self: *Tokenizer, start_line: usize, start_col: usize, start_pos: usize) errors.ParseError!?TokenWithPos {
        // Check for triple quote """
        if (self.pos + 2 < self.source.len and
            self.source[self.pos + 1] == '"' and
            self.source[self.pos + 2] == '"')
        {
            self.pos += 3;
            self.column += 3;
            return tok(.triple_quote, start_line, start_col, self.source[start_pos .. start_pos + 3]);
        }

        _ = self.advance(); // skip opening "
        while (self.pos < self.source.len) {
            const ch = self.source[self.pos];
            if (ch == '"') {
                _ = self.advance(); // skip closing "
                return tok(.string, start_line, start_col, self.source[start_pos..self.pos]);
            }
            if (ch == '\\') {
                _ = self.advance(); // skip backslash
                _ = self.advance(); // skip escaped char
                continue;
            }
            if (ch == '\n') {
                return error.UnterminatedString;
            }
            _ = self.advance();
        }
        return error.UnterminatedString;
    }

    fn readSingleQuotedString(self: *Tokenizer, start_line: usize, start_col: usize, start_pos: usize) errors.ParseError!?TokenWithPos {
        _ = self.advance(); // skip opening '
        while (self.pos < self.source.len) {
            const ch = self.source[self.pos];
            if (ch == '\'') {
                _ = self.advance(); // skip closing '
                return tok(.string, start_line, start_col, self.source[start_pos..self.pos]);
            }
            if (ch == '\\') {
                _ = self.advance();
                _ = self.advance();
                continue;
            }
            if (ch == '\n') {
                return error.UnterminatedString;
            }
            _ = self.advance();
        }
        return error.UnterminatedString;
    }

    fn readWord(self: *Tokenizer, start_line: usize, start_col: usize, start_pos: usize) errors.ParseError!?TokenWithPos {
        // Read an unquoted word (everything until whitespace, colon, brace, bracket, newline, or comment)
        while (self.pos < self.source.len) {
            const ch = self.source[self.pos];
            if (ch == ' ' or ch == '\t' or ch == '\n' or ch == '\r' or
                ch == ':' or ch == '{' or ch == '}' or
                ch == '[' or ch == ']' or ch == '#' or ch == ',')
            {
                break;
            }
            self.pos += 1;
            self.column += 1;
        }

        const lexeme = self.source[start_pos..self.pos];
        if (lexeme.len == 0) {
            return error.UnexpectedToken;
        }

        // Classify the word
        if (std.mem.eql(u8, lexeme, "true")) {
            return tok(.bool_true, start_line, start_col, lexeme);
        }
        if (std.mem.eql(u8, lexeme, "false")) {
            return tok(.bool_false, start_line, start_col, lexeme);
        }
        if (std.mem.eql(u8, lexeme, "null")) {
            return tok(.null, start_line, start_col, lexeme);
        }

        // Check if it looks like a number
        if (isNumber(lexeme)) {
            return tok(.number, start_line, start_col, lexeme);
        }

        return tok(.string, start_line, start_col, lexeme);
    }

    fn tok(token: Token, line: usize, column: usize, lexeme: []const u8) TokenWithPos {
        return .{
            .token = token,
            .line = line,
            .column = column,
            .lexeme = lexeme,
        };
    }
};

/// Check if a string looks like a valid number.
fn isNumber(s: []const u8) bool {
    if (s.len == 0) return false;

    var i: usize = 0;
    // Optional sign
    if (s[i] == '-' or s[i] == '+') {
        i += 1;
        if (i == s.len) return false;
    }
    // Need at least one digit
    if (i >= s.len) return false;
    if (!std.ascii.isDigit(s[i]) and s[i] != '.') return false;

    var has_dot = false;
    var has_e = false;
    while (i < s.len) : (i += 1) {
        const c = s[i];
        if (std.ascii.isDigit(c)) continue;
        if (c == '.' and !has_dot and !has_e) {
            has_dot = true;
            continue;
        }
        if ((c == 'e' or c == 'E') and !has_e) {
            has_e = true;
            // optional sign after e
            if (i + 1 < s.len and (s[i + 1] == '+' or s[i + 1] == '-')) {
                i += 1;
            }
            continue;
        }
        return false;
    }
    return true;
}

// ── Tests ──────────────────────────────────────────────────────────────

test "tokenize structural tokens" {
    var tokenizer = Tokenizer.init("{}[]:~");
    try std.testing.expectEqual(Token.l_brace, (try tokenizer.next()).?.token);
    try std.testing.expectEqual(Token.r_brace, (try tokenizer.next()).?.token);
    try std.testing.expectEqual(Token.l_bracket, (try tokenizer.next()).?.token);
    try std.testing.expectEqual(Token.r_bracket, (try tokenizer.next()).?.token);
    try std.testing.expectEqual(Token.colon, (try tokenizer.next()).?.token);
    try std.testing.expectEqual(Token.tilde, (try tokenizer.next()).?.token);
    try std.testing.expectEqual(Token.eof, (try tokenizer.next()).?.token);
}

test "tokenize keywords" {
    var tokenizer = Tokenizer.init("true false null");
    try std.testing.expectEqual(Token.bool_true, (try tokenizer.next()).?.token);
    try std.testing.expectEqual(Token.bool_false, (try tokenizer.next()).?.token);
    try std.testing.expectEqual(Token.null, (try tokenizer.next()).?.token);
}

test "tokenize numbers" {
    var tokenizer = Tokenizer.init("42 3.14 -1 1e10 2.5E-3");
    const t1 = (try tokenizer.next()).?;
    try std.testing.expectEqual(Token.number, t1.token);
    try std.testing.expectEqualStrings("42", t1.lexeme);

    const t2 = (try tokenizer.next()).?;
    try std.testing.expectEqual(Token.number, t2.token);
    try std.testing.expectEqualStrings("3.14", t2.lexeme);

    try std.testing.expectEqual(Token.number, (try tokenizer.next()).?.token);
    try std.testing.expectEqual(Token.number, (try tokenizer.next()).?.token);
    try std.testing.expectEqual(Token.number, (try tokenizer.next()).?.token);
}

test "tokenize double-quoted strings" {
    var tokenizer = Tokenizer.init("\"hello world\" \"with \\\"escape\\\"\"");
    const t1 = (try tokenizer.next()).?;
    try std.testing.expectEqual(Token.string, t1.token);
    try std.testing.expectEqualStrings("\"hello world\"", t1.lexeme);

    const t2 = (try tokenizer.next()).?;
    try std.testing.expectEqual(Token.string, t2.token);
}

test "tokenize single-quoted strings" {
    var tokenizer = Tokenizer.init("'hello'");
    const t1 = (try tokenizer.next()).?;
    try std.testing.expectEqual(Token.string, t1.token);
    try std.testing.expectEqualStrings("'hello'", t1.lexeme);
}

test "tokenize comments" {
    var tokenizer = Tokenizer.init("# this is a comment\nvalue");
    const t1 = (try tokenizer.next()).?;
    try std.testing.expectEqual(Token.comment, t1.token);
    try std.testing.expectEqualStrings("# this is a comment", t1.lexeme);

    try std.testing.expectEqual(Token.newline, (try tokenizer.next()).?.token);
    try std.testing.expectEqual(Token.string, (try tokenizer.next()).?.token);
}

test "tokenize annotations" {
    var tokenizer = Tokenizer.init("@disabled @description");
    const t1 = (try tokenizer.next()).?;
    try std.testing.expectEqual(Token.annotation, t1.token);
    try std.testing.expectEqualStrings("@disabled", t1.lexeme);

    const t2 = (try tokenizer.next()).?;
    try std.testing.expectEqual(Token.annotation, t2.token);
    try std.testing.expectEqualStrings("@description", t2.lexeme);
}

test "tokenize triple quotes" {
    var tokenizer = Tokenizer.init("\"\"\" content \"\"\"");
    try std.testing.expectEqual(Token.triple_quote, (try tokenizer.next()).?.token);
    try std.testing.expectEqual(Token.string, (try tokenizer.next()).?.token);
    try std.testing.expectEqual(Token.triple_quote, (try tokenizer.next()).?.token);
}

test "position tracking" {
    var tokenizer = Tokenizer.init("ab\ncd");
    const t1 = (try tokenizer.next()).?;
    try std.testing.expectEqual(@as(usize, 1), t1.line);
    try std.testing.expectEqual(@as(usize, 1), t1.column);

    _ = try tokenizer.next(); // newline
    const t3 = (try tokenizer.next()).?;
    try std.testing.expectEqual(@as(usize, 2), t3.line);
    try std.testing.expectEqual(@as(usize, 1), t3.column);
}

test "CRLF handling" {
    var tokenizer = Tokenizer.init("a\r\nb");
    const t1 = (try tokenizer.next()).?;
    try std.testing.expectEqual(Token.string, t1.token);
    try std.testing.expectEqual(Token.newline, (try tokenizer.next()).?.token);
    const t3 = (try tokenizer.next()).?;
    try std.testing.expectEqual(Token.string, t3.token);
    try std.testing.expectEqualStrings("b", t3.lexeme);
}

test "unterminated string error" {
    var tokenizer = Tokenizer.init("\"unclosed");
    try std.testing.expectError(error.UnterminatedString, tokenizer.next());
}

test "invalid annotation error" {
    var tokenizer = Tokenizer.init("@ ");
    try std.testing.expectError(error.InvalidAnnotation, tokenizer.next());
}

test "unquoted strings" {
    var tokenizer = Tokenizer.init("hello world");
    const t1 = (try tokenizer.next()).?;
    try std.testing.expectEqual(Token.string, t1.token);
    try std.testing.expectEqualStrings("hello", t1.lexeme);
}

test "isNumber" {
    try std.testing.expect(isNumber("123"));
    try std.testing.expect(isNumber("-42"));
    try std.testing.expect(isNumber("3.14"));
    try std.testing.expect(isNumber("1e10"));
    try std.testing.expect(isNumber("2.5E-3"));
    try std.testing.expect(!isNumber("abc"));
    try std.testing.expect(!isNumber(""));
    try std.testing.expect(!isNumber("-"));
    try std.testing.expect(!isNumber("1.2.3"));
}

test "tokenize bru-like block" {
    const source =
        \\meta {
        \\  name: my-request
        \\  type: http
        \\}
    ;
    var tokenizer = Tokenizer.init(source);

    // meta
    const t1 = (try tokenizer.next()).?;
    try std.testing.expectEqual(Token.string, t1.token);
    try std.testing.expectEqualStrings("meta", t1.lexeme);

    // {
    try std.testing.expectEqual(Token.l_brace, (try tokenizer.next()).?.token);
    // newline
    try std.testing.expectEqual(Token.newline, (try tokenizer.next()).?.token);

    // name
    const t4 = (try tokenizer.next()).?;
    try std.testing.expectEqual(Token.string, t4.token);
    try std.testing.expectEqualStrings("name", t4.lexeme);

    // :
    try std.testing.expectEqual(Token.colon, (try tokenizer.next()).?.token);
    // my-request (unquoted string)
    const t6 = (try tokenizer.next()).?;
    try std.testing.expectEqual(Token.string, t6.token);
    try std.testing.expectEqualStrings("my-request", t6.lexeme);
}
