const std = @import("std");
const tokenizer = @import("tokenizer.zig");
const parser = @import("parser.zig");
const transformer = @import("transformer.zig");
const yaml_emitter = @import("yaml_emitter.zig");

// ── Tokenizer Fuzz ─────────────────────────────────────────────────────

test "fuzz: tokenizer accepts arbitrary input without panic" {
    try std.testing.fuzz({}, fuzzTokenizer, .{
        .corpus = &.{
            "meta {\n  name: test\n}\n",
            "get {\n  url: https://example.com\n}\n",
            "",
            "{\n}\n",
            "body:json {\n  {\"key\": \"value\"}\n}\n",
            "~disabled: true\n",
            "@annotation(arg)\n",
        },
    });
}

fn fuzzTokenizer(_: void, input: []const u8) anyerror!void {
    var tok = tokenizer.Tokenizer.init(input);
    for (0..10_000) |_| {
        const maybe_token = tok.next() catch break;
        const token = maybe_token orelse break;
        if (token.token == .eof) break;
    }
}

// ── Parser Fuzz ────────────────────────────────────────────────────────

test "fuzz: parser handles arbitrary input gracefully" {
    try std.testing.fuzz({}, fuzzParser, .{
        .corpus = &.{
            "meta {\n  name: test\n}\n\nget {\n  url: https://example.com\n}\n",
            "meta {\n}\n\npost {\n  url: https://x.com\n}\n\nbody:json {\n  {}\n}\n",
            "",
            "{\n",
            "meta {\n  name: x\n",
            "headers {\n  Accept: application/json\n  X-Key: value\n}\n",
            "auth:bearer {\n  token: abc\n}\n",
            "script:pre-request {\n  const x = 1;\n}\n",
        },
    });
}

fn fuzzParser(_: void, input: []const u8) anyerror!void {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    _ = parser.parse(arena.allocator(), input) catch {};
}

// ── Full Pipeline Fuzz ─────────────────────────────────────────────────

test "fuzz: full pipeline handles arbitrary input" {
    try std.testing.fuzz({}, fuzzPipeline, .{
        .corpus = &.{
            "meta {\n  name: test\n  type: http\n}\n\nget {\n  url: https://example.com\n}\n",
            "meta {\n  name: p\n}\n\npost {\n  url: https://x.com\n}\n\nbody:json {\n  {\"a\":1}\n}\n",
            "meta {\n  name: a\n}\n\nget {\n  url: https://x.com\n}\n\nassert {\n  res.status: eq 200\n}\n",
        },
    });
}

fn fuzzPipeline(_: void, input: []const u8) anyerror!void {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    const doc = parser.parse(alloc, input) catch return;
    const req = transformer.transform(alloc, doc) catch return;
    const yaml = yaml_emitter.emit(alloc, req, .{}) catch return;
    _ = yaml;
}
