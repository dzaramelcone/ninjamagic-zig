const std = @import("std");
const core = @import("core");
const ws = @import("websocket");
var clients: std.AutoArrayHashMap(usize, *ws.Conn) = undefined;

pub fn init(alloc: std.mem.Allocator) void {
    clients = std.AutoArrayHashMap(usize, *ws.Conn).init(alloc);
}

pub fn deinit() void {
    clients.deinit();
}

pub fn step() void {
    var connects = core.bus.connect.flush() catch return;
    while (connects.next()) |sig| {
        const connect = sig.*;
        clients.put(connect.source, connect.conn) catch @panic("OOM");
    }
    var disconnects = core.bus.disconnect.flush() catch return;
    while (disconnects.next()) |sig| {
        const disconnect = sig.*;
        _ = clients.swapRemove(disconnect.source);
    }
}

pub fn get(id: usize) ?*ws.Conn {
    return clients.get(id);
}

pub fn list() []usize {
    return clients.keys();
}

pub const Iter = std.AutoArrayHashMap(usize, *ws.Conn).Iterator;
pub fn iter() Iter {
    return clients.iterator();
}

test "basic client tracking" {
    init(std.testing.allocator);
    defer deinit();
    try std.testing.expect(list().len == 0);
    var mockConn = ws.Conn{
        ._closed = false,
        .started = 0,
        .stream = undefined,
        .address = undefined,
    };

    try core.bus.enqueue(.{ .Connect = .{ .source = 1, .conn = &mockConn } });
    step();
    try std.testing.expect(get(1) != null);
    try std.testing.expect(get(2) == null);
    try std.testing.expect(list().len == 1);

    try core.bus.enqueue(.{ .Connect = .{ .source = 2, .conn = &mockConn } });
    step();
    try std.testing.expect(get(1) != null);
    try std.testing.expect(get(2) != null);
    try std.testing.expect(list().len == 2);

    try core.bus.enqueue(.{ .Disconnect = .{ .source = 1 } });
    step();
    try std.testing.expect(get(1) == null);
    try std.testing.expect(get(2) != null);
    try std.testing.expect(list().len == 1);

    try core.bus.enqueue(.{ .Disconnect = .{ .source = 2 } });
    step();
    try std.testing.expect(list().len == 0);
}
