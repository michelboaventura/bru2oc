const std = @import("std");
const oc = @import("opencollection.zig");

pub const EmitOptions = struct {
    include_comments: bool = false,
    indent_size: usize = 2,
};

/// Emit an OpenCollectionEnvironment as YAML text.
/// Caller owns the returned slice.
pub fn emitEnvironment(allocator: std.mem.Allocator, env: oc.OpenCollectionEnvironment, options: EmitOptions) ![]const u8 {
    _ = options;
    var buf: std.ArrayListUnmanaged(u8) = .empty;
    const writer = buf.writer(allocator);

    if (env.variables) |variables| {
        try writer.writeAll("variables:\n");
        for (variables) |v| {
            try writer.print("  - name: {s}\n", .{v.name});
            if (v.secret) {
                try writer.writeAll("    secret: true\n");
            } else {
                try emitYamlValue(writer, "    value", v.value);
            }
            if (!v.enabled) {
                try writer.writeAll("    enabled: false\n");
            }
        }
    }

    return buf.toOwnedSlice(allocator);
}

/// Emit an OpenCollectionFolder as YAML text.
/// Caller owns the returned slice.
pub fn emitFolder(allocator: std.mem.Allocator, folder: oc.OpenCollectionFolder, options: EmitOptions) ![]const u8 {
    var buf: std.ArrayListUnmanaged(u8) = .empty;
    const writer = buf.writer(allocator);

    try emitInfo(writer, folder.info);

    if (folder.headers) |headers| {
        try emitTopLevelHeaders(writer, headers);
    }

    if (folder.auth) |auth| {
        try emitTopLevelAuth(writer, auth);
    }

    if (folder.runtime) |runtime| {
        try emitRuntime(writer, runtime, options);
    }

    if (folder.docs) |docs| {
        try emitDocs(writer, docs);
    }

    return buf.toOwnedSlice(allocator);
}

/// Emit an OpenCollectionRequest as YAML text.
/// Caller owns the returned slice.
pub fn emit(allocator: std.mem.Allocator, req: oc.OpenCollectionRequest, options: EmitOptions) ![]const u8 {
    var buf: std.ArrayListUnmanaged(u8) = .empty;
    const writer = buf.writer(allocator);

    try emitInfo(writer, req.info);
    try emitHttp(writer, req.http, options);

    if (req.settings) |settings| {
        try emitSettings(writer, settings);
    }

    if (req.runtime) |runtime| {
        try emitRuntime(writer, runtime, options);
    }

    if (req.docs) |docs| {
        try emitDocs(writer, docs);
    }

    return buf.toOwnedSlice(allocator);
}

// ── Info Section (Task 25) ──────────────────────────────────────────────

fn emitInfo(writer: anytype, info: oc.Info) !void {
    try writer.writeAll("info:\n");
    try writer.print("  name: {s}\n", .{info.name});
    try writer.print("  type: {s}\n", .{info.type});
    if (info.seq) |seq| {
        try writer.print("  seq: {d}\n", .{seq});
    }
    if (info.tags) |tags| {
        try writer.writeAll("  tags:\n");
        for (tags) |tag| {
            try writer.print("    - {s}\n", .{tag});
        }
    }
}

// ── HTTP Section (Task 26) ──────────────────────────────────────────────

fn emitHttp(writer: anytype, http: oc.Http, options: EmitOptions) !void {
    try writer.writeAll("http:\n");
    try writer.print("  method: {s}\n", .{http.method});
    try emitYamlValue(writer, "  url", http.url);

    if (http.headers) |headers| {
        try emitHeaders(writer, headers);
    }
    if (http.params) |params| {
        try emitParams(writer, params);
    }
    if (http.body) |body| {
        try emitBody(writer, body, options);
    }
    if (http.auth) |auth| {
        try emitAuth(writer, auth);
    }
}

// ── Headers (Task 27) ───────────────────────────────────────────────────

fn emitHeaders(writer: anytype, headers: []const oc.Header) !void {
    try writer.writeAll("  headers:\n");
    for (headers) |h| {
        try writer.print("    - name: {s}\n", .{h.name});
        try emitYamlValue(writer, "      value", h.value);
        if (!h.enabled) {
            try writer.writeAll("      enabled: false\n");
        }
    }
}

// ── Top-level Headers (for folder.bru) ──────────────────────────────────

