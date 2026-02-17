const std = @import("std");
const oc = @import("opencollection.zig");

/// Emit Bru format text from an OpenCollectionRequest.
pub fn emit(allocator: std.mem.Allocator, req: oc.OpenCollectionRequest) ![]const u8 {
    var buf: std.ArrayListUnmanaged(u8) = .empty;
    const writer = buf.writer(allocator);

    // meta block
    try writer.writeAll("meta {\n");
    try writer.print("  name: {s}\n", .{req.info.name});
    if (!std.mem.eql(u8, req.info.type, "http")) {
        try writer.print("  type: {s}\n", .{req.info.type});
    } else {
        try writer.writeAll("  type: http\n");
    }
    if (req.info.seq) |seq| {
        try writer.print("  seq: {d}\n", .{seq});
    }
    try writer.writeAll("}\n");

    // method + url block
    try writer.print("\n{s} {{\n", .{req.http.method});
    try writer.print("  url: {s}\n", .{req.http.url});
    try writer.writeAll("}\n");

    // headers
    if (req.http.headers) |headers| {
        if (headers.len > 0) {
            try writer.writeAll("\nheaders {\n");
            for (headers) |h| {
                if (!h.enabled) {
                    try writer.print("  ~{s}: {s}\n", .{ h.name, h.value });
                } else {
                    try writer.print("  {s}: {s}\n", .{ h.name, h.value });
                }
            }
            try writer.writeAll("}\n");
        }
    }

    // params:query
    if (req.http.params) |params| {
        var has_query = false;
        var has_path = false;
        for (params) |p| {
            if (p.param_type == .query) has_query = true;
            if (p.param_type == .path) has_path = true;
        }
        if (has_query) {
            try writer.writeAll("\nparams:query {\n");
            for (params) |p| {
                if (p.param_type != .query) continue;
                if (!p.enabled) {
                    try writer.print("  ~{s}: {s}\n", .{ p.name, p.value });
                } else {
                    try writer.print("  {s}: {s}\n", .{ p.name, p.value });
                }
            }
            try writer.writeAll("}\n");
        }
        if (has_path) {
            try writer.writeAll("\nparams:path {\n");
            for (params) |p| {
                if (p.param_type != .path) continue;
                try writer.print("  {s}: {s}\n", .{ p.name, p.value });
            }
            try writer.writeAll("}\n");
        }
    }

    // body
    if (req.http.body) |body| {
        switch (body) {
            .json => |data| {
                try writer.writeAll("\nbody:json {\n");
                try emitIndentedContent(writer, data);
                try writer.writeAll("}\n");
            },
            .xml => |data| {
                try writer.writeAll("\nbody:xml {\n");
                try emitIndentedContent(writer, data);
                try writer.writeAll("}\n");
            },
            .text => |data| {
                try writer.writeAll("\nbody:text {\n");
                try emitIndentedContent(writer, data);
                try writer.writeAll("}\n");
            },
            .graphql => |gql| {
                try writer.writeAll("\nbody:graphql {\n");
                try emitIndentedContent(writer, gql.query);
                try writer.writeAll("}\n");
            },
            .sparql => |data| {
                try writer.writeAll("\nbody:sparql {\n");
                try emitIndentedContent(writer, data);
                try writer.writeAll("}\n");
            },
            .form_urlencoded => |fields| {
                try writer.writeAll("\nbody:form-urlencoded {\n");
                for (fields) |f| {
                    if (!f.enabled) {
                        try writer.print("  ~{s}: {s}\n", .{ f.name, f.value });
                    } else {
                        try writer.print("  {s}: {s}\n", .{ f.name, f.value });
                    }
                }
                try writer.writeAll("}\n");
            },
            .multipart_form => |parts| {
                try writer.writeAll("\nbody:multipart-form {\n");
                for (parts) |p| {
                    try writer.print("  {s}: {s}\n", .{ p.name, p.value });
                }
                try writer.writeAll("}\n");
            },
        }
    }

    // auth
    if (req.http.auth) |auth| {
        switch (auth) {
            .bearer => |b| {
                try writer.writeAll("\nauth:bearer {\n");
                try writer.print("  token: {s}\n", .{b.token});
                try writer.writeAll("}\n");
            },
            .basic => |b| {
                try writer.writeAll("\nauth:basic {\n");
                try writer.print("  username: {s}\n", .{b.username});
                try writer.print("  password: {s}\n", .{b.password});
                try writer.writeAll("}\n");
            },
            .oauth2 => |o| {
                try writer.writeAll("\nauth:oauth2 {\n");
                try writer.print("  access_token: {s}\n", .{o.access_token});
                try writer.writeAll("}\n");
            },
            .aws_v4 => |a| {
                try writer.writeAll("\nauth:awsv4 {\n");
                try writer.print("  access_key: {s}\n", .{a.access_key});
                try writer.print("  secret_key: {s}\n", .{a.secret_key});
                try writer.print("  region: {s}\n", .{a.region});
                try writer.print("  service: {s}\n", .{a.service});
                try writer.writeAll("}\n");
            },
            .digest => |d| {
                try writer.writeAll("\nauth:digest {\n");
                try writer.print("  username: {s}\n", .{d.username});
                try writer.print("  password: {s}\n", .{d.password});
                try writer.writeAll("}\n");
            },
            .api_key => |a| {
                try writer.writeAll("\nauth:api-key {\n");
                try writer.print("  key: {s}\n", .{a.key});
                try writer.print("  value: {s}\n", .{a.value});
                try writer.writeAll("}\n");
            },
            .none => {},
        }
    }

    // runtime: scripts
    if (req.runtime) |runtime| {
        if (runtime.scripts) |scripts| {
            for (scripts) |s| {
                const block_name: []const u8 = switch (s.script_type) {
                    .before_request => "script:pre-request",
                    .after_response => "script:post-response",
                    .tests => "tests",
                };
                try writer.print("\n{s} {{\n", .{block_name});
                try emitIndentedContent(writer, s.code);
                try writer.writeAll("}\n");
            }
        }

        // assertions
        if (runtime.assertions) |assertions| {
            if (assertions.len > 0) {
                try writer.writeAll("\nassert {\n");
                for (assertions) |a| {
                    const op = operatorToString(a.operator);
                    if (!a.enabled) {
                        try writer.print("  ~{s}: {s} {s}\n", .{ a.expression, op, a.value });
                    } else {
                        try writer.print("  {s}: {s} {s}\n", .{ a.expression, op, a.value });
                    }
                }
                try writer.writeAll("}\n");
            }
        }

        // vars
        if (runtime.vars) |vars| {
            var has_pre = false;
            var has_post = false;
            for (vars) |v| {
                if (v.var_type == .before_request) has_pre = true;
                if (v.var_type == .after_response) has_post = true;
            }
            if (has_pre) {
                try writer.writeAll("\nvars:pre-request {\n");
                for (vars) |v| {
                    if (v.var_type != .before_request) continue;
                    if (!v.enabled) {
                        try writer.print("  ~{s}: {s}\n", .{ v.name, v.value });
                    } else {
                        try writer.print("  {s}: {s}\n", .{ v.name, v.value });
                    }
                }
                try writer.writeAll("}\n");
            }
            if (has_post) {
                try writer.writeAll("\nvars:post-response {\n");
                for (vars) |v| {
                    if (v.var_type != .after_response) continue;
                    if (!v.enabled) {
                        try writer.print("  ~{s}: {s}\n", .{ v.name, v.value });
                    } else {
                        try writer.print("  {s}: {s}\n", .{ v.name, v.value });
                    }
                }
                try writer.writeAll("}\n");
            }
        }
    }

    // docs
    if (req.docs) |docs| {
        if (docs.content) |content| {
            try writer.writeAll("\ndocs {\n");
            try emitIndentedContent(writer, content);
            try writer.writeAll("}\n");
        } else if (docs.description) |desc| {
            try writer.writeAll("\ndocs {\n");
            try emitIndentedContent(writer, desc);
            try writer.writeAll("}\n");
        }
    }

    return buf.toOwnedSlice(allocator);
}

