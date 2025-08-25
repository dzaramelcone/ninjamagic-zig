pub const host_ws = @import("websocket.zig").host;
pub const host_http = @import("web.zig").host;
const ws = @import("websocket");
pub const Airlock = @import("airlock.zig").Airlock;
pub const Conn = ws.Conn;

test {
    @import("std").testing.refAllDecls(@This());
}