fn emitTopLevelHeaders(writer: anytype, headers: []const oc.Header) !void {
    try writer.writeAll("headers:\n");
    for (headers) |h| {
        try writer.print("  - name: {s}\n", .{h.name});
        try emitYamlValue(writer, "    value", h.value);
        if (!h.enabled) {
            try writer.writeAll("    enabled: false\n");
        }
    }
}

// ── Params (Task 27) ────────────────────────────────────────────────────

fn emitParams(writer: anytype, params: []const oc.Param) !void {
    try writer.writeAll("  params:\n");
    for (params) |p| {
        try writer.print("    - name: {s}\n", .{p.name});
        try emitYamlValue(writer, "      value", p.value);
        try writer.print("      type: {s}\n", .{@tagName(p.param_type)});
        if (!p.enabled) {
            try writer.writeAll("      enabled: false\n");
        }
    }
}

// ── Body (Task 28) ──────────────────────────────────────────────────────

fn emitBody(writer: anytype, body: oc.Body, options: EmitOptions) !void {
    _ = options;
    try writer.writeAll("  body:\n");
    switch (body) {
        .json => |data| {
            try writer.writeAll("    type: json\n");
            try emitMultilineData(writer, "    data", data);
        },
        .xml => |data| {
            try writer.writeAll("    type: xml\n");
            try emitMultilineData(writer, "    data", data);
        },
        .text => |data| {
            try writer.writeAll("    type: text\n");
            try emitMultilineData(writer, "    data", data);
        },
        .sparql => |data| {
            try writer.writeAll("    type: sparql\n");
            try emitMultilineData(writer, "    data", data);
        },
        .graphql => |gql| {
            try writer.writeAll("    type: graphql\n");
            try emitMultilineData(writer, "    query", gql.query);
            if (gql.variables) |vars| {
                try emitMultilineData(writer, "    variables", vars);
            }
            if (gql.operation_name) |op| {
                try writer.print("    operationName: {s}\n", .{op});
            }
        },
        .form_urlencoded => |fields| {
            try writer.writeAll("    type: form-urlencoded\n");
            try writer.writeAll("    fields:\n");
            for (fields) |f| {
                try writer.print("      - name: {s}\n", .{f.name});
                try emitYamlValue(writer, "        value", f.value);
                if (!f.enabled) {
                    try writer.writeAll("        enabled: false\n");
                }
            }
        },
        .multipart_form => |parts| {
            try writer.writeAll("    type: multipart-form\n");
            try writer.writeAll("    parts:\n");
            for (parts) |p| {
                try writer.print("      - name: {s}\n", .{p.name});
                try emitYamlValue(writer, "        value", p.value);
                if (p.filename) |fname| {
                    try writer.print("        filename: {s}\n", .{fname});
                }
                if (p.content_type) |ct| {
                    try writer.print("        contentType: {s}\n", .{ct});
                }
                if (!p.enabled) {
                    try writer.writeAll("        enabled: false\n");
                }
            }
        },
    }
}

// ── Auth (Task 29) ──────────────────────────────────────────────────────

fn emitAuth(writer: anytype, auth: oc.Auth) !void {
    try writer.writeAll("  auth:\n");
    switch (auth) {
        .bearer => |b| {
            try writer.writeAll("    type: bearer\n");
            try emitYamlValue(writer, "    token", b.token);
            if (b.prefix) |p| {
                try writer.print("    prefix: {s}\n", .{p});
            }
        },
        .basic => |b| {
            try writer.writeAll("    type: basic\n");
            try emitYamlValue(writer, "    username", b.username);
            try emitYamlValue(writer, "    password", b.password);
        },
        .oauth2 => |o| {
            try writer.writeAll("    type: oauth2\n");
            try emitYamlValue(writer, "    accessToken", o.access_token);
            if (o.token_type) |tt| {
                try writer.print("    tokenType: {s}\n", .{tt});
            }
            if (o.refresh_token) |rt| {
                try emitYamlValue(writer, "    refreshToken", rt);
            }
        },
        .aws_v4 => |a| {
            try writer.writeAll("    type: awsv4\n");
            try emitYamlValue(writer, "    accessKeyId", a.access_key);
            try emitYamlValue(writer, "    secretAccessKey", a.secret_key);
            try writer.print("    region: {s}\n", .{a.region});
            try writer.print("    service: {s}\n", .{a.service});
            if (a.session_token) |st| {
                try emitYamlValue(writer, "    sessionToken", st);
            }
        },
        .digest => |d| {
            try writer.writeAll("    type: digest\n");
            try emitYamlValue(writer, "    username", d.username);
            try emitYamlValue(writer, "    password", d.password);
            if (d.realm) |r| {
                try writer.print("    realm: {s}\n", .{r});
            }
        },
        .api_key => |a| {
            try writer.writeAll("    type: apikey\n");
            try emitYamlValue(writer, "    key", a.key);
            try emitYamlValue(writer, "    value", a.value);
            try writer.print("    placement: {s}\n", .{a.placement});
        },
        .inherit => {
            try writer.writeAll("    type: inherit\n");
        },
        .none => {
            try writer.writeAll("    type: none\n");
        },
    }
}

