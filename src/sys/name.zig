const std = @import("std");
const core = @import("../core/module.zig");

var names: std.AutoArrayHashMap(usize, []const u8) = undefined;
var alloc: std.mem.Allocator = undefined;

pub fn init(allocator: std.mem.Allocator) void {
    alloc = allocator;
    names = std.AutoArrayHashMap(usize, []const u8).init(alloc);
}

pub fn deinit() void {
    names.deinit();
    alloc = undefined;
}

pub fn get(id: usize) ![]const u8 {
    return names.get(id) orelse return error.NotFound;
}

pub fn put(id: usize, name: []const u8) void {
    names.put(id, name) catch @panic("OOM");
}
