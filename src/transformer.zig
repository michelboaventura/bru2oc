const std = @import("std");
const ir = @import("ir.zig");
const oc = @import("opencollection.zig");
const errors = @import("errors.zig");

const Value = ir.Value;
const Entry = ir.Entry;
const BruDocument = ir.BruDocument;

/// Transform a parsed BruDocument into an OpenCollectionRequest.
pub fn transform(arena: std.mem.Allocator, doc: BruDocument) errors.TransformError!oc.OpenCollectionRequest {
    const info = try transformMeta(arena, doc);
    const http_method = extractMethod(doc);
    const url = extractUrl(doc);

    if (http_method == null) return error.MissingRequiredField;

    var result = oc.OpenCollectionRequest{
        .info = info,
        .http = .{
            .method = http_method.?,
            .url = url orelse "",
            .headers = try transformHeaders(arena, doc),
            .params = try transformParams(arena, doc),
            .body = transformBody(doc),
            .auth = try transformAuth(arena, doc),
        },
    };

    result.runtime = try transformRuntime(arena, doc);
    result.docs = transformDocs(doc);

    return result;
}

// ── Meta (Task 12) ──────────────────────────────────────────────────────

fn transformMeta(arena: std.mem.Allocator, doc: BruDocument) errors.TransformError!oc.Info {
    _ = arena;
    const meta = doc.getFirst("meta");
    if (meta == null) {
        return oc.Info{ .name = "untitled" };
    }

    var info = oc.Info{ .name = "untitled" };
    switch (meta.?.value) {
        .multimap => |entries| {
            for (entries) |entry| {
                if (std.mem.eql(u8, entry.key, "name")) {
                    info.name = entry.value.asString() orelse "untitled";
                } else if (std.mem.eql(u8, entry.key, "type")) {
                    info.@"type" = entry.value.asString() orelse "http";
                } else if (std.mem.eql(u8, entry.key, "seq")) {
                    if (entry.value.asString()) |s| {
                        info.seq = std.fmt.parseInt(usize, s, 10) catch null;
                    }
                }
            }
        },
        else => {},
    }

    return info;
}

// ── HTTP Method & URL (Task 13) ─────────────────────────────────────────

const http_methods = [_][]const u8{
    "get", "post", "put", "delete", "patch", "head", "options", "trace", "connect",
};

fn extractMethod(doc: BruDocument) ?[]const u8 {
    for (&http_methods) |method| {
        if (doc.getFirst(method) != null) return method;
    }
    return null;
}

fn extractUrl(doc: BruDocument) ?[]const u8 {
    for (&http_methods) |method| {
        const block = doc.getFirst(method);
        if (block != null) {
            switch (block.?.value) {
                .multimap => |entries| {
                    for (entries) |entry| {
                        if (std.mem.eql(u8, entry.key, "url")) {
                            return entry.value.asString();
                        }
                    }
                },
                else => {},
            }
        }
    }
    return null;
}

// ── Headers (Task 14) ───────────────────────────────────────────────────

fn transformHeaders(arena: std.mem.Allocator, doc: BruDocument) errors.TransformError!?[]const oc.Header {
    const block = doc.getFirst("headers");
    if (block == null) return null;

    switch (block.?.value) {
        .multimap => |entries| {
            var headers: std.ArrayListUnmanaged(oc.Header) = .empty;
            for (entries) |entry| {
                headers.append(arena, oc.Header{
                    .name = entry.key,
                    .value = entry.value.asString() orelse "",
                    .enabled = !entry.disabled,
                }) catch return error.MissingRequiredField;
            }
            return headers.toOwnedSlice(arena) catch return error.MissingRequiredField;
        },
        else => return null,
    }
}

// ── Query & Path Params (Task 15) ───────────────────────────────────────