// ── Top-level Auth (for folder.bru) ──────────────────────────────────────

fn emitTopLevelAuth(writer: anytype, auth: oc.Auth) !void {
    try writer.writeAll("auth:\n");
    switch (auth) {
        .bearer => |b| {
            try writer.writeAll("  type: bearer\n");
            try emitYamlValue(writer, "  token", b.token);
            if (b.prefix) |p| {
                try writer.print("  prefix: {s}\n", .{p});
            }
        },
        .basic => |b| {
            try writer.writeAll("  type: basic\n");
            try emitYamlValue(writer, "  username", b.username);
            try emitYamlValue(writer, "  password", b.password);
        },
        .oauth2 => |o| {
            try writer.writeAll("  type: oauth2\n");
            try emitYamlValue(writer, "  accessToken", o.access_token);
            if (o.token_type) |tt| {
                try writer.print("  tokenType: {s}\n", .{tt});
            }
            if (o.refresh_token) |rt| {
                try emitYamlValue(writer, "  refreshToken", rt);
            }
        },
        .aws_v4 => |a| {
            try writer.writeAll("  type: awsv4\n");
            try emitYamlValue(writer, "  accessKeyId", a.access_key);
            try emitYamlValue(writer, "  secretAccessKey", a.secret_key);
            try writer.print("  region: {s}\n", .{a.region});
            try writer.print("  service: {s}\n", .{a.service});
            if (a.session_token) |st| {
                try emitYamlValue(writer, "  sessionToken", st);
            }
        },
        .digest => |d| {
            try writer.writeAll("  type: digest\n");
            try emitYamlValue(writer, "  username", d.username);
            try emitYamlValue(writer, "  password", d.password);
            if (d.realm) |r| {
                try writer.print("  realm: {s}\n", .{r});
            }
        },
        .api_key => |a| {
            try writer.writeAll("  type: apikey\n");
            try emitYamlValue(writer, "  key", a.key);
            try emitYamlValue(writer, "  value", a.value);
            try writer.print("  placement: {s}\n", .{a.placement});
        },
        .inherit => {
            try writer.writeAll("  type: inherit\n");
        },
        .none => {
            try writer.writeAll("  type: none\n");
        },
    }
}

// ── Settings Section ────────────────────────────────────────────────────

fn emitSettings(writer: anytype, settings: oc.Settings) !void {
    try writer.writeAll("settings:\n");
    if (settings.encode_url) |v| {
        try writer.print("  encodeUrl: {s}\n", .{if (v) "true" else "false"});
    }
    if (settings.timeout) |t| {
        try writer.print("  timeout: {d}\n", .{t});
    }
    if (settings.follow_redirects) |v| {
        try writer.print("  followRedirects: {s}\n", .{if (v) "true" else "false"});
    }
}

// ── Runtime Section (Task 30) ────────────────────────────────────────────

fn emitRuntime(writer: anytype, runtime: oc.Runtime, options: EmitOptions) !void {
    _ = options;
    try writer.writeAll("runtime:\n");

    if (runtime.scripts) |scripts| {
        try writer.writeAll("  scripts:\n");
        for (scripts) |s| {
            try writer.print("    - type: {s}\n", .{@tagName(s.script_type)});
            try emitMultilineData(writer, "      code", s.code);
            if (!s.enabled) {
                try writer.writeAll("      enabled: false\n");
            }
        }
    }

    if (runtime.assertions) |assertions| {
        try writer.writeAll("  assertions:\n");
        for (assertions) |a| {
            try writer.print("    - expression: {s}\n", .{a.expression});
            try writer.print("      operator: {s}\n", .{@tagName(a.operator)});
            try emitYamlValue(writer, "      value", a.value);
            if (!a.enabled) {
                try writer.writeAll("      enabled: false\n");
            }
        }
    }

    if (runtime.vars) |vars| {
        try writer.writeAll("  vars:\n");
        for (vars) |v| {
            try writer.print("    - name: {s}\n", .{v.name});
            try emitYamlValue(writer, "      value", v.value);
            try writer.print("      type: {s}\n", .{@tagName(v.var_type)});
            if (!v.enabled) {
                try writer.writeAll("      enabled: false\n");
            }
        }
    }
}

