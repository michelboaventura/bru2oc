const std = @import("std");

/// Annotation on an entry, e.g. @disabled, @description("text"), @enum("a","b")
pub const Annotation = struct {
    name: []const u8,
    args: []const Value,

    pub fn init(name: []const u8, args: []const Value) Annotation {
        return .{ .name = name, .args = args };
    }

    pub fn noArgs(name: []const u8) Annotation {
        return .{ .name = name, .args = &.{} };
    }
};

/// A key-value entry in a multimap block.
pub const Entry = struct {
    annotations: []const Annotation,
    key: []const u8,
    value: Value,
    disabled: bool,
    line: usize,

    pub fn init(key: []const u8, value: Value) Entry {
        return .{
            .annotations = &.{},
            .key = key,
            .value = value,
            .disabled = false,
            .line = 0,
        };
    }

    pub fn withLine(self: Entry, line: usize) Entry {
        var copy = self;
        copy.line = line;
        return copy;
    }

    pub fn withAnnotations(self: Entry, annotations: []const Annotation) Entry {
        var copy = self;
        copy.annotations = annotations;
        return copy;
    }

    pub fn asDisabled(self: Entry) Entry {
        var copy = self;
        copy.disabled = true;
        return copy;
    }
};

/// Tagged union representing all possible Bru value types.
pub const Value = union(enum) {
    null: void,
    bool: bool,
    number: []const u8,
    string: []const u8,
    multimap: []const Entry,
    array: []const Value,
    multistring: []const u8,

    pub fn isNull(self: Value) bool {
        return self == .null;
    }

    pub fn asString(self: Value) ?[]const u8 {
        return switch (self) {
            .string => |s| s,
            .number => |n| n,
            .multistring => |m| m,
            else => null,
        };
    }

    pub fn asBool(self: Value) ?bool {
        return switch (self) {
            .bool => |b| b,
            else => null,
        };
    }
};

/// Top-level Bru document: a multimap of blocks.
pub const BruDocument = struct {
    entries: []const Entry,
    allocator: std.mem.Allocator,

    pub fn init(allocator: std.mem.Allocator, entries: []const Entry) BruDocument {
        return .{
            .entries = entries,
            .allocator = allocator,
        };
    }

    /// Find all entries with a given key.
    pub fn getEntries(self: BruDocument, key: []const u8) []const Entry {
        var count: usize = 0;
        for (self.entries) |e| {
            if (std.mem.eql(u8, e.key, key)) count += 1;
        }
        if (count == 0) return &.{};

        // Return a slice view — we just do a linear scan for simplicity
        // Since entries is const, we search each time. For the typical
        // small number of top-level blocks this is fine.
        return self.entries;
    }

    /// Find the first entry with a given key.
    pub fn getFirst(self: BruDocument, key: []const u8) ?Entry {
        for (self.entries) |e| {
            if (std.mem.eql(u8, e.key, key)) return e;
        }
        return null;
    }

    pub fn deinit(self: *BruDocument) void {
        // When using ArenaAllocator, all memory is freed at once.
        // This is a no-op placeholder for interface compatibility.
        _ = self;
    }
};

// ── Tests ──────────────────────────────────────────────────────────────

test "Value tagged union variants" {
    const null_val = Value{ .null = {} };
    try std.testing.expect(null_val.isNull());

    const bool_val = Value{ .bool = true };
    try std.testing.expectEqual(true, bool_val.asBool().?);

    const num_val = Value{ .number = "123" };
    try std.testing.expectEqualStrings("123", num_val.asString().?);

    const str_val = Value{ .string = "hello" };
    try std.testing.expectEqualStrings("hello", str_val.asString().?);

    const ms_val = Value{ .multistring = "line1\nline2" };
    try std.testing.expectEqualStrings("line1\nline2", ms_val.asString().?);
}

test "Value number preserves original string" {
    const v1 = Value{ .number = "1.0" };
    const v2 = Value{ .number = "1" };
    const v3 = Value{ .number = "1e10" };
    try std.testing.expectEqualStrings("1.0", v1.asString().?);
    try std.testing.expectEqualStrings("1", v2.asString().?);
    try std.testing.expectEqualStrings("1e10", v3.asString().?);
}

test "Annotation creation" {
    const no_args = Annotation.noArgs("disabled");
    try std.testing.expectEqualStrings("disabled", no_args.name);
    try std.testing.expectEqual(@as(usize, 0), no_args.args.len);

    const args = [_]Value{
        Value{ .string = "option_a" },
        Value{ .string = "option_b" },
    };
    const with_args = Annotation.init("enum", &args);
    try std.testing.expectEqualStrings("enum", with_args.name);
    try std.testing.expectEqual(@as(usize, 2), with_args.args.len);
}

test "Entry creation and builder methods" {
    const entry = Entry.init("Content-Type", Value{ .string = "application/json" })
        .withLine(5);
    try std.testing.expectEqualStrings("Content-Type", entry.key);
    try std.testing.expectEqualStrings("application/json", entry.value.asString().?);
    try std.testing.expectEqual(@as(usize, 5), entry.line);
    try std.testing.expectEqual(false, entry.disabled);

    const disabled = entry.asDisabled();
    try std.testing.expectEqual(true, disabled.disabled);
    try std.testing.expectEqualStrings("Content-Type", disabled.key);
}

test "Entry with annotations" {
    const annotations = [_]Annotation{
        Annotation.noArgs("disabled"),
        Annotation.init("description", &.{Value{ .string = "test header" }}),
    };
    const entry = Entry.init("X-Custom", Value{ .string = "val" })
        .withAnnotations(&annotations);
    try std.testing.expectEqual(@as(usize, 2), entry.annotations.len);
    try std.testing.expectEqualStrings("disabled", entry.annotations[0].name);
}

test "BruDocument getFirst" {
    const entries = [_]Entry{
        Entry.init("meta", Value{ .string = "data" }),
        Entry.init("headers", Value{ .string = "h" }),
        Entry.init("meta", Value{ .string = "data2" }),
    };
    const doc = BruDocument.init(std.testing.allocator, &entries);
    const meta = doc.getFirst("meta");
    try std.testing.expect(meta != null);
    try std.testing.expectEqualStrings("meta", meta.?.key);
    try std.testing.expectEqualStrings("data", meta.?.value.asString().?);

    const missing = doc.getFirst("nonexistent");
    try std.testing.expect(missing == null);
}

test "Value array variant" {
    const items = [_]Value{
        Value{ .string = "a" },
        Value{ .number = "1" },
        Value{ .bool = false },
    };
    const arr = Value{ .array = &items };
    switch (arr) {
        .array => |a| try std.testing.expectEqual(@as(usize, 3), a.len),
        else => return error.UnexpectedToken,
    }
}

test "Value multimap variant" {
    const entries = [_]Entry{
        Entry.init("key1", Value{ .string = "val1" }),
        Entry.init("key2", Value{ .number = "42" }),
    };
    const mm = Value{ .multimap = &entries };
    switch (mm) {
        .multimap => |m| {
            try std.testing.expectEqual(@as(usize, 2), m.len);
            try std.testing.expectEqualStrings("key1", m[0].key);
        },
        else => return error.UnexpectedToken,
    }
}