fn transformParams(arena: std.mem.Allocator, doc: BruDocument) errors.TransformError!?[]const oc.Param {
    var params: std.ArrayListUnmanaged(oc.Param) = .empty;

    // Query params
    if (doc.getFirst("params:query")) |block| {
        switch (block.value) {
            .multimap => |entries| {
                for (entries) |entry| {
                    params.append(arena, oc.Param{
                        .name = entry.key,
                        .value = entry.value.asString() orelse "",
                        .param_type = .query,
                        .enabled = !entry.disabled,
                    }) catch return error.MissingRequiredField;
                }
            },
            else => {},
        }
    }

    // Path params
    if (doc.getFirst("params:path")) |block| {
        switch (block.value) {
            .multimap => |entries| {
                for (entries) |entry| {
                    params.append(arena, oc.Param{
                        .name = entry.key,
                        .value = entry.value.asString() orelse "",
                        .param_type = .path,
                        .enabled = !entry.disabled,
                    }) catch return error.MissingRequiredField;
                }
            },
            else => {},
        }
    }

    if (params.items.len == 0) return null;
    return params.toOwnedSlice(arena) catch return error.MissingRequiredField;
}

// ── Request Body (Task 16) ──────────────────────────────────────────────

fn transformBody(doc: BruDocument) ?oc.Body {
    if (doc.getFirst("body:json")) |block| {
        if (block.value.asString()) |s| return oc.Body{ .json = s };
    }
    if (doc.getFirst("body:xml")) |block| {
        if (block.value.asString()) |s| return oc.Body{ .xml = s };
    }
    if (doc.getFirst("body:text")) |block| {
        if (block.value.asString()) |s| return oc.Body{ .text = s };
    }
    if (doc.getFirst("body:graphql")) |block| {
        if (block.value.asString()) |query| {
            var gql = oc.GraphQL{ .query = query };
            if (doc.getFirst("body:graphql:vars")) |vars_block| {
                gql.variables = vars_block.value.asString();
            }
            return oc.Body{ .graphql = gql };
        }
    }
    if (doc.getFirst("body:sparql")) |block| {
        if (block.value.asString()) |s| return oc.Body{ .sparql = s };
    }
    // form-urlencoded and multipart-form are handled via multimap entries
    // but need arena allocation — skip for now if no multistring content
    if (doc.getFirst("body:form-urlencoded")) |block| {
        if (block.value.asString()) |s| return oc.Body{ .text = s };
    }
    if (doc.getFirst("body:multipart-form")) |block| {
        if (block.value.asString()) |s| return oc.Body{ .text = s };
    }
    return null;
}

// ── Authentication (Task 17) ────────────────────────────────────────────

