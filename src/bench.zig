const std = @import("std");
const bru2oc = @import("bru2oc");

const parser = bru2oc.parser;
const transformer = bru2oc.transformer;
const yaml_emitter = bru2oc.yaml_emitter;

// ── Data Generation ────────────────────────────────────────────────────

fn generateBruRequest(alloc: std.mem.Allocator, index: usize) ![]const u8 {
    var buf: std.ArrayListUnmanaged(u8) = .empty;
    const writer = buf.writer(alloc);

    try writer.print(
        \\meta {{
        \\  name: request-{d}
        \\  type: http
        \\  seq: {d}
        \\}}
        \\
        \\
    , .{ index, index });

    const methods = [_][]const u8{ "get", "post", "put", "delete", "patch" };
    const method = methods[index % methods.len];

    try writer.print(
        \\{s} {{
        \\  url: https://api.example.com/resource/{d}
        \\}}
        \\
        \\headers {{
        \\  Accept: application/json
        \\  X-Request-ID: req-{d}
        \\  Authorization: Bearer token-{d}
        \\}}
        \\
        \\
    , .{ method, index, index, index });

    if (index % 3 == 0) {
        try writer.writeAll(
            \\params:query {
            \\  page: 1
            \\  limit: 20
            \\  ~debug: true
            \\}
            \\
            \\
        );
    }

    if (std.mem.eql(u8, method, "post") or std.mem.eql(u8, method, "put")) {
        try writer.print(
            \\body:json {{
            \\  {{
            \\    "id": {d},
            \\    "name": "item-{d}",
            \\    "active": true
            \\  }}
            \\}}
            \\
            \\
        , .{ index, index });
    }

    if (index % 5 == 0) {
        try writer.writeAll(
            \\auth:bearer {
            \\  token: my-jwt-token
            \\}
            \\
            \\assert {
            \\  res.status: eq 200
            \\}
            \\
            \\
        );
    }

    return buf.toOwnedSlice(alloc);
}

fn generateCollection(alloc: std.mem.Allocator, count: usize) ![]const []const u8 {
    var files: std.ArrayListUnmanaged([]const u8) = .empty;
    for (0..count) |i| {
        const content = try generateBruRequest(alloc, i);
        try files.append(alloc, content);
    }
    return files.toOwnedSlice(alloc);
}

// ── Benchmark Helpers ──────────────────────────────────────────────────

const BenchResult = struct {
    name: []const u8,
    iterations: usize,
    total_ns: u64,
    min_ns: u64,
    max_ns: u64,
    mean_ns: u64,
    bytes_processed: u64,
};

fn bench(name: []const u8, iterations: usize, bytes: u64, comptime func: anytype, args: anytype) BenchResult {
    var min_ns: u64 = std.math.maxInt(u64);
    var max_ns: u64 = 0;
    var total_ns: u64 = 0;

    for (0..iterations) |_| {
        var timer = std.time.Timer.start() catch unreachable;
        _ = @call(.auto, func, args);
        const elapsed = timer.read();
        total_ns += elapsed;
        if (elapsed < min_ns) min_ns = elapsed;
        if (elapsed > max_ns) max_ns = elapsed;
    }

    return .{
        .name = name,
        .iterations = iterations,
        .total_ns = total_ns,
        .min_ns = min_ns,
        .max_ns = max_ns,
        .mean_ns = total_ns / iterations,
        .bytes_processed = bytes * iterations,
    };
}

var out_buf: [8192]u8 = undefined;

fn printResult(r: BenchResult) void {
    const mean_us = @as(f64, @floatFromInt(r.mean_ns)) / 1000.0;
    const min_us = @as(f64, @floatFromInt(r.min_ns)) / 1000.0;
    const max_us = @as(f64, @floatFromInt(r.max_ns)) / 1000.0;
    const ops_per_sec = if (r.mean_ns > 0) @as(f64, 1_000_000_000.0) / @as(f64, @floatFromInt(r.mean_ns)) else 0;
    const mb_per_sec = if (r.mean_ns > 0 and r.bytes_processed > 0)
        @as(f64, @floatFromInt(r.bytes_processed / r.iterations)) / (@as(f64, @floatFromInt(r.mean_ns)) / 1_000_000_000.0) / (1024.0 * 1024.0)
    else
        0;

    var w = std.fs.File.stdout().writer(&out_buf);
    const writer = &w.interface;
    writer.print("  {s:<30} {d:>10.1} us  (min: {d:.1}, max: {d:.1})  {d:>10.0} ops/s", .{
        r.name,
        mean_us,
        min_us,
        max_us,
        ops_per_sec,
    }) catch {};
    if (mb_per_sec > 0) {
        writer.print("  {d:>8.1} MB/s", .{mb_per_sec}) catch {};
    }
    writer.writeAll("\n") catch {};
    writer.flush() catch {};
}

