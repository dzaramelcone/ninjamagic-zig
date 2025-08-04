const std = @import("std");
const core = @import("core");
const ws = @import("ws");

var clients: std.AutoArrayHashMap(usize, *ws.Conn) = undefined;

pub fn init(alloc: std.mem.Allocator) !void {
    clients.init(alloc);
}
pub fn deinit() void {
    clients.deinit();
}
pub fn step() void {
    var connects = core.bus.connect.flush() catch return;
    while (connects.next()) |sig| {
        const connect = sig.*;
        clients.put(connect.source, connect.conn);
    }
    var disconnects = core.bus.disconnect.flush() catch return;
    while (disconnects.next()) |sig| {
        const disconnect = sig.*;
        clients.swapRemove(disconnect.source);
    }
}

pub fn list() []usize {
    return clients.keys();
}
