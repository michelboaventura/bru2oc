const std = @import("std");
const parser = @import("parser.zig");
const transformer = @import("transformer.zig");
const yaml_emitter = @import("yaml_emitter.zig");
const fs_utils = @import("fs_utils.zig");
const converter = @import("converter.zig");

// ── End-to-End Integration Tests ────────────────────────────────────────

test "end-to-end: simple GET request" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    const source =
        \\meta {
        \\  name: get-users
        \\  type: http
        \\  seq: 1
        \\}
        \\
        \\get {
        \\  url: https://api.example.com/users
        \\}
        \\
        \\headers {
        \\  Accept: application/json
        \\}
    ;

    const doc = try parser.parse(alloc, source);
    const req = try transformer.transform(alloc, doc);
    const yaml = try yaml_emitter.emit(alloc, req, .{});

    try std.testing.expect(std.mem.indexOf(u8, yaml, "name: get-users") != null);
    try std.testing.expect(std.mem.indexOf(u8, yaml, "method: get") != null);
    try std.testing.expect(std.mem.indexOf(u8, yaml, "https://api.example.com/users") != null);
    try std.testing.expect(std.mem.indexOf(u8, yaml, "Accept") != null);
    try std.testing.expect(fs_utils.verifyYaml(yaml));
}

test "end-to-end: POST with JSON body" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    const source =
        \\meta {
        \\  name: create-user
        \\  type: http
        \\}
        \\
        \\post {
        \\  url: https://api.example.com/users
        \\}
        \\
        \\headers {
        \\  Content-Type: application/json
        \\}
        \\
        \\body:json {
        \\  {
        \\    "name": "John",
        \\    "email": "john@example.com"
        \\  }
        \\}
    ;

    const doc = try parser.parse(alloc, source);
    const req = try transformer.transform(alloc, doc);
    const yaml = try yaml_emitter.emit(alloc, req, .{});

    try std.testing.expect(std.mem.indexOf(u8, yaml, "method: post") != null);
    try std.testing.expect(std.mem.indexOf(u8, yaml, "type: json") != null);
    try std.testing.expect(std.mem.indexOf(u8, yaml, "\"name\"") != null);
    try std.testing.expect(fs_utils.verifyYaml(yaml));
}

test "end-to-end: request with auth and assertions" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    const source =
        \\meta {
        \\  name: protected-endpoint
        \\  type: http
        \\}
        \\
        \\get {
        \\  url: https://api.example.com/protected
        \\}
        \\
        \\auth:bearer {
        \\  token: my-jwt-token
        \\}
        \\
        \\assert {
        \\  res.status: eq 200
        \\}
    ;

    const doc = try parser.parse(alloc, source);
    const req = try transformer.transform(alloc, doc);
    const yaml = try yaml_emitter.emit(alloc, req, .{});

    try std.testing.expect(std.mem.indexOf(u8, yaml, "type: bearer") != null);
    try std.testing.expect(std.mem.indexOf(u8, yaml, "token: my-jwt-token") != null);
    try std.testing.expect(std.mem.indexOf(u8, yaml, "assertions:") != null);
    try std.testing.expect(std.mem.indexOf(u8, yaml, "res.status") != null);
    try std.testing.expect(fs_utils.verifyYaml(yaml));
}

test "end-to-end: request with scripts" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    const source =
        \\meta {
        \\  name: scripted-request
        \\  type: http
        \\}
        \\
        \\get {
        \\  url: https://api.example.com/data
        \\}
        \\
        \\script:pre-request {
        \\  const token = bru.getEnvVar("TOKEN");
        \\  req.setHeader("Authorization", token);
        \\}
        \\
        \\script:post-response {
        \\  const body = res.getBody();
        \\  bru.setVar("result", body.data);
        \\}
    ;

    const doc = try parser.parse(alloc, source);
    const req = try transformer.transform(alloc, doc);
    const yaml = try yaml_emitter.emit(alloc, req, .{});

    try std.testing.expect(std.mem.indexOf(u8, yaml, "scripts:") != null);
    try std.testing.expect(std.mem.indexOf(u8, yaml, "before_request") != null);
    try std.testing.expect(std.mem.indexOf(u8, yaml, "after_response") != null);
    try std.testing.expect(fs_utils.verifyYaml(yaml));
}

test "end-to-end: request with query and path params" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    const source =
        \\meta {
        \\  name: param-test
        \\  type: http
        \\}
        \\
        \\get {
        \\  url: https://api.example.com/users/:id
        \\}
        \\
        \\params:query {
        \\  page: 1
        \\  limit: 10
        \\  ~debug: true
        \\}
        \\
        \\params:path {
        \\  id: 42
        \\}
    ;

    const doc = try parser.parse(alloc, source);
    const req = try transformer.transform(alloc, doc);
    const yaml = try yaml_emitter.emit(alloc, req, .{});

    try std.testing.expect(std.mem.indexOf(u8, yaml, "params:") != null);
    try std.testing.expect(std.mem.indexOf(u8, yaml, "type: query") != null);
    try std.testing.expect(std.mem.indexOf(u8, yaml, "type: path") != null);
    try std.testing.expect(std.mem.indexOf(u8, yaml, "enabled: false") != null);
    try std.testing.expect(fs_utils.verifyYaml(yaml));
}

test "end-to-end: request with docs" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    const source =
        \\meta {
        \\  name: documented-request
        \\  type: http
        \\}
        \\
        \\get {
        \\  url: https://api.example.com/health
        \\}
        \\
        \\docs {
        \\  Health check endpoint.
        \\  Returns server status.
        \\}
    ;

    const doc = try parser.parse(alloc, source);
    const req = try transformer.transform(alloc, doc);
    const yaml = try yaml_emitter.emit(alloc, req, .{});

    try std.testing.expect(std.mem.indexOf(u8, yaml, "docs:") != null);
    try std.testing.expect(std.mem.indexOf(u8, yaml, "Health check endpoint") != null);
    try std.testing.expect(fs_utils.verifyYaml(yaml));
}