fn transformAuth(arena: std.mem.Allocator, doc: BruDocument) errors.TransformError!?oc.Auth {
    _ = arena;
    if (doc.getFirst("auth:bearer")) |block| {
        switch (block.value) {
            .multimap => |entries| {
                var token: []const u8 = "";
                var prefix: ?[]const u8 = null;
                for (entries) |entry| {
                    if (std.mem.eql(u8, entry.key, "token")) {
                        token = entry.value.asString() orelse "";
                    } else if (std.mem.eql(u8, entry.key, "prefix")) {
                        prefix = entry.value.asString();
                    }
                }
                return oc.Auth{ .bearer = .{ .token = token, .prefix = prefix } };
            },
            else => {},
        }
    }

    if (doc.getFirst("auth:basic")) |block| {
        switch (block.value) {
            .multimap => |entries| {
                var username: []const u8 = "";
                var password: []const u8 = "";
                for (entries) |entry| {
                    if (std.mem.eql(u8, entry.key, "username")) {
                        username = entry.value.asString() orelse "";
                    } else if (std.mem.eql(u8, entry.key, "password")) {
                        password = entry.value.asString() orelse "";
                    }
                }
                return oc.Auth{ .basic = .{ .username = username, .password = password } };
            },
            else => {},
        }
    }

    if (doc.getFirst("auth:oauth2")) |block| {
        switch (block.value) {
            .multimap => |entries| {
                var access_token: []const u8 = "";
                var token_type: ?[]const u8 = null;
                var refresh_token: ?[]const u8 = null;
                for (entries) |entry| {
                    if (std.mem.eql(u8, entry.key, "access_token")) {
                        access_token = entry.value.asString() orelse "";
                    } else if (std.mem.eql(u8, entry.key, "token_type")) {
                        token_type = entry.value.asString();
                    } else if (std.mem.eql(u8, entry.key, "refresh_token")) {
                        refresh_token = entry.value.asString();
                    }
                }
                return oc.Auth{ .oauth2 = .{
                    .access_token = access_token,
                    .token_type = token_type,
                    .refresh_token = refresh_token,
                } };
            },
            else => {},
        }
    }

    if (doc.getFirst("auth:awsv4")) |block| {
        switch (block.value) {
            .multimap => |entries| {
                var access_key: []const u8 = "";
                var secret_key: []const u8 = "";
                var region: []const u8 = "";
                var service: []const u8 = "";
                var session_token: ?[]const u8 = null;
                for (entries) |entry| {
                    if (std.mem.eql(u8, entry.key, "accessKeyId")) {
                        access_key = entry.value.asString() orelse "";
                    } else if (std.mem.eql(u8, entry.key, "secretAccessKey")) {
                        secret_key = entry.value.asString() orelse "";
                    } else if (std.mem.eql(u8, entry.key, "region")) {
                        region = entry.value.asString() orelse "";
                    } else if (std.mem.eql(u8, entry.key, "service")) {
                        service = entry.value.asString() orelse "";
                    } else if (std.mem.eql(u8, entry.key, "sessionToken")) {
                        session_token = entry.value.asString();
                    }
                }
                return oc.Auth{ .aws_v4 = .{
                    .access_key = access_key,
                    .secret_key = secret_key,
                    .region = region,
                    .service = service,
                    .session_token = session_token,
                } };
            },
            else => {},
        }
    }

    if (doc.getFirst("auth:digest")) |block| {
        switch (block.value) {
            .multimap => |entries| {
                var username: []const u8 = "";
                var password: []const u8 = "";
                for (entries) |entry| {
                    if (std.mem.eql(u8, entry.key, "username")) {
                        username = entry.value.asString() orelse "";
                    } else if (std.mem.eql(u8, entry.key, "password")) {
                        password = entry.value.asString() orelse "";
                    }
                }
                return oc.Auth{ .digest = .{ .username = username, .password = password } };
            },
            else => {},
        }
    }

    return null;
}

// ── Scripts & Tests (Task 18) ───────────────────────────────────────────

fn transformScripts(doc: BruDocument) struct { pre: ?[]const u8, post: ?[]const u8, tests_code: ?[]const u8 } {
    var pre: ?[]const u8 = null;
    var post: ?[]const u8 = null;
    var tests_code: ?[]const u8 = null;

    if (doc.getFirst("script:pre-request")) |block| {
        pre = block.value.asString();
    }
    if (doc.getFirst("script:post-response")) |block| {
        post = block.value.asString();
    }
    if (doc.getFirst("tests")) |block| {
        tests_code = block.value.asString();
    }

    return .{ .pre = pre, .post = post, .tests_code = tests_code };
}

// ── Assertions (Task 19) ────────────────────────────────────────────────

fn transformAssertions(arena: std.mem.Allocator, doc: BruDocument) errors.TransformError!?[]const oc.Assertion {
    const block = doc.getFirst("assert");
    if (block == null) return null;

    switch (block.?.value) {
        .multimap => |entries| {
            var assertions: std.ArrayListUnmanaged(oc.Assertion) = .empty;
            for (entries) |entry| {
                const val_str = entry.value.asString() orelse "";
                // Parse "operator value" format, e.g. "eq 200"
                const parsed = parseAssertionValue(val_str);
                assertions.append(arena, oc.Assertion{
                    .expression = entry.key,
                    .operator = parsed.operator,
                    .value = parsed.value,
                    .enabled = !entry.disabled,
                }) catch return error.MissingRequiredField;
            }
            if (assertions.items.len == 0) return null;
            return assertions.toOwnedSlice(arena) catch return error.MissingRequiredField;
        },
        else => return null,
    }
}