// ── Docs (Task 31) ──────────────────────────────────────────────────────

fn emitDocs(writer: anytype, docs: oc.Docs) !void {
    try writer.writeAll("docs:\n");
    if (docs.description) |desc| {
        try emitMultilineData(writer, "  description", desc);
    }
    if (docs.content) |content| {
        try emitMultilineData(writer, "  content", content);
    }
}

// ── Helpers ─────────────────────────────────────────────────────────────

/// Emit a YAML value, quoting if it contains special characters.
fn emitYamlValue(writer: anytype, key: []const u8, value: []const u8) !void {
    if (needsQuoting(value)) {
        try writer.print("{s}: \"{s}\"\n", .{ key, value });
    } else {
        try writer.print("{s}: {s}\n", .{ key, value });
    }
}

/// Emit multiline data using YAML literal block scalar (|).
fn emitMultilineData(writer: anytype, key: []const u8, data: []const u8) !void {
    if (std.mem.indexOf(u8, data, "\n") != null) {
        try writer.print("{s}: |\n", .{key});
        var iter = std.mem.splitScalar(u8, data, '\n');
        while (iter.next()) |line| {
            if (line.len == 0) {
                try writer.writeAll("\n");
            } else {
                // Add extra indent (key indent + 2)
                const key_indent = countLeadingSpaces(key);
                var i: usize = 0;
                while (i < key_indent + 2) : (i += 1) {
                    try writer.writeByte(' ');
                }
                try writer.print("{s}\n", .{line});
            }
        }
    } else {
        try emitYamlValue(writer, key, data);
    }
}

fn countLeadingSpaces(s: []const u8) usize {
    var count: usize = 0;
    for (s) |c| {
        if (c == ' ') {
            count += 1;
        } else {
            break;
        }
    }
    return count;
}

/// Check if a YAML value string needs quoting.
fn needsQuoting(s: []const u8) bool {
    if (s.len == 0) return true;
    // Quote if contains special YAML characters
    for (s) |c| {
        if (c == ':' or c == '#' or c == '[' or c == ']' or
            c == '{' or c == '}' or c == ',' or c == '&' or
            c == '*' or c == '!' or c == '|' or c == '>' or
            c == '\'' or c == '"' or c == '%' or c == '@' or c == '`')
        {
            return true;
        }
    }
    // Quote if looks like a boolean or null
    if (std.mem.eql(u8, s, "true") or std.mem.eql(u8, s, "false") or
        std.mem.eql(u8, s, "null") or std.mem.eql(u8, s, "yes") or
        std.mem.eql(u8, s, "no") or std.mem.eql(u8, s, "on") or
        std.mem.eql(u8, s, "off"))
    {
        return true;
    }
    // Quote if starts with special chars
    if (s[0] == ' ' or s[0] == '-' or s[0] == '?' or s[0] == '\t') {
        return true;
    }
    return false;
}

// ── Tests ──────────────────────────────────────────────────────────────

test "emit simple request" {
    const allocator = std.testing.allocator;

    const req = oc.OpenCollectionRequest{
        .info = .{ .name = "test-request" },
        .http = .{ .method = "GET", .url = "https://example.com/api" },
    };

    const yaml = try emit(allocator, req, .{});
    defer allocator.free(yaml);

    try std.testing.expect(std.mem.indexOf(u8, yaml, "info:") != null);
    try std.testing.expect(std.mem.indexOf(u8, yaml, "name: test-request") != null);
    try std.testing.expect(std.mem.indexOf(u8, yaml, "method: GET") != null);
    // URL contains ':' so it will be quoted
    try std.testing.expect(std.mem.indexOf(u8, yaml, "https://example.com/api") != null);
}

