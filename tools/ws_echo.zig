const std = @import("std");
const net = @import("../src/net/module.zig");

const Echo = struct {
    conns: std.AutoArrayHashMap(usize, *net.Conn),

    pub fn init(alloc: std.mem.Allocator) Echo {
        return .{ .conns = std.AutoArrayHashMap(usize, *net.Conn).init(alloc) };
    }

    pub fn onConnect(self: *Echo, id: usize, c: *net.Conn) !void {
        try self.conns.put(id, c);
    }
    pub fn onDisconnect(self: *Echo, id: usize) void {
        _ = self.conns.remove(id);
    }
    pub fn onMessage(self: *Echo, id: usize, msg: []const u8) !void {
        const c = self.conns.get(id) orelse return;
        try c.write(msg);
    }
};

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    var echo = Echo.init(gpa.allocator());
    try net.host_ws(Echo, gpa.allocator(), &echo);
}
