const std = @import("std");
const ws = @import("websocket");
const core = @import("core");
const cfg = core.Config;

pub fn Handler(comptime T: type) type {
    return struct {
        impl: *T,
        conn: *ws.Conn,
        id: usize,

        pub fn init(h: *const ws.Handshake, conn: *ws.Conn, impl: *T) !@This() {
            _ = h; // (custom checks here, like session token)
            const id = core.getId();
            try impl.onConnect(id, conn);
            return .{ .impl = impl, .conn = conn, .id = id };
        }

        pub fn deinit(self: *@This()) void {
            self.impl.onDisconnect(self.id);
        }

        pub fn clientMessage(self: *@This(), raw: []const u8) !void {
            self.impl.onMessage(self.id, raw) catch |err| try self.conn.write(@errorName(err));
        }

        pub fn close(self: *@This()) void {
            self.deinit();
        }
    };
}

pub fn host(comptime T: type, allocator: std.mem.Allocator, impl: *T) !void {
    var server = try ws.Server(Handler(T)).init(allocator, cfg.Ws);
    defer server.deinit();
    try server.listen(impl);
}