test "emit headers" {
    const allocator = std.testing.allocator;

    const headers = [_]oc.Header{
        .{ .name = "Content-Type", .value = "application/json" },
        .{ .name = "X-Debug", .value = "true", .enabled = false },
    };

    const req = oc.OpenCollectionRequest{
        .info = .{ .name = "test" },
        .http = .{
            .method = "POST",
            .url = "https://example.com",
            .headers = &headers,
        },
    };

    const yaml = try emit(allocator, req, .{});
    defer allocator.free(yaml);

    try std.testing.expect(std.mem.indexOf(u8, yaml, "headers:") != null);
    try std.testing.expect(std.mem.indexOf(u8, yaml, "name: Content-Type") != null);
    try std.testing.expect(std.mem.indexOf(u8, yaml, "enabled: false") != null);
}

test "emit body json" {
    const allocator = std.testing.allocator;

    const req = oc.OpenCollectionRequest{
        .info = .{ .name = "test" },
        .http = .{
            .method = "POST",
            .url = "https://example.com",
            .body = oc.Body{ .json = "{\n  \"key\": \"value\"\n}" },
        },
    };

    const yaml = try emit(allocator, req, .{});
    defer allocator.free(yaml);

    try std.testing.expect(std.mem.indexOf(u8, yaml, "body:") != null);
    try std.testing.expect(std.mem.indexOf(u8, yaml, "type: json") != null);
    try std.testing.expect(std.mem.indexOf(u8, yaml, "data: |") != null);
}

test "emit auth bearer" {
    const allocator = std.testing.allocator;

    const req = oc.OpenCollectionRequest{
        .info = .{ .name = "test" },
        .http = .{
            .method = "GET",
            .url = "https://example.com",
            .auth = oc.Auth{ .bearer = .{ .token = "my-token" } },
        },
    };

    const yaml = try emit(allocator, req, .{});
    defer allocator.free(yaml);

    try std.testing.expect(std.mem.indexOf(u8, yaml, "auth:") != null);
    try std.testing.expect(std.mem.indexOf(u8, yaml, "type: bearer") != null);
    try std.testing.expect(std.mem.indexOf(u8, yaml, "token: my-token") != null);
}

test "emit runtime with scripts" {
    const allocator = std.testing.allocator;

    const scripts = [_]oc.Script{
        .{ .script_type = .before_request, .code = "console.log('pre');" },
    };

    const req = oc.OpenCollectionRequest{
        .info = .{ .name = "test" },
        .http = .{ .method = "GET", .url = "https://example.com" },
        .runtime = oc.Runtime{ .scripts = &scripts },
    };

    const yaml = try emit(allocator, req, .{});
    defer allocator.free(yaml);

    try std.testing.expect(std.mem.indexOf(u8, yaml, "runtime:") != null);
    try std.testing.expect(std.mem.indexOf(u8, yaml, "scripts:") != null);
    try std.testing.expect(std.mem.indexOf(u8, yaml, "type: before_request") != null);
}

test "emit docs" {
    const allocator = std.testing.allocator;

    const req = oc.OpenCollectionRequest{
        .info = .{ .name = "test" },
        .http = .{ .method = "GET", .url = "https://example.com" },
        .docs = oc.Docs{ .content = "This is a test endpoint." },
    };

    const yaml = try emit(allocator, req, .{});
    defer allocator.free(yaml);

    try std.testing.expect(std.mem.indexOf(u8, yaml, "docs:") != null);
    try std.testing.expect(std.mem.indexOf(u8, yaml, "This is a test endpoint") != null);
}

test "needsQuoting" {
    try std.testing.expect(needsQuoting(""));
    try std.testing.expect(needsQuoting("https://example.com"));
    try std.testing.expect(needsQuoting("true"));
    try std.testing.expect(needsQuoting("null"));
    try std.testing.expect(!needsQuoting("simple-value"));
    try std.testing.expect(!needsQuoting("hello"));
    try std.testing.expect(needsQuoting("value with: colon"));
}

test "emit params" {
    const allocator = std.testing.allocator;

    const params = [_]oc.Param{
        .{ .name = "page", .value = "1", .param_type = .query },
        .{ .name = "id", .value = "123", .param_type = .path },
    };

    const req = oc.OpenCollectionRequest{
        .info = .{ .name = "test" },
        .http = .{
            .method = "GET",
            .url = "https://example.com",
            .params = &params,
        },
    };

    const yaml = try emit(allocator, req, .{});
    defer allocator.free(yaml);

    try std.testing.expect(std.mem.indexOf(u8, yaml, "params:") != null);
    try std.testing.expect(std.mem.indexOf(u8, yaml, "type: query") != null);
    try std.testing.expect(std.mem.indexOf(u8, yaml, "type: path") != null);
}
