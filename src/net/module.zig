pub const ws = @import("websocket.zig");
pub const http = @import("web.zig");
pub const host_http = http.host;
pub const host_ws = ws.host_ws;
pub const Conn = ws.Session;

test {
    @import("std").testing.refAllDecls(@This());
}
