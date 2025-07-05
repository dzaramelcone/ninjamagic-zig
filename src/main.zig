const std = @import("std");
const host_ws = @import("net").host_ws;
const host_http = @import("net").host_http;
const db = @import("db.zig");
const State = @import("state.zig").State;
const cfg = @import("core").Config;

pub fn main() !void {
    var gpa = std.heap.DebugAllocator(.{ .thread_safe = true }){};
    const alloc = gpa.allocator();
    defer _ = gpa.deinit();

    try db.doQueries(alloc);

    var http = try std.Thread.spawn(.{}, host_http, .{alloc});
    defer http.join();

    var ws = try std.Thread.spawn(.{}, host_ws, .{alloc});
    defer ws.join();

    var state = try State.init(alloc);
    defer state.deinit();
    const tick: f64 = 1.0 / cfg.tps;
    const tick_ns = @as(u64, @intFromFloat(tick * 1e9));
    while (true) {
        state.step(tick);
        std.Thread.sleep(tick_ns);
    }
}
