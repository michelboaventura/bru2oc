const std = @import("std");

/// Top-level OpenCollection request representation.
pub const OpenCollectionRequest = struct {
    info: Info,
    http: Http,
    runtime: ?Runtime = null,
    settings: ?Settings = null,
    docs: ?Docs = null,
};

/// Request metadata.
pub const Info = struct {
    name: []const u8,
    type: []const u8 = "http",
    seq: ?usize = null,
    tags: ?[]const []const u8 = null,
};

/// Placeholder for request-level settings.
pub const Settings = struct {
    timeout: ?usize = null,
    follow_redirects: ?bool = null,
};

/// Documentation block.
pub const Docs = struct {
    description: ?[]const u8 = null,
    content: ?[]const u8 = null,
};

/// HTTP request configuration.
pub const Http = struct {
    method: []const u8,
    url: []const u8,
    headers: ?[]const Header = null,
    params: ?[]const Param = null,
    body: ?Body = null,
    auth: ?Auth = null,
};

/// HTTP header.
pub const Header = struct {
    name: []const u8,
    value: []const u8,
    enabled: bool = true,
};

/// Parameter type: query string or path variable.
pub const ParamType = enum {
    query,
    path,
};

/// HTTP parameter.
pub const Param = struct {
    name: []const u8,
    value: []const u8,
    param_type: ParamType = .query,
    enabled: bool = true,
};

/// Form field for URL-encoded bodies.
pub const FormField = struct {
    name: []const u8,
    value: []const u8,
    enabled: bool = true,
};

/// Multipart form part.
pub const MultipartPart = struct {
    name: []const u8,
    value: []const u8,
    filename: ?[]const u8 = null,
    content_type: ?[]const u8 = null,
    enabled: bool = true,
};

/// Request body tagged union.
pub const Body = union(enum) {
    json: []const u8,
    xml: []const u8,
    text: []const u8,
    form_urlencoded: []const FormField,
    multipart_form: []const MultipartPart,
    graphql: GraphQL,
    sparql: []const u8,
};

/// GraphQL request body.
pub const GraphQL = struct {
    query: []const u8,
    variables: ?[]const u8 = null,
    operation_name: ?[]const u8 = null,
};

/// Authentication tagged union.
pub const Auth = union(enum) {
    bearer: BearerAuth,
    basic: BasicAuth,
    oauth2: OAuth2Auth,
    aws_v4: AwsV4Auth,
    digest: DigestAuth,
    api_key: ApiKeyAuth,
    none: void,
};

pub const BearerAuth = struct {
    token: []const u8,
    prefix: ?[]const u8 = null,
};

pub const BasicAuth = struct {
    username: []const u8,
    password: []const u8,
};

pub const OAuth2Auth = struct {
    access_token: []const u8,
    token_type: ?[]const u8 = null,
    refresh_token: ?[]const u8 = null,
};

pub const AwsV4Auth = struct {
    access_key: []const u8,
    secret_key: []const u8,
    region: []const u8,
    service: []const u8,
    session_token: ?[]const u8 = null,
};

pub const DigestAuth = struct {
    username: []const u8,
    password: []const u8,
    realm: ?[]const u8 = null,
};

pub const ApiKeyAuth = struct {
    key: []const u8,
    value: []const u8,
    placement: []const u8 = "header",
};

/// When a script executes.
pub const ScriptType = enum {
    before_request,
    after_response,
    tests,
};

/// A script block.
pub const Script = struct {
    script_type: ScriptType,
    code: []const u8,
    enabled: bool = true,
};

/// Assertion operator.
pub const AssertionOperator = enum {
    eq,
    neq,
    contains,
    not_contains,
    gt,
    lt,
    gte,
    lte,
    matches,
    exists,
    is_null,
    is_string,
    is_number,
    is_boolean,
    is_json,
};

/// A test assertion.
pub const Assertion = struct {
    expression: []const u8,
    operator: AssertionOperator,
    value: []const u8,
    enabled: bool = true,
};

/// Variable scope.
pub const VarType = enum {
    before_request,
    after_response,
};

/// A runtime variable.
pub const Var = struct {
    name: []const u8,
    value: []const u8,
    var_type: VarType = .before_request,
    enabled: bool = true,
};

/// Runtime configuration: scripts, assertions, variables.
pub const Runtime = struct {
    scripts: ?[]const Script = null,
    assertions: ?[]const Assertion = null,
    vars: ?[]const Var = null,
};

