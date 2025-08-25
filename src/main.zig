const std = @import("std");
const net = @import("net/module.zig");
const db = @import("db.zig");
const State = @import("state.zig").State;
const cfg = @import("core/Config.zig").Config;
const zts = @import("core/module.zig").zts;
const zqlite = @import("zqlite");

pub fn main() !void {
    var gpa = std.heap.DebugAllocator(.{ .thread_safe = true }){};
    const alloc = gpa.allocator();
    defer _ = gpa.deinit();

    const pool_ptr = try zqlite.Pool.init(alloc, cfg.Zqlite);
    defer pool_ptr.deinit();

    var http = try std.Thread.spawn(.{}, net.host_http, .{alloc});
    defer http.join();
    var state = try State.init(alloc);
    const state_ptr = &state;

    var ws = try std.Thread.spawn(.{}, net.host_ws, .{ State, alloc, pool_ptr, state_ptr });
    defer ws.join();
    const tick: f64 = 1.0 / cfg.tps;
    const tick_ns = @as(u64, @intFromFloat(tick * 1e9));
    while (true) {
        try state.step(tick);
        std.Thread.sleep(tick_ns);
    }
}
