//! Global game state and tick orchestrator.
const std = @import("std");
const core = @import("core/module.zig");
const sys = @import("sys/module.zig");
const ws = @import("websocket");

const Channel = core.Channel(core.sig.Signal, std.math.pow(usize, 2, 10));

pub const State = struct {
    alloc: std.mem.Allocator,
    now: core.Seconds,
    channel: Channel,

    pub fn init(alloc: std.mem.Allocator) !State {
        sys.client.init(alloc);
        try sys.move.init(alloc);
        sys.act.init(alloc);

        return .{
            .alloc = alloc,
            .now = 0,
            .channel = Channel{},
        };
    }

    pub fn deinit(_: *State) void {
        sys.act.deinit();
        sys.move.deinit();
        sys.client.deinit();
    }

    /// Advance the simulation by one frame.
    /// Drains inbound signals, steps each system, then flushes outbound packets.
    pub fn step(self: *State, dt: core.Seconds) !void {
        self.now += dt;
        var arena_allocator = std.heap.ArenaAllocator.init(self.alloc);
        defer arena_allocator.deinit();
        const arena = arena_allocator.allocator();
        // Pull messages off the queue.
        for (self.channel.flip()) |sig| {
            core.bus.enqueue(sig) catch continue;
        }
        // Update client list.
        sys.client.step();

        // Handle actions.
        sys.act.step(self.now);

        // Handle moves.
        sys.move.step();

        // Update LOS.
        sys.sight.step();

        // Emit messages.
        try sys.emit.step(arena);

        // Send all pending packets to clients.
        var it = try sys.outbox.flush(arena);
        while (it.next()) |pkt| {
            const conn = sys.client.get(pkt.recipient) orelse continue;
            try conn.write(pkt.body);
        }
    }

    pub fn onMessage(self: *State, user: usize, msg: []const u8) !void {
        const sig = sys.parser.parse(.{ .user = user, .text = msg }) catch return;
        if (!self.channel.push(sig)) return error.ServerBacklogged;
    }

    pub fn onConnect(self: *State, id: usize, c: *ws.Conn) !void {
        if (!self.channel.push(.{ .Connect = .{
            .source = id,
            .conn = c,
        } })) return error.ServerBacklogged;
    }

    pub fn onDisconnect(self: *State, id: usize) void {
        while (!self.channel.push(.{ .Disconnect = .{ .source = id } })) std.atomic.spinLoopHint();
    }

    pub fn broadcast(_: *State, text: []const u8) !void {
        var it = sys.client.iter();
        while (it.next()) |kv| {
            const id = kv.key_ptr.*;
            const conn = kv.value_ptr.*;
            std.log.debug("sending to user={d}: {s}", .{ id, text });
            conn.write(text) catch |err| std.log.err("ws write: {s}", .{@errorName(err)});
        }
    }
};

test "state.zig: connect and disconnect update client registry" {
    var s = try State.init(std.testing.allocator);
    defer s.deinit();
    var mock = ws.Conn{ ._closed = false, .started = 0, .stream = undefined, .address = undefined };

    try s.onConnect(42, &mock);
    try s.step(0.01);
    try std.testing.expect(sys.client.get(42) != null);

    s.onDisconnect(42);
    try s.step(0.01);
    try std.testing.expect(sys.client.get(42) == null);
}

test "state.zig: channel backpressure returns ServerBacklogged" {
    var s = try State.init(std.testing.allocator);
    defer s.deinit();
    var mock = ws.Conn{ ._closed = false, .started = 0, .stream = undefined, .address = undefined };

    var got_error = false;
    var i: usize = 0;
    while (i < 4096) : (i += 1) {
        const res = s.onConnect(i, &mock);
        if (res) |_| {
            // keep filling until it fails; do not drain via step()
        } else |_| {
            got_error = true;
            break;
        }
    }
    try std.testing.expect(got_error);
}

test "state.zig: onMessage enqueues and drains" {
    var s = try State.init(std.testing.allocator);
    defer s.deinit();
    try s.onMessage(1, "'hello world");
    try s.step(0.01);
    try std.testing.expect(s.channel.flip().len == 0);
}

const posix = std.posix;
const net = std.net;
const PipeConn = struct {
    read_fd: posix.fd_t,
    conn: ws.Conn,
};
fn makePipeConn() !PipeConn {
    const fds = try posix.pipe();
    const addr = try net.Address.parseIp("127.0.0.1", 0);
    return .{
        .read_fd = fds[0],
        .conn = ws.Conn{
            ._closed = false,
            .started = 0,
            .stream = .{ .handle = fds[1] },
            .address = addr,
        },
    };
}

test "state.zig: outbox writes to multiple connected clients" {
    var s = try State.init(std.testing.allocator);
    defer s.deinit();

    var a = try makePipeConn();
    defer posix.close(a.read_fd);
    var b = try makePipeConn();
    defer posix.close(b.read_fd);

    try s.onConnect(1, &a.conn);
    try s.onConnect(2, &b.conn);
    try s.step(0.01);

    // Enqueue multiple messages for 1 and one for 2; State.step will flush and write.
    try core.bus.enqueue(.{ .Outbound = .{ .Message = .{ .to = 1, .text = "foo" } } });
    try core.bus.enqueue(.{ .Outbound = .{ .Message = .{ .to = 1, .text = "bar" } } });
    try core.bus.enqueue(.{ .Outbound = .{ .Message = .{ .to = 2, .text = "baz" } } });

    try s.step(0.01);

    // Read frames from pipes and verify payload contents.
    var buf: [4096]u8 = undefined;
    const n1 = try posix.read(a.read_fd, &buf);
    try std.testing.expect(n1 > 0);
    // Very small payloads: expect single text frame: 0x81, len, payload
    try std.testing.expectEqual(@as(u8, 0x81), buf[0]);
    const len1: usize = buf[1];
    const payload1 = buf[2 .. 2 + len1];
    try std.testing.expect(std.mem.indexOf(u8, payload1, "foo") != null);
    try std.testing.expect(std.mem.indexOf(u8, payload1, "bar") != null);

    const n2 = try posix.read(b.read_fd, &buf);
    try std.testing.expect(n2 > 0);
    try std.testing.expectEqual(@as(u8, 0x81), buf[0]);
    const len2: usize = buf[1];
    const payload2 = buf[2 .. 2 + len2];
    try std.testing.expect(std.mem.indexOf(u8, payload2, "baz") != null);
}