fn parseAssertionValue(s: []const u8) struct { operator: oc.AssertionOperator, value: []const u8 } {
    // Try to find operator at beginning of string
    const ops = [_]struct { name: []const u8, op: oc.AssertionOperator }{
        .{ .name = "neq", .op = .neq },
        .{ .name = "eq", .op = .eq },
        .{ .name = "contains", .op = .contains },
        .{ .name = "notContains", .op = .not_contains },
        .{ .name = "gt", .op = .gt },
        .{ .name = "gte", .op = .gte },
        .{ .name = "lt", .op = .lt },
        .{ .name = "lte", .op = .lte },
        .{ .name = "matches", .op = .matches },
        .{ .name = "exists", .op = .exists },
        .{ .name = "isNull", .op = .is_null },
        .{ .name = "isString", .op = .is_string },
        .{ .name = "isNumber", .op = .is_number },
        .{ .name = "isBoolean", .op = .is_boolean },
        .{ .name = "isJson", .op = .is_json },
    };

    for (&ops) |op_def| {
        if (std.mem.startsWith(u8, s, op_def.name)) {
            const rest = s[op_def.name.len..];
            const trimmed = std.mem.trimLeft(u8, rest, " ");
            return .{ .operator = op_def.op, .value = trimmed };
        }
    }

    return .{ .operator = .eq, .value = s };
}

// ── Runtime Variables (Task 20) ──────────────────────────────────────────

fn transformVars(arena: std.mem.Allocator, doc: BruDocument) errors.TransformError!?[]const oc.Var {
    var vars: std.ArrayListUnmanaged(oc.Var) = .empty;

    if (doc.getFirst("vars:pre-request")) |block| {
        switch (block.value) {
            .multimap => |entries| {
                for (entries) |entry| {
                    vars.append(arena, oc.Var{
                        .name = entry.key,
                        .value = entry.value.asString() orelse "",
                        .var_type = .before_request,
                        .enabled = !entry.disabled,
                    }) catch return error.MissingRequiredField;
                }
            },
            else => {},
        }
    }

    if (doc.getFirst("vars:post-response")) |block| {
        switch (block.value) {
            .multimap => |entries| {
                for (entries) |entry| {
                    vars.append(arena, oc.Var{
                        .name = entry.key,
                        .value = entry.value.asString() orelse "",
                        .var_type = .after_response,
                        .enabled = !entry.disabled,
                    }) catch return error.MissingRequiredField;
                }
            },
            else => {},
        }
    }

    if (vars.items.len == 0) return null;
    return vars.toOwnedSlice(arena) catch return error.MissingRequiredField;
}

// ── Docs (Task 21) ──────────────────────────────────────────────────────

fn transformDocs(doc: BruDocument) ?oc.Docs {
    const block = doc.getFirst("docs");
    if (block == null) return null;

    return oc.Docs{
        .content = block.?.value.asString(),
    };
}

// ── Runtime Assembly (Tasks 18-20, 22-23) ───────────────────────────────

fn transformRuntime(arena: std.mem.Allocator, doc: BruDocument) errors.TransformError!?oc.Runtime {
    const scripts_data = transformScripts(doc);
    const assertions = try transformAssertions(arena, doc);
    const vars = try transformVars(arena, doc);

    var scripts: std.ArrayListUnmanaged(oc.Script) = .empty;
    if (scripts_data.pre) |code| {
        scripts.append(arena, oc.Script{
            .script_type = .before_request,
            .code = code,
        }) catch return error.MissingRequiredField;
    }
    if (scripts_data.post) |code| {
        scripts.append(arena, oc.Script{
            .script_type = .after_response,
            .code = code,
        }) catch return error.MissingRequiredField;
    }
    if (scripts_data.tests_code) |code| {
        scripts.append(arena, oc.Script{
            .script_type = .tests,
            .code = code,
        }) catch return error.MissingRequiredField;
    }

    const has_scripts = scripts.items.len > 0;
    const has_assertions = assertions != null;
    const has_vars = vars != null;

    if (!has_scripts and !has_assertions and !has_vars) return null;

    return oc.Runtime{
        .scripts = if (has_scripts) scripts.toOwnedSlice(arena) catch return error.MissingRequiredField else null,
        .assertions = assertions,
        .vars = vars,
    };
}

// ── Tests ──────────────────────────────────────────────────────────────

const parser = @import("parser.zig");

fn parseAndTransform(alloc: std.mem.Allocator, source: []const u8) !oc.OpenCollectionRequest {
    const doc = try parser.parse(alloc, source);
    return try transform(alloc, doc);
}