// ── Benchmark Functions ────────────────────────────────────────────────

fn benchParse(source: []const u8) ?*const anyopaque {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    _ = parser.parse(arena.allocator(), source) catch null;
    return null;
}

fn benchTransform(source: []const u8) ?*const anyopaque {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const alloc = arena.allocator();
    const doc = parser.parse(alloc, source) catch return null;
    _ = transformer.transform(alloc, doc) catch null;
    return null;
}

fn benchEmit(source: []const u8) ?*const anyopaque {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const alloc = arena.allocator();
    const doc = parser.parse(alloc, source) catch return null;
    const req = transformer.transform(alloc, doc) catch return null;
    _ = yaml_emitter.emit(alloc, req, .{}) catch null;
    return null;
}

fn benchEndToEnd(source: []const u8) ?*const anyopaque {
    return benchEmit(source);
}

// ── Main ───────────────────────────────────────────────────────────────

fn writeOut(comptime fmt: []const u8, args: anytype) void {
    var w = std.fs.File.stdout().writer(&out_buf);
    const writer = &w.interface;
    writer.print(fmt, args) catch {};
    writer.flush() catch {};
}

fn writeStr(s: []const u8) void {
    var w = std.fs.File.stdout().writer(&out_buf);
    const writer = &w.interface;
    writer.writeAll(s) catch {};
    writer.flush() catch {};
}

pub fn main() !void {
    var gpa_state: std.heap.DebugAllocator(.{}) = .init;
    defer _ = gpa_state.deinit();
    const alloc = gpa_state.allocator();

    writeStr("\n=== bru2oc Performance Benchmarks ===\n\n");

    // Generate test data
    const sizes = [_]struct { count: usize, name: []const u8 }{
        .{ .count = 1, .name = "small (1 req)" },
        .{ .count = 10, .name = "medium (10 req)" },
        .{ .count = 100, .name = "large (100 req)" },
    };

    for (sizes) |size| {
        const files = try generateCollection(alloc, size.count);
        defer {
            for (files) |f| alloc.free(f);
            alloc.free(files);
        }

        // Calculate total bytes
        var total_bytes: u64 = 0;
        for (files) |f| total_bytes += f.len;

        writeOut("--- {s} ({d} bytes total) ---\n", .{ size.name, total_bytes });

        const iterations: usize = if (size.count <= 10) 1000 else 100;

        // Benchmark each stage for each file (use first file as representative)
        const sample = files[0];
        const sample_bytes = sample.len;

        printResult(bench("parse", iterations, sample_bytes, benchParse, .{sample}));
        printResult(bench("parse + transform", iterations, sample_bytes, benchTransform, .{sample}));
        printResult(bench("parse + transform + emit", iterations, sample_bytes, benchEmit, .{sample}));

        // End-to-end for all files in the collection
        for (files) |f| {
            _ = benchEndToEnd(f);
        }
        var timer = std.time.Timer.start() catch unreachable;
        for (0..@min(iterations, 100)) |_| {
            for (files) |f| {
                _ = benchEndToEnd(f);
            }
        }
        const batch_ns = timer.read();
        const batch_iters = @min(iterations, 100);
        const batch_mean = batch_ns / batch_iters;
        const batch_us = @as(f64, @floatFromInt(batch_mean)) / 1000.0;
        const batch_ops = if (batch_mean > 0) @as(f64, 1_000_000_000.0) / @as(f64, @floatFromInt(batch_mean)) * @as(f64, @floatFromInt(size.count)) else 0;

        writeOut("  {s:<30} {d:>10.1} us  ({d:.0} files/s)\n", .{
            "batch e2e",
            batch_us,
            batch_ops,
        });

        writeStr("\n");
    }

    writeStr("=== Benchmarks complete ===\n\n");
}
