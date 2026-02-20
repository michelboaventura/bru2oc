const std = @import("std");
const oc = @import("opencollection.zig");

pub const YamlParseError = error{
    InvalidYaml,
    MissingRequiredField,
    OutOfMemory,
};

/// Parse OpenCollection YAML into an OpenCollectionRequest.
pub fn parse(allocator: std.mem.Allocator, yaml: []const u8) YamlParseError!oc.OpenCollectionRequest {
    var p = YamlParser.init(allocator, yaml);
    return p.parseDocument();
}

const YamlParser = struct {
    alloc: std.mem.Allocator,
    lines: std.ArrayListUnmanaged(Line),
    pos: usize,

    const Line = struct {
        indent: usize,
        content: []const u8,
        raw: []const u8,
    };

    fn init(alloc: std.mem.Allocator, yaml: []const u8) YamlParser {
        var lines: std.ArrayListUnmanaged(Line) = .empty;
        var iter = std.mem.splitScalar(u8, yaml, '\n');
        while (iter.next()) |raw| {
            const trimmed = std.mem.trimLeft(u8, raw, " ");
            if (trimmed.len == 0) continue;
            if (trimmed[0] == '#') continue; // skip comments
            const indent = raw.len - trimmed.len;
            lines.append(alloc, .{
                .indent = indent,
                .content = trimmed,
                .raw = raw,
            }) catch {};
        }
        return .{ .alloc = alloc, .lines = lines, .pos = 0 };
    }

    fn peek(self: *YamlParser) ?Line {
        if (self.pos >= self.lines.items.len) return null;
        return self.lines.items[self.pos];
    }

    fn advance(self: *YamlParser) ?Line {
        if (self.pos >= self.lines.items.len) return null;
        const line = self.lines.items[self.pos];
        self.pos += 1;
        return line;
    }

    fn parseKeyValue(content: []const u8) ?struct { key: []const u8, value: []const u8 } {
        // Handle "- key: value" (list item with key-value)
        var c = content;
        if (std.mem.startsWith(u8, c, "- ")) {
            c = c[2..];
        }
        const colon = std.mem.indexOf(u8, c, ": ") orelse {
            // Check for "key:" with no value
            if (c.len > 0 and c[c.len - 1] == ':') {
                return .{ .key = c[0 .. c.len - 1], .value = "" };
            }
            return null;
        };
        return .{ .key = c[0..colon], .value = c[colon + 2 ..] };
    }

    fn unquote(s: []const u8) []const u8 {
        if (s.len >= 2) {
            if ((s[0] == '"' and s[s.len - 1] == '"') or (s[0] == '\'' and s[s.len - 1] == '\'')) {
                return s[1 .. s.len - 1];
            }
        }
        return s;
    }

    fn parseDocument(self: *YamlParser) YamlParseError!oc.OpenCollectionRequest {
        var info: ?oc.Info = null;
        var http: ?oc.Http = null;
        var runtime: ?oc.Runtime = null;
        var settings: ?oc.Settings = null;
        var docs: ?oc.Docs = null;

        while (self.peek()) |line| {
            if (line.indent != 0) {
                _ = self.advance();
                continue;
            }
            const kv = parseKeyValue(line.content) orelse {
                _ = self.advance();
                continue;
            };
            if (std.mem.eql(u8, kv.key, "info")) {
                _ = self.advance();
                info = try self.parseInfo();
            } else if (std.mem.eql(u8, kv.key, "http")) {
                _ = self.advance();
                http = try self.parseHttp();
            } else if (std.mem.eql(u8, kv.key, "runtime")) {
                _ = self.advance();
                runtime = try self.parseRuntime();
            } else if (std.mem.eql(u8, kv.key, "settings")) {
                _ = self.advance();
                settings = try self.parseSettings();
            } else if (std.mem.eql(u8, kv.key, "docs")) {
                _ = self.advance();
                docs = try self.parseDocs();
            } else {
                _ = self.advance();
            }
        }

        if (info == null) return error.MissingRequiredField;
        if (http == null) return error.MissingRequiredField;

        return oc.OpenCollectionRequest{
            .info = info.?,
            .http = http.?,
            .runtime = runtime,
            .settings = settings,
            .docs = docs,
        };
    }

    fn parseInfo(self: *YamlParser) YamlParseError!oc.Info {
        var name: ?[]const u8 = null;
        var req_type: []const u8 = "http";
        var seq: ?usize = null;

        while (self.peek()) |line| {
            if (line.indent < 2) break;
            _ = self.advance();
            const kv = parseKeyValue(line.content) orelse continue;
            if (std.mem.eql(u8, kv.key, "name")) {
                name = unquote(kv.value);
            } else if (std.mem.eql(u8, kv.key, "type")) {
                req_type = unquote(kv.value);
            } else if (std.mem.eql(u8, kv.key, "seq")) {
                seq = std.fmt.parseInt(usize, kv.value, 10) catch null;
            }
        }

        if (name == null) return error.MissingRequiredField;
        return oc.Info{ .name = name.?, .type = req_type, .seq = seq };
    }

    fn parseHttp(self: *YamlParser) YamlParseError!oc.Http {
        var method: ?[]const u8 = null;
        var url: ?[]const u8 = null;
        var headers: ?[]const oc.Header = null;
        var params: ?[]const oc.Param = null;
        var body: ?oc.Body = null;
        var auth: ?oc.Auth = null;

        while (self.peek()) |line| {
            if (line.indent < 2) break;
            const kv = parseKeyValue(line.content) orelse {
                _ = self.advance();
                continue;
            };
            if (std.mem.eql(u8, kv.key, "method")) {
                _ = self.advance();
                method = unquote(kv.value);
            } else if (std.mem.eql(u8, kv.key, "url")) {
                _ = self.advance();
                url = unquote(kv.value);
            } else if (std.mem.eql(u8, kv.key, "headers")) {
                _ = self.advance();
                headers = try self.parseHeaders();
            } else if (std.mem.eql(u8, kv.key, "params")) {
                _ = self.advance();
                params = try self.parseParams();
            } else if (std.mem.eql(u8, kv.key, "body")) {
                _ = self.advance();
                body = try self.parseBody();
            } else if (std.mem.eql(u8, kv.key, "auth")) {
                _ = self.advance();
                auth = try self.parseAuth();
            } else {
                _ = self.advance();
            }
        }

        if (method == null) return error.MissingRequiredField;
        if (url == null) return error.MissingRequiredField;

        return oc.Http{
            .method = method.?,
            .url = url.?,
            .headers = headers,
            .params = params,
            .body = body,
            .auth = auth,
        };
    }

    fn parseHeaders(self: *YamlParser) YamlParseError![]const oc.Header {
        var headers: std.ArrayListUnmanaged(oc.Header) = .empty;
        while (self.peek()) |line| {
            if (line.indent < 4) break;
            if (!std.mem.startsWith(u8, line.content, "- ")) {
                _ = self.advance();
                continue;
            }
            _ = self.advance();
            var h = oc.Header{ .name = "", .value = "" };
            // Parse the first field from the "- name: ..." line
            const first_kv = parseKeyValue(line.content);
            if (first_kv) |fkv| {
                if (std.mem.eql(u8, fkv.key, "name")) h.name = unquote(fkv.value);
                if (std.mem.eql(u8, fkv.key, "value")) h.value = unquote(fkv.value);
            }
            // Parse continuation lines at higher indent
            while (self.peek()) |next| {
                if (next.indent < 6) break;
                _ = self.advance();
                const nkv = parseKeyValue(next.content) orelse continue;
                if (std.mem.eql(u8, nkv.key, "name")) h.name = unquote(nkv.value);
                if (std.mem.eql(u8, nkv.key, "value")) h.value = unquote(nkv.value);
                if (std.mem.eql(u8, nkv.key, "enabled")) h.enabled = std.mem.eql(u8, nkv.value, "true");
            }
            headers.append(self.alloc, h) catch {};
        }
        return headers.toOwnedSlice(self.alloc) catch &.{};
    }

    fn parseParams(self: *YamlParser) YamlParseError![]const oc.Param {
        var params: std.ArrayListUnmanaged(oc.Param) = .empty;
        while (self.peek()) |line| {
            if (line.indent < 4) break;
            if (!std.mem.startsWith(u8, line.content, "- ")) {
                _ = self.advance();
                continue;
            }
            _ = self.advance();
            var p = oc.Param{ .name = "", .value = "" };
            const first_kv = parseKeyValue(line.content);
            if (first_kv) |fkv| {
                if (std.mem.eql(u8, fkv.key, "name")) p.name = unquote(fkv.value);
                if (std.mem.eql(u8, fkv.key, "value")) p.value = unquote(fkv.value);
            }
            while (self.peek()) |next| {
                if (next.indent < 6) break;
                _ = self.advance();
                const nkv = parseKeyValue(next.content) orelse continue;
                if (std.mem.eql(u8, nkv.key, "name")) p.name = unquote(nkv.value);
                if (std.mem.eql(u8, nkv.key, "value")) p.value = unquote(nkv.value);
                if (std.mem.eql(u8, nkv.key, "type")) {
                    if (std.mem.eql(u8, nkv.value, "path")) p.param_type = .path;
                }
                if (std.mem.eql(u8, nkv.key, "enabled")) p.enabled = std.mem.eql(u8, nkv.value, "true");
            }
            params.append(self.alloc, p) catch {};
        }
        return params.toOwnedSlice(self.alloc) catch &.{};
    }

    fn parseBody(self: *YamlParser) YamlParseError!oc.Body {
        var body_type: ?[]const u8 = null;
        var data: ?[]const u8 = null;

        while (self.peek()) |line| {
            if (line.indent < 4) break;
            _ = self.advance();
            const kv = parseKeyValue(line.content) orelse continue;
            if (std.mem.eql(u8, kv.key, "type")) {
                body_type = unquote(kv.value);
            } else if (std.mem.eql(u8, kv.key, "data")) {
                // Check for multiline block scalar
                if (std.mem.eql(u8, kv.value, "|")) {
                    data = self.readBlockScalar();
                } else {
                    data = unquote(kv.value);
                }
            }
        }

        const bt = body_type orelse "text";
        const d = data orelse "";

        if (std.mem.eql(u8, bt, "json")) return oc.Body{ .json = d };
        if (std.mem.eql(u8, bt, "xml")) return oc.Body{ .xml = d };
        if (std.mem.eql(u8, bt, "graphql")) return oc.Body{ .graphql = .{ .query = d } };
        if (std.mem.eql(u8, bt, "sparql")) return oc.Body{ .sparql = d };
        return oc.Body{ .text = d };
    }

    fn readBlockScalar(self: *YamlParser) []const u8 {
        var buf: std.ArrayListUnmanaged(u8) = .empty;
        const block_indent = if (self.peek()) |l| l.indent else return "";

        while (self.peek()) |line| {
            if (line.indent < block_indent) break;
            _ = self.advance();
            if (buf.items.len > 0) buf.append(self.alloc, '\n') catch {};
            // Strip the block indent
            if (line.raw.len > block_indent) {
                buf.appendSlice(self.alloc, line.raw[block_indent..]) catch {};
            } else {
                buf.appendSlice(self.alloc, line.content) catch {};
            }
        }
        return buf.toOwnedSlice(self.alloc) catch "";
    }

    fn parseAuth(self: *YamlParser) YamlParseError!oc.Auth {
        var auth_type: ?[]const u8 = null;
        var token: ?[]const u8 = null;
        var username: ?[]const u8 = null;
        var password: ?[]const u8 = null;
        var access_key: ?[]const u8 = null;
        var secret_key: ?[]const u8 = null;
        var region: ?[]const u8 = null;
        var service: ?[]const u8 = null;

        while (self.peek()) |line| {
            if (line.indent < 4) break;
            _ = self.advance();
            const kv = parseKeyValue(line.content) orelse continue;
            if (std.mem.eql(u8, kv.key, "type")) auth_type = unquote(kv.value);
            if (std.mem.eql(u8, kv.key, "token")) token = unquote(kv.value);
            if (std.mem.eql(u8, kv.key, "username")) username = unquote(kv.value);
            if (std.mem.eql(u8, kv.key, "password")) password = unquote(kv.value);
            if (std.mem.eql(u8, kv.key, "access_key")) access_key = unquote(kv.value);
            if (std.mem.eql(u8, kv.key, "secret_key")) secret_key = unquote(kv.value);
            if (std.mem.eql(u8, kv.key, "region")) region = unquote(kv.value);
            if (std.mem.eql(u8, kv.key, "service")) service = unquote(kv.value);
        }

        const at = auth_type orelse return oc.Auth{ .none = {} };
        if (std.mem.eql(u8, at, "bearer")) {
            return oc.Auth{ .bearer = .{ .token = token orelse "" } };
        }
        if (std.mem.eql(u8, at, "basic")) {
            return oc.Auth{ .basic = .{ .username = username orelse "", .password = password orelse "" } };
        }
        if (std.mem.eql(u8, at, "oauth2")) {
            return oc.Auth{ .oauth2 = .{ .access_token = token orelse "" } };
        }
        if (std.mem.eql(u8, at, "aws_v4")) {
            return oc.Auth{ .aws_v4 = .{
                .access_key = access_key orelse "",
                .secret_key = secret_key orelse "",
                .region = region orelse "",
                .service = service orelse "",
            } };
        }
        if (std.mem.eql(u8, at, "digest")) {
            return oc.Auth{ .digest = .{ .username = username orelse "", .password = password orelse "" } };
        }
        if (std.mem.eql(u8, at, "inherit")) {
            return oc.Auth{ .inherit = {} };
        }
        return oc.Auth{ .none = {} };
    }

    fn parseSettings(self: *YamlParser) YamlParseError!oc.Settings {
        var settings = oc.Settings{};

        while (self.peek()) |line| {
            if (line.indent < 2) break;
            const kv = parseKeyValue(line.content) orelse {
                _ = self.advance();
                continue;
            };
            _ = self.advance();
            if (std.mem.eql(u8, kv.key, "encodeUrl")) {
                settings.encode_url = std.mem.eql(u8, unquote(kv.value), "true");
            } else if (std.mem.eql(u8, kv.key, "timeout")) {
                settings.timeout = std.fmt.parseInt(usize, unquote(kv.value), 10) catch null;
            } else if (std.mem.eql(u8, kv.key, "followRedirects")) {
                settings.follow_redirects = std.mem.eql(u8, unquote(kv.value), "true");
            }
        }

        return settings;
    }

    fn parseRuntime(self: *YamlParser) YamlParseError!oc.Runtime {
        var scripts: std.ArrayListUnmanaged(oc.Script) = .empty;
        var assertions: std.ArrayListUnmanaged(oc.Assertion) = .empty;
        var vars: std.ArrayListUnmanaged(oc.Var) = .empty;

        while (self.peek()) |line| {
            if (line.indent < 2) break;
            const kv = parseKeyValue(line.content) orelse {
                _ = self.advance();
                continue;
            };
            if (std.mem.eql(u8, kv.key, "scripts")) {
                _ = self.advance();
                self.parseScripts(&scripts);
            } else if (std.mem.eql(u8, kv.key, "assertions")) {
                _ = self.advance();
                self.parseAssertions(&assertions);
            } else if (std.mem.eql(u8, kv.key, "vars")) {
                _ = self.advance();
                self.parseVars(&vars);
            } else {
                _ = self.advance();
            }
        }

        return oc.Runtime{
            .scripts = if (scripts.items.len > 0) scripts.toOwnedSlice(self.alloc) catch null else null,
            .assertions = if (assertions.items.len > 0) assertions.toOwnedSlice(self.alloc) catch null else null,
            .vars = if (vars.items.len > 0) vars.toOwnedSlice(self.alloc) catch null else null,
        };
    }

    fn parseScripts(self: *YamlParser, scripts: *std.ArrayListUnmanaged(oc.Script)) void {
        while (self.peek()) |line| {
            if (line.indent < 4) break;
            if (!std.mem.startsWith(u8, line.content, "- ")) {
                _ = self.advance();
                continue;
            }
            _ = self.advance();
            var s = oc.Script{ .script_type = .before_request, .code = "" };
            const first_kv = parseKeyValue(line.content);
            if (first_kv) |fkv| {
                if (std.mem.eql(u8, fkv.key, "type")) {
                    if (std.mem.eql(u8, fkv.value, "after_response")) s.script_type = .after_response;
                    if (std.mem.eql(u8, fkv.value, "tests")) s.script_type = .tests;
                }
            }
            while (self.peek()) |next| {
                if (next.indent < 6) break;
                _ = self.advance();
                const nkv = parseKeyValue(next.content) orelse continue;
                if (std.mem.eql(u8, nkv.key, "type")) {
                    if (std.mem.eql(u8, nkv.value, "after_response")) s.script_type = .after_response;
                    if (std.mem.eql(u8, nkv.value, "tests")) s.script_type = .tests;
                }
                if (std.mem.eql(u8, nkv.key, "code")) {
                    if (std.mem.eql(u8, nkv.value, "|")) {
                        s.code = self.readBlockScalar();
                    } else {
                        s.code = unquote(nkv.value);
                    }
                }
            }
            scripts.append(self.alloc, s) catch {};
        }
    }

    fn parseAssertions(self: *YamlParser, assertions: *std.ArrayListUnmanaged(oc.Assertion)) void {
        while (self.peek()) |line| {
            if (line.indent < 4) break;
            if (!std.mem.startsWith(u8, line.content, "- ")) {
                _ = self.advance();
                continue;
            }
            _ = self.advance();
            var a = oc.Assertion{ .expression = "", .operator = .eq, .value = "" };
            const first_kv = parseKeyValue(line.content);
            if (first_kv) |fkv| {
                if (std.mem.eql(u8, fkv.key, "expression")) a.expression = unquote(fkv.value);
            }
            while (self.peek()) |next| {
                if (next.indent < 6) break;
                _ = self.advance();
                const nkv = parseKeyValue(next.content) orelse continue;
                if (std.mem.eql(u8, nkv.key, "expression")) a.expression = unquote(nkv.value);
                if (std.mem.eql(u8, nkv.key, "operator")) a.operator = parseOperator(nkv.value);
                if (std.mem.eql(u8, nkv.key, "value")) a.value = unquote(nkv.value);
            }
            assertions.append(self.alloc, a) catch {};
        }
    }

    fn parseOperator(s: []const u8) oc.AssertionOperator {
        if (std.mem.eql(u8, s, "neq")) return .neq;
        if (std.mem.eql(u8, s, "contains")) return .contains;
        if (std.mem.eql(u8, s, "not_contains")) return .not_contains;
        if (std.mem.eql(u8, s, "gt")) return .gt;
        if (std.mem.eql(u8, s, "lt")) return .lt;
        if (std.mem.eql(u8, s, "gte")) return .gte;
        if (std.mem.eql(u8, s, "lte")) return .lte;
        if (std.mem.eql(u8, s, "matches")) return .matches;
        if (std.mem.eql(u8, s, "exists")) return .exists;
        if (std.mem.eql(u8, s, "isNull")) return .is_null;
        if (std.mem.eql(u8, s, "isString")) return .is_string;
        if (std.mem.eql(u8, s, "isNumber")) return .is_number;
        if (std.mem.eql(u8, s, "isBoolean")) return .is_boolean;
        if (std.mem.eql(u8, s, "isJson")) return .is_json;
        return .eq;
    }

    fn parseVars(self: *YamlParser, vars: *std.ArrayListUnmanaged(oc.Var)) void {
        while (self.peek()) |line| {
            if (line.indent < 4) break;
            if (!std.mem.startsWith(u8, line.content, "- ")) {
                _ = self.advance();
                continue;
            }
            _ = self.advance();
            var v = oc.Var{ .name = "", .value = "" };
            const first_kv = parseKeyValue(line.content);
            if (first_kv) |fkv| {
                if (std.mem.eql(u8, fkv.key, "name")) v.name = unquote(fkv.value);
            }
            while (self.peek()) |next| {
                if (next.indent < 6) break;
                _ = self.advance();
                const nkv = parseKeyValue(next.content) orelse continue;
                if (std.mem.eql(u8, nkv.key, "name")) v.name = unquote(nkv.value);
                if (std.mem.eql(u8, nkv.key, "value")) v.value = unquote(nkv.value);
                if (std.mem.eql(u8, nkv.key, "type")) {
                    if (std.mem.eql(u8, nkv.value, "after_response")) v.var_type = .after_response;
                }
                if (std.mem.eql(u8, nkv.key, "enabled")) v.enabled = std.mem.eql(u8, nkv.value, "true");
            }
            vars.append(self.alloc, v) catch {};
        }
    }

    fn parseDocs(self: *YamlParser) YamlParseError!oc.Docs {
        var description: ?[]const u8 = null;
        var content: ?[]const u8 = null;

        while (self.peek()) |line| {
            if (line.indent < 2) break;
            _ = self.advance();
            const kv = parseKeyValue(line.content) orelse continue;
            if (std.mem.eql(u8, kv.key, "description")) {
                if (std.mem.eql(u8, kv.value, "|")) {
                    description = self.readBlockScalar();
                } else {
                    description = unquote(kv.value);
                }
            }
            if (std.mem.eql(u8, kv.key, "content")) {
                if (std.mem.eql(u8, kv.value, "|")) {
                    content = self.readBlockScalar();
                } else {
                    content = unquote(kv.value);
                }
            }
        }

        return oc.Docs{ .description = description, .content = content };
    }
};

