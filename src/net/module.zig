pub const host_ws = @import("websocket.zig").host;
pub const host_http = @import("web.zig").host;
const ws = @import("websocket");
pub const oauth = @import("oauth.zig");

pub const Conn = ws.Conn;

test {
    @import("std").testing.refAllDecls(@This());
}
