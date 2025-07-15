const std = @import("std");
const net = @import("net");
const db = @import("db.zig");
const State = @import("state.zig").State;
const cfg = @import("core").Config;
var state: *State = undefined;

const Dep = struct {
    pub fn onPacket(id: usize, txt: []u8) void {
        state.onPacket(id, txt);
    }
    pub fn onConnect(id: usize, c: *net.Conn) void {
        state.onConnect(id, c);
    }
    pub fn onClose(id: usize) void {
        state.onClose(id);
    }
};
pub fn main() !void {
    var gpa = std.heap.DebugAllocator(.{ .thread_safe = true }){};
    const alloc = gpa.allocator();
    defer _ = gpa.deinit();

    try db.doQueries(alloc);

    var http = try std.Thread.spawn(.{}, net.host_http, .{alloc});
    defer http.join();

    state = try State.init(alloc);
    defer state.deinit();
    var deps = net.Deps{
        .alloc = alloc,
        .pushInbound = Dep.onPacket,
        .registerClient = Dep.onConnect,
        .unregister = Dep.onClose,
    };
    var ws = try std.Thread.spawn(.{}, net.host_ws, .{&deps});
    defer ws.join();
    const tick: f64 = 1.0 / cfg.tps;
    const tick_ns = @as(u64, @intFromFloat(tick * 1e9));
    while (true) {
        state.step(tick);
        std.Thread.sleep(tick_ns);
    }
}
