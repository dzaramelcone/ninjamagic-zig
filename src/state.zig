const std = @import("std");
const core = @import("core");
const sys = @import("sys");
const ws = @import("websocket");

const Channel = core.Channel(core.sig.Signal, std.math.pow(usize, 2, 10));

pub const State = struct {
    alloc: std.mem.Allocator,

    now: core.Seconds,

    conns: std.AutoHashMap(usize, *ws.Conn),
    channel: Channel,

    pub fn init(alloc: std.mem.Allocator) !State {
        try sys.move.init(alloc);
        sys.act.init(alloc);
        return .{
            .alloc = alloc,
            .now = 0,
            .conns = std.AutoHashMap(usize, *ws.Conn).init(alloc),
            .channel = Channel{},
        };
    }

    pub fn deinit(self: *State) void {
        self.conns.deinit();
        self.alloc.destroy(self);
    }

    pub fn step(self: *State, dt: core.Seconds) !void {
        self.now += dt;

        // Pull messages off the queue.
        for (self.channel.flip()) |sig| {
            try core.bus.enqueue(sig);
        }
        // Handle actions.
        try sys.act.step(self.now);

        // Handle moves.
        try sys.move.step();

        // Send all pending packets to clients.
        var it = try sys.outbox.flush(self.alloc);
        while (it.next()) |pkt| {
            const conn = self.conns.get(pkt.recipient) orelse continue;
            try conn.write(pkt.body);
        }
    }

    pub fn onMessage(self: *State, user: usize, msg: []const u8) !void {
        const sig = sys.parser.parse(.{ .user = user, .text = msg }) catch |err| {
            switch (err) {
                error.NothingSent => return,
                else => try self.conns.get(user).?.write(sys.parser.toPlayer(err)),
            }
            return;
        };
        if (!self.channel.push(sig)) return error.ServerBacklogged;
    }

    pub fn onConnect(self: *State, id: usize, c: *ws.Conn) !void {
        try self.conns.put(id, c);
    }

    pub fn onDisconnect(self: *State, id: usize) void {
        if (self.conns.remove(id)) std.log.debug("{d} disconnected.", .{id});
    }

    pub fn broadcast(self: *State, text: []const u8) !void {
        var it = self.conns.iterator();
        while (it.next()) |kv| {
            const id = kv.key_ptr.*;
            const conn = kv.value_ptr.*;
            std.log.debug("sending to user={d}: {s}", .{ id, text });
            conn.write(text) catch |err| std.log.err("ws write: {s}", .{@errorName(err)});
        }
    }
};
