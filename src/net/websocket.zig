const std = @import("std");
const ws = @import("websocket");
const cfg = @import("core").Config;
var next_id: std.atomic.Value(usize) = .{ .raw = 1 };

pub const Deps = struct {
    alloc: std.mem.Allocator,
    pushInbound: *const fn (usize, []u8) void,
    registerClient: *const fn (usize, *ws.Conn) void,
    unregister: *const fn (usize) void,
};

const WsHandler = struct {
    deps: *Deps,
    conn: *ws.Conn,
    user: usize,
    pub fn init(_: *const ws.Handshake, conn: *ws.Conn, deps: *Deps) !WsHandler {
        const id = next_id.fetchAdd(1, .monotonic);
        deps.registerClient(id, conn);
        return .{ .deps = deps, .conn = conn, .user = id };
    }
    pub fn deinit(self: *WsHandler) void {
        self.deps.unregister(self.user);
    }
    pub fn clientMessage(self: *WsHandler, raw: []const u8) !void {
        const buf = try self.deps.alloc.dupe(u8, raw);
        self.deps.pushInbound(self.user, buf);
        try self.conn.write(raw);
    }
};

pub fn host(deps: *Deps) !void {
    var ws_server = try ws.Server(WsHandler).init(deps.alloc, cfg.Ws);
    defer ws_server.deinit();
    try ws_server.listen(deps);
}
