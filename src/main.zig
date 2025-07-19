const std = @import("std");
const net = @import("net");
const db = @import("db.zig");
const State = @import("state.zig").State;
const cfg = @import("core").Config;

pub fn main() !void {
    var gpa = std.heap.DebugAllocator(.{ .thread_safe = true }){};
    const allocator = gpa.allocator();
    defer _ = gpa.deinit();

    // try db.doQueries(alloc);

    var http = try std.Thread.spawn(.{}, net.host_http, .{allocator});
    defer http.join();

    const state = try State.init(allocator);

    var ws = try std.Thread.spawn(.{}, net.host_ws, .{ State, allocator, state });
    defer ws.join();
    const tick: f64 = 1.0 / cfg.tps;
    const tick_ns = @as(u64, @intFromFloat(tick * 1e9));
    while (true) {
        try state.step(tick);
        std.Thread.sleep(tick_ns);
    }
}
