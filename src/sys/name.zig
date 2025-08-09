const std = @import("std");
const core = @import("../core/module.zig");

var names: std.AutoArrayHashMap(usize, []const u8) = undefined;
var alloc: std.mem.Allocator = undefined;

pub fn init(allocator: std.mem.Allocator) void {
    alloc = allocator;
    names = std.AutoArrayHashMap(usize, []const u8).init(alloc);
}

pub fn deinit() void {
    for (names.values()) |v| alloc.free(v);
    names.deinit();
    alloc = undefined;
}

pub fn get(id: usize) ![]const u8 {
    return names.get(id) orelse return error.NotFound;
}

pub fn put(id: usize, name: []const u8) void {
    const copy = alloc.dupe(u8, name) catch @panic("OOM");
    if ((names.fetchPut(id, copy) catch @panic("OOM"))) |kv| {
        alloc.free(kv.value);
    }
}

test "sys/name.zig: put does not alias input buffer" {
    init(std.testing.allocator);
    defer deinit();

    const buf = try std.testing.allocator.alloc(u8, 5);
    defer std.testing.allocator.free(buf);
    @memcpy(buf, "Alice");
    put(1, buf);
    // mutate source
    @memcpy(buf, "ZZZZZ");
    const got = try get(1);
    try std.testing.expectEqualStrings("Alice", got);
}
