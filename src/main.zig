const std = @import("std");
const bru2oc = @import("bru2oc");

pub fn main() !void {
    var gpa_state: std.heap.DebugAllocator(.{}) = .init;
    defer _ = gpa_state.deinit();
    const allocator = gpa_state.allocator();

    const args = try std.process.argsAlloc(allocator);
    defer std.process.argsFree(allocator, args);

    // Skip program name (args[0])
    const cli_args = if (args.len > 1) args[1..] else args[0..0];

    const exit_code = bru2oc.converter.run(allocator, cli_args) catch {
        std.process.exit(1);
    };

    std.process.exit(exit_code);
}