test "transform meta block" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    const source =
        \\meta {
        \\  name: my-request
        \\  type: http
        \\  seq: 3
        \\}
        \\
        \\get {
        \\  url: https://example.com
        \\}
    ;

    const req = try parseAndTransform(alloc, source);
    try std.testing.expectEqualStrings("my-request", req.info.name);
    try std.testing.expectEqualStrings("http", req.info.@"type");
    try std.testing.expectEqual(@as(?usize, 3), req.info.seq);
}

test "transform HTTP method and URL" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    const source =
        \\meta {
        \\  name: test
        \\}
        \\
        \\post {
        \\  url: https://api.example.com/users
        \\}
    ;

    const req = try parseAndTransform(alloc, source);
    try std.testing.expectEqualStrings("post", req.http.method);
    try std.testing.expectEqualStrings("https://api.example.com/users", req.http.url);
}

test "transform headers" {
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
        \\  Content-Type: application/json
        \\  ~Authorization: Bearer token
        \\}
    ;

    const req = try parseAndTransform(alloc, source);
    const headers = req.http.headers.?;
    try std.testing.expectEqual(@as(usize, 2), headers.len);
    try std.testing.expectEqualStrings("Content-Type", headers[0].name);
    try std.testing.expect(headers[0].enabled);
    try std.testing.expectEqualStrings("Authorization", headers[1].name);
    try std.testing.expect(!headers[1].enabled);
}

test "transform auth bearer" {
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
        \\auth:bearer {
        \\  token: my-secret-token
        \\}
    ;

    const req = try parseAndTransform(alloc, source);
    const auth = req.http.auth.?;
    switch (auth) {
        .bearer => |b| try std.testing.expectEqualStrings("my-secret-token", b.token),
        else => return error.MissingRequiredField,
    }
}

test "transform body json" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    const source =
        \\meta {
        \\  name: test
        \\}
        \\
        \\post {
        \\  url: https://example.com
        \\}
        \\
        \\body:json {
        \\  {"key": "value"}
        \\}
    ;

    const req = try parseAndTransform(alloc, source);
    const body = req.http.body.?;
    switch (body) {
        .json => |data| try std.testing.expect(data.len > 0),
        else => return error.MissingRequiredField,
    }
}

test "transform scripts" {
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
        \\script:pre-request {
        \\  const token = "abc";
        \\}
    ;

    const req = try parseAndTransform(alloc, source);
    const runtime = req.runtime.?;
    const scripts = runtime.scripts.?;
    try std.testing.expectEqual(@as(usize, 1), scripts.len);
    try std.testing.expectEqual(oc.ScriptType.before_request, scripts[0].script_type);
}

test "transform assertions" {
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
        \\assert {
        \\  res.status: eq 200
        \\  res.body: contains success
        \\}
    ;

    const req = try parseAndTransform(alloc, source);
    const runtime = req.runtime.?;
    const assertions = runtime.assertions.?;
    try std.testing.expectEqual(@as(usize, 2), assertions.len);
    try std.testing.expectEqualStrings("res.status", assertions[0].expression);
    try std.testing.expectEqual(oc.AssertionOperator.eq, assertions[0].operator);
    try std.testing.expectEqualStrings("200", assertions[0].value);
}

test "transform docs" {
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
        \\docs {
        \\  This endpoint returns user data.
        \\}
    ;

    const req = try parseAndTransform(alloc, source);
    const docs = req.docs.?;
    try std.testing.expect(docs.content != null);
}

test "missing method returns error" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    const source =
        \\meta {
        \\  name: test
        \\}
    ;

    const doc = try parser.parse(alloc, source);
    try std.testing.expectError(error.MissingRequiredField, transform(alloc, doc));
}

test "parseAssertionValue" {
    const r1 = parseAssertionValue("eq 200");
    try std.testing.expectEqual(oc.AssertionOperator.eq, r1.operator);
    try std.testing.expectEqualStrings("200", r1.value);

    const r2 = parseAssertionValue("contains success");
    try std.testing.expectEqual(oc.AssertionOperator.contains, r2.operator);
    try std.testing.expectEqualStrings("success", r2.value);

    const r3 = parseAssertionValue("isNull");
    try std.testing.expectEqual(oc.AssertionOperator.is_null, r3.operator);
}
