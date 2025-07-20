const std = @import("std");
const net = @import("net");
const db = @import("db.zig");
const State = @import("state.zig").State;
const cfg = @import("core").Config;
const zts = @import("core").zts;

const tmpl = @embedFile("foobar.txt");

pub fn main() !void {
    std.log.info(zts.s(tmpl, "foo"), .{"daytime"});
    std.log.info(zts.s(tmpl, "bar"), .{"nighttime"});
    var gpa = std.heap.DebugAllocator(.{ .thread_safe = true }){};
    const alloc = gpa.allocator();
    defer _ = gpa.deinit();

    // try db.doQueries(alloc);

    var http = try std.Thread.spawn(.{}, net.host_http, .{alloc});
    defer http.join();

    const state = try State.init(alloc);

    var ws = try std.Thread.spawn(.{}, net.host_ws, .{ State, alloc, state });
    defer ws.join();
    const tick: f64 = 1.0 / cfg.tps;
    const tick_ns = @as(u64, @intFromFloat(tick * 1e9));
    while (true) {
        try state.step(tick);
        std.Thread.sleep(tick_ns);
    }
}
