const std = @import("std");
const net = @import("net");
const db = @import("db.zig");
const State = @import("state.zig").State;
const cfg = @import("core").Config;
const zts = @import("core").zts;

pub fn main() !void {
    var gpa = std.heap.DebugAllocator(.{ .thread_safe = true }){};
    const alloc = gpa.allocator();
    defer _ = gpa.deinit();

    // try db.doQueries(alloc);

    var http = try std.Thread.spawn(.{}, net.host_http, .{alloc});
    defer http.join();
    var state = try State.init(alloc);
    const state_ptr = &state;

    var ws = try std.Thread.spawn(.{}, net.host_ws, .{ State, alloc, state_ptr });
    defer ws.join();
    const tick: f64 = 1.0 / cfg.tps;
    const tick_ns = @as(u64, @intFromFloat(tick * 1e9));
    while (true) {
        try state.step(tick);
        std.Thread.sleep(tick_ns);
    }
}