fn emitIndentedContent(writer: anytype, content: []const u8) !void {
    if (content.len == 0) return;
    var iter = std.mem.splitScalar(u8, content, '\n');
    while (iter.next()) |line| {
        try writer.print("  {s}\n", .{line});
    }
}

fn operatorToString(op: oc.AssertionOperator) []const u8 {
    return switch (op) {
        .eq => "eq",
        .neq => "neq",
        .contains => "contains",
        .not_contains => "notContains",
        .gt => "gt",
        .lt => "lt",
        .gte => "gte",
        .lte => "lte",
        .matches => "matches",
        .exists => "exists",
        .is_null => "isNull",
        .is_string => "isString",
        .is_number => "isNumber",
        .is_boolean => "isBoolean",
        .is_json => "isJson",
    };
}

// ── Tests ──────────────────────────────────────────────────────────────

test "emit minimal request" {
    const allocator = std.testing.allocator;

    const req = oc.OpenCollectionRequest{
        .info = .{ .name = "test" },
        .http = .{ .method = "get", .url = "https://example.com" },
    };

    const bru = try emit(allocator, req);
    defer allocator.free(bru);

    try std.testing.expect(std.mem.indexOf(u8, bru, "name: test") != null);
    try std.testing.expect(std.mem.indexOf(u8, bru, "get {") != null);
    try std.testing.expect(std.mem.indexOf(u8, bru, "url: https://example.com") != null);
}

test "emit with headers" {
    const allocator = std.testing.allocator;

    const headers = [_]oc.Header{
        .{ .name = "Accept", .value = "application/json" },
        .{ .name = "X-Debug", .value = "true", .enabled = false },
    };

    const req = oc.OpenCollectionRequest{
        .info = .{ .name = "test" },
        .http = .{ .method = "get", .url = "https://example.com", .headers = &headers },
    };

    const bru = try emit(allocator, req);
    defer allocator.free(bru);

    try std.testing.expect(std.mem.indexOf(u8, bru, "Accept: application/json") != null);
    try std.testing.expect(std.mem.indexOf(u8, bru, "~X-Debug: true") != null);
}

test "emit with auth bearer" {
    const allocator = std.testing.allocator;

    const req = oc.OpenCollectionRequest{
        .info = .{ .name = "test" },
        .http = .{
            .method = "get",
            .url = "https://example.com",
            .auth = oc.Auth{ .bearer = .{ .token = "my-token" } },
        },
    };

    const bru = try emit(allocator, req);
    defer allocator.free(bru);

    try std.testing.expect(std.mem.indexOf(u8, bru, "auth:bearer {") != null);
    try std.testing.expect(std.mem.indexOf(u8, bru, "token: my-token") != null);
}

test "emit with assertions" {
    const allocator = std.testing.allocator;

    const assertions = [_]oc.Assertion{
        .{ .expression = "res.status", .operator = .eq, .value = "200" },
    };

    const req = oc.OpenCollectionRequest{
        .info = .{ .name = "test" },
        .http = .{ .method = "get", .url = "https://example.com" },
        .runtime = oc.Runtime{ .assertions = &assertions },
    };

    const bru = try emit(allocator, req);
    defer allocator.free(bru);

    try std.testing.expect(std.mem.indexOf(u8, bru, "assert {") != null);
    try std.testing.expect(std.mem.indexOf(u8, bru, "res.status: eq 200") != null);
}
