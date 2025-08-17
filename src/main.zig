const std = @import("std");
const net = @import("net");
const db = @import("db.zig");
const State = @import("state.zig").State;
const cfg = @import("core").Config;

pub fn main() !void {
    var gpa = std.heap.DebugAllocator(.{ .thread_safe = true }){};
    const alloc = gpa.allocator();
    defer _ = gpa.deinit();

    const echo_mode = true;

    if (echo_mode) {
        std.log.info("Hosting in echo mode. Good luck!", .{});
        var ws = try std.Thread.spawn(.{}, net.host_ws, .{alloc});
        defer ws.join();
        while (true) std.Thread.sleep(60 * 1_000_000_000);
    } else {
        // TODO Merge websocket thread into the below. http workers should also perform work on ws frames
        var http = try std.Thread.spawn(.{}, net.host_http, .{alloc});
        defer http.join();

        var state = try State.init(alloc);
        var ws = try std.Thread.spawn(.{}, net.host_ws, .{alloc});
        defer ws.join();

        const tick: f64 = 1.0 / cfg.tps;
        const tick_ns = @as(u64, @intFromFloat(tick * 1e9));
        while (true) {
            try state.step(tick);
            std.Thread.sleep(tick_ns);
        }
    }
}
