const std = @import("std");
const core = @import("core");
const move = @import("sys").move;
const ws = @import("websocket");
const sys = @import("sys");
const Channel = core.Channel(core.Request, std.math.pow(usize, 2, 10));

var counter: usize = 0;
const Event = struct {
    id: usize,
    owner: usize,
    start: core.Seconds,
    end: core.Seconds,
};

fn eventCmp(_: void, a: Event, b: Event) std.math.Order {
    return std.math.order(a.end, b.end);
}

const Action = struct {
    id: usize,
    callback: *fn (Event, Action) void,
};

pub const State = struct {
    alloc: std.mem.Allocator,

    actions: std.AutoHashMap(usize, Action),
    events: std.PriorityQueue(Event, void, eventCmp),
    now: core.Seconds,

    conns: std.AutoHashMap(usize, *ws.Conn),
    channel: Channel,
    move: sys.move.System,

    outbox: sys.outbox.System,

    pub fn init(alloc: std.mem.Allocator) !State {
        return .{
            .alloc = alloc,

            .actions = std.AutoHashMap(usize, Action).init(alloc),
            .events = std.PriorityQueue(Event, void, eventCmp).init(alloc, undefined),
            .move = try sys.move.System.init(alloc),
            .now = 0,
            .conns = std.AutoHashMap(usize, *ws.Conn).init(alloc),
            .channel = Channel{},
            .outbox = try sys.outbox.System.init(alloc),
        };
    }

    pub fn deinit(self: *State) void {
        self.actions.deinit();
        self.events.deinit();
        self.conns.deinit();
        self.alloc.destroy(self);
    }

    pub fn step(self: *State, dt: core.Seconds) !void {
        self.now += dt;

        // Pull messages off the queue.
        for (self.channel.flip()) |req| {
            // goofy free coming off another thread. TODO: figure this out better
            defer self.alloc.free(req.text);

            // TODO: handle error, probably just an ErrorSignal that sends a msg with better feedback for user
            // can do zts s(err), add response text for each error type in errors.txt.
            const sig = sys.parser.parse(req) catch |err| {
                self.outbox.handle_parse_err(req, err);
                continue;
            };
            switch (sig) {
                .Walk => self.move.recv(sig),
                else => return error.NotYetImplemented,
            }
        }
        // Handle events.
        while (self.events.peek()) |evt| {
            if (evt.end < self.now) break;
            _ = self.events.remove();
            var act = self.actions.get(evt.owner) orelse continue;
            if (act.id != evt.id) continue;
            _ = self.actions.remove(evt.owner);
            act.callback(evt, act);
        }
        // Handle moves.
        try self.move.step();

        var it = try self.outbox.flush();
        while (it.next()) |pkt| {
            const conn = self.conns.get(pkt.recipient) orelse continue;
            try conn.write(pkt.body);
        }
    }

    pub fn startAction(self: *State, actor: usize, act: Action, dur: core.Seconds) !void {
        const evt = Event{
            .id = counter,
            .owner = actor,
            .start = self.now,
            .end = self.now + dur,
        };
        counter += 1;
        try self.events.add(evt);
        try self.actions.put(actor, act);
    }

    pub fn onMessage(self: *State, user: usize, msg: []const u8) !void {
        const buf = try self.alloc.dupe(u8, msg);
        if (!self.channel.push(.{ .user = user, .text = buf })) return error.ServerBacklogged;
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