// ── Tests ──────────────────────────────────────────────────────────────

test "OpenCollectionRequest with required fields" {
    const req = OpenCollectionRequest{
        .info = .{ .name = "test" },
        .http = .{ .method = "GET", .url = "https://example.com" },
    };
    try std.testing.expectEqualStrings("test", req.info.name);
    try std.testing.expectEqualStrings("GET", req.http.method);
    try std.testing.expectEqual(@as(?Runtime, null), req.runtime);
    try std.testing.expectEqual(@as(?Docs, null), req.docs);
}

test "Info with optional fields" {
    const info = Info{ .name = "my-request", .type = "graphql", .seq = 5 };
    try std.testing.expectEqualStrings("my-request", info.name);
    try std.testing.expectEqual(@as(?usize, 5), info.seq);
}

test "Header enabled by default" {
    const h = Header{ .name = "Content-Type", .value = "application/json" };
    try std.testing.expect(h.enabled);
}

test "Header disabled" {
    const h = Header{ .name = "X-Debug", .value = "true", .enabled = false };
    try std.testing.expect(!h.enabled);
}

test "Param types" {
    const q = Param{ .name = "page", .value = "1", .param_type = .query };
    const p = Param{ .name = "id", .value = "123", .param_type = .path };
    try std.testing.expectEqual(ParamType.query, q.param_type);
    try std.testing.expectEqual(ParamType.path, p.param_type);
}

test "Body json variant" {
    const body = Body{ .json = "{\"key\": \"value\"}" };
    switch (body) {
        .json => |data| try std.testing.expect(data.len > 0),
        else => return error.Unexpected,
    }
}

test "Body graphql variant" {
    const body = Body{ .graphql = .{
        .query = "{ users { id name } }",
        .variables = "{\"limit\": 10}",
    } };
    switch (body) {
        .graphql => |gql| {
            try std.testing.expect(gql.query.len > 0);
            try std.testing.expect(gql.variables != null);
        },
        else => return error.Unexpected,
    }
}

test "Auth bearer" {
    const auth = Auth{ .bearer = .{ .token = "abc123" } };
    switch (auth) {
        .bearer => |b| try std.testing.expectEqualStrings("abc123", b.token),
        else => return error.Unexpected,
    }
}

test "Auth basic" {
    const auth = Auth{ .basic = .{ .username = "user", .password = "pass" } };
    switch (auth) {
        .basic => |b| {
            try std.testing.expectEqualStrings("user", b.username);
            try std.testing.expectEqualStrings("pass", b.password);
        },
        else => return error.Unexpected,
    }
}

test "Script types" {
    const pre = Script{ .script_type = .before_request, .code = "console.log('pre');" };
    const post = Script{ .script_type = .after_response, .code = "console.log('post');" };
    try std.testing.expectEqual(ScriptType.before_request, pre.script_type);
    try std.testing.expectEqual(ScriptType.after_response, post.script_type);
    try std.testing.expect(pre.enabled);
}

test "Assertion operators" {
    const a = Assertion{ .expression = "res.status", .operator = .eq, .value = "200" };
    try std.testing.expectEqual(AssertionOperator.eq, a.operator);
    try std.testing.expect(a.enabled);
}

test "Runtime with all optional null" {
    const rt = Runtime{};
    try std.testing.expectEqual(@as(?[]const Script, null), rt.scripts);
    try std.testing.expectEqual(@as(?[]const Assertion, null), rt.assertions);
    try std.testing.expectEqual(@as(?[]const Var, null), rt.vars);
}

test "Var types" {
    const v = Var{ .name = "token", .value = "{{token}}", .var_type = .after_response };
    try std.testing.expectEqual(VarType.after_response, v.var_type);
}

test "FormField" {
    const f = FormField{ .name = "username", .value = "test" };
    try std.testing.expectEqualStrings("username", f.name);
    try std.testing.expect(f.enabled);
}

test "Body form_urlencoded" {
    const fields = [_]FormField{
        .{ .name = "user", .value = "test" },
        .{ .name = "pass", .value = "secret" },
    };
    const body = Body{ .form_urlencoded = &fields };
    switch (body) {
        .form_urlencoded => |ff| try std.testing.expectEqual(@as(usize, 2), ff.len),
        else => return error.Unexpected,
    }
}
