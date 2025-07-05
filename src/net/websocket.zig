const std = @import("std");
const ws = @import("websocket");
const cfg = @import("core").Config;

const App = struct {};
const WsHandler = struct {
    app: *App,
    conn: *ws.Conn,
    pub fn init(_: *const ws.Handshake, conn: *ws.Conn, app: *App) !WsHandler {
        return .{
            .app = app,
            .conn = conn,
        };
    }

    pub fn clientMessage(self: *WsHandler, data: []const u8) !void {
        try self.conn.write(data); // echo the message back
    }
};

pub fn host(alloc: std.mem.Allocator) !void {
    // start the ws_server. TODO: move this into tardy if possible
    var ws_server = try ws.Server(WsHandler).init(alloc, cfg.Ws);
    defer ws_server.deinit();

    var app = App{};
    try ws_server.listen(&app);
}
