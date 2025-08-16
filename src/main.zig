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

    // Echo-only mode for Autobahn tests: set MUD_ECHO=1
    var echo_mode = false;
    if (std.process.getEnvVarOwned(alloc, "MUD_ECHO")) |val| {
        defer alloc.free(val);
        echo_mode = std.mem.eql(u8, std.mem.trim(u8, val, " \t\r\n"), "1");
    } else |_| {}

    if (echo_mode) {
        // Minimal WS echo host; skip HTTP and game state threads.
        const noop_handler = net.WsHandler{
            .ctx = undefined,
            .onConnect = struct { fn f(_: *anyopaque, _: usize, _: *net.Conn) anyerror!void { return; } }.f,
            .onDisconnect = struct { fn f(_: *anyopaque, _: usize) void {} }.f,
            .onMessage = struct { fn f(_: *anyopaque, _: usize, _: []const u8) anyerror!void { return; } }.f,
        };
        var ws = try std.Thread.spawn(.{}, net.host_ws, .{ alloc, &noop_handler });
        defer ws.join();
        // Park main thread indefinitely.
        while (true) std.Thread.sleep(60 * 1_000_000_000);
    } else {
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
}
