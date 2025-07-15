pub const host_ws = @import("websocket.zig").host;
pub const host_http = @import("web.zig").host;
const ws = @import("websocket");

pub const Deps = @import("websocket.zig").Deps;
pub const Conn = ws.Conn;