// ── Tests ──────────────────────────────────────────────────────────────

test "parse minimal YAML" {
    const yaml =
        \\info:
        \\  name: test
        \\  type: http
        \\http:
        \\  method: get
        \\  url: https://example.com
    ;
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    const req = try parse(arena.allocator(), yaml);
    try std.testing.expectEqualStrings("test", req.info.name);
    try std.testing.expectEqualStrings("get", req.http.method);
    try std.testing.expectEqualStrings("https://example.com", req.http.url);
}

test "parse YAML with headers" {
    const yaml =
        \\info:
        \\  name: test
        \\http:
        \\  method: post
        \\  url: https://example.com
        \\  headers:
        \\    - name: Accept
        \\      value: application/json
        \\    - name: X-Debug
        \\      value: true
        \\      enabled: false
    ;
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    const req = try parse(arena.allocator(), yaml);
    const headers = req.http.headers.?;
    try std.testing.expectEqual(@as(usize, 2), headers.len);
    try std.testing.expectEqualStrings("Accept", headers[0].name);
    try std.testing.expect(headers[0].enabled);
    try std.testing.expect(!headers[1].enabled);
}

test "parse YAML with auth" {
    const yaml =
        \\info:
        \\  name: test
        \\http:
        \\  method: get
        \\  url: https://example.com
        \\  auth:
        \\    type: bearer
        \\    token: my-token
    ;
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    const req = try parse(arena.allocator(), yaml);
    const auth = req.http.auth.?;
    switch (auth) {
        .bearer => |b| try std.testing.expectEqualStrings("my-token", b.token),
        else => return error.MissingRequiredField,
    }
}

test "parse missing info" {
    const yaml =
        \\http:
        \\  method: get
        \\  url: https://example.com
    ;
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    try std.testing.expectError(error.MissingRequiredField, parse(arena.allocator(), yaml));
}