test "end-to-end: file conversion roundtrip" {
    const allocator = std.testing.allocator;

    var tmp_dir = std.testing.tmpDir(.{});
    defer tmp_dir.cleanup();

    const bru_content =
        \\meta {
        \\  name: roundtrip-test
        \\  type: http
        \\  seq: 1
        \\}
        \\
        \\get {
        \\  url: https://example.com/api
        \\}
        \\
        \\headers {
        \\  Accept: application/json
        \\  ~X-Debug: true
        \\}
    ;

    tmp_dir.dir.writeFile(.{ .sub_path = "test.bru", .data = bru_content }) catch return;

    const tmp_path = tmp_dir.dir.realpathAlloc(allocator, ".") catch return;
    defer allocator.free(tmp_path);

    const input_path = std.fmt.allocPrint(allocator, "{s}/test.bru", .{tmp_path}) catch return;
    defer allocator.free(input_path);

    const result = converter.convertFile(allocator, input_path, .{});
    if (result.output_path) |op| allocator.free(op);

    try std.testing.expect(result.success);

    // Read the output and verify it's valid YAML
    const output_path = std.fmt.allocPrint(allocator, "{s}/test.yml", .{tmp_path}) catch return;
    defer allocator.free(output_path);

    const yaml_content = tmp_dir.dir.readFileAlloc(allocator, "test.yml", 1024 * 1024) catch return;
    defer allocator.free(yaml_content);

    try std.testing.expect(yaml_content.len > 0);
    try std.testing.expect(fs_utils.verifyYaml(yaml_content));
    try std.testing.expect(std.mem.indexOf(u8, yaml_content, "roundtrip-test") != null);
}

// ── Additional Parser Tests ─────────────────────────────────────────────

test "parser: empty meta block" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const doc = try parser.parse(arena.allocator(), "meta {\n}\n\nget {\n  url: https://x.com\n}");
    try std.testing.expect(doc.getFirst("meta") != null);
}

test "parser: multiple body types" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    const source =
        \\meta {
        \\  name: xml-test
        \\}
        \\
        \\post {
        \\  url: https://example.com
        \\}
        \\
        \\body:xml {
        \\  <root><item>value</item></root>
        \\}
    ;

    const doc = try parser.parse(alloc, source);
    try std.testing.expect(doc.getFirst("body:xml") != null);
}

// ── Additional Transformer Tests ────────────────────────────────────────

test "transformer: auth basic" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    const source =
        \\meta {
        \\  name: basic-auth
        \\}
        \\
        \\get {
        \\  url: https://example.com
        \\}
        \\
        \\auth:basic {
        \\  username: admin
        \\  password: secret
        \\}
    ;

    const doc = try parser.parse(alloc, source);
    const req = try transformer.transform(alloc, doc);
    const auth = req.http.auth.?;
    switch (auth) {
        .basic => |b| {
            try std.testing.expectEqualStrings("admin", b.username);
            try std.testing.expectEqualStrings("secret", b.password);
        },
        else => return error.MissingRequiredField,
    }
}

test "transformer: vars pre and post" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    const source =
        \\meta {
        \\  name: vars-test
        \\}
        \\
        \\get {
        \\  url: https://example.com
        \\}
        \\
        \\vars:pre-request {
        \\  token: abc123
        \\}
        \\
        \\vars:post-response {
        \\  result: res.body
        \\}
    ;

    const doc = try parser.parse(alloc, source);
    const req = try transformer.transform(alloc, doc);
    const vars = req.runtime.?.vars.?;
    try std.testing.expectEqual(@as(usize, 2), vars.len);
}

// ── Additional Emitter Tests ────────────────────────────────────────────

test "emitter: auth basic output" {
    const allocator = std.testing.allocator;

    const req = @import("opencollection.zig").OpenCollectionRequest{
        .info = .{ .name = "test" },
        .http = .{
            .method = "GET",
            .url = "https://example.com",
            .auth = @import("opencollection.zig").Auth{ .basic = .{
                .username = "user",
                .password = "pass",
            } },
        },
    };

    const yaml = try yaml_emitter.emit(allocator, req, .{});
    defer allocator.free(yaml);

    try std.testing.expect(std.mem.indexOf(u8, yaml, "type: basic") != null);
    try std.testing.expect(std.mem.indexOf(u8, yaml, "username: user") != null);
    try std.testing.expect(std.mem.indexOf(u8, yaml, "password: pass") != null);
}

test "emitter: assertions output" {
    const allocator = std.testing.allocator;
    const oc = @import("opencollection.zig");

    const assertions = [_]oc.Assertion{
        .{ .expression = "res.status", .operator = .eq, .value = "200" },
        .{ .expression = "res.body", .operator = .contains, .value = "ok" },
    };

    const req = oc.OpenCollectionRequest{
        .info = .{ .name = "test" },
        .http = .{ .method = "GET", .url = "https://example.com" },
        .runtime = oc.Runtime{ .assertions = &assertions },
    };

    const yaml = try yaml_emitter.emit(allocator, req, .{});
    defer allocator.free(yaml);

    try std.testing.expect(std.mem.indexOf(u8, yaml, "assertions:") != null);
    try std.testing.expect(std.mem.indexOf(u8, yaml, "operator: eq") != null);
    try std.testing.expect(std.mem.indexOf(u8, yaml, "operator: contains") != null);
}
