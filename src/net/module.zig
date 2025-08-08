pub const host_ws = @import("websocket.zig").host;
pub const host_http = @import("web.zig").host;

pub const Conn = @import("websocket.zig").Conn;

test {
    @import("std").testing.refAllDecls(@This());
}
