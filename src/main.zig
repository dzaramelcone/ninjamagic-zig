const std = @import("std");
const net = @import("net");
const db = @import("db.zig");
const State = @import("state.zig").State;
const cfg = @import("core").Config;

fn asState(ctx: *anyopaque) *State {
    return @ptrCast(@alignCast(ctx));
}
fn ws_onConnect(ctx: *anyopaque, id: usize, conn: *net.Conn) anyerror!void {
    try asState(ctx).onConnect(id, conn);
}
fn ws_onDisconnect(ctx: *anyopaque, id: usize) void {
    asState(ctx).onDisconnect(id);
}
fn ws_onMessage(ctx: *anyopaque, id: usize, msg: []const u8) anyerror!void {
    try asState(ctx).onMessage(id, msg);
}
pub fn main() !void {
    var gpa = std.heap.DebugAllocator(.{ .thread_safe = true }){};
    const alloc = gpa.allocator();
    defer _ = gpa.deinit();

    var http = try std.Thread.spawn(.{}, net.host_http, .{alloc});
    defer http.join();

    var state = try State.init(alloc);
    const state_ptr = &state;

    const handler = net.WsHandler{
        .ctx = state_ptr,
        .onConnect = ws_onConnect,
        .onDisconnect = ws_onDisconnect,
        .onMessage = ws_onMessage,
    };

    var ws = try std.Thread.spawn(.{}, net.host_ws, .{ alloc, &handler });
    defer ws.join();

    const tick: f64 = 1.0 / cfg.tps;
    const tick_ns = @as(u64, @intFromFloat(tick * 1e9));
    while (true) {
        try state.step(tick);
        std.Thread.sleep(tick_ns);
    }
}
