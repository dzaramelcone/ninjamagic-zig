const std = @import("std");
const core = @import("core");
const sys = @import("sys");
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

    pub fn deinit(self: *State) void {
        self.alloc.destroy(self);
    }

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
