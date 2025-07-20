const std = @import("std");
const core = @import("core");
const move = @import("sys").move;
const ws = @import("websocket");
const sys = @import("sys");
const Channel = core.Channel(core.Command, std.math.pow(usize, 2, 10));

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

    positions: std.ArrayList(core.Point),
    level: move.Level,
    actions: std.AutoHashMap(usize, Action),
    events: std.PriorityQueue(Event, void, eventCmp),
    now: core.Seconds,

    conns: std.AutoHashMap(usize, *ws.Conn),
    channel: Channel,

    pub fn init(alloc: std.mem.Allocator) !*State {
        const self = try alloc.create(State);
        self.* = .{
            .alloc = alloc,

            .positions = std.ArrayList(core.Point).init(alloc),
            .actions = std.AutoHashMap(usize, Action).init(alloc),
            .events = std.PriorityQueue(Event, void, eventCmp).init(alloc, undefined),
            .now = 0,
            .level = move.Level.initStatic(alloc),
            .conns = std.AutoHashMap(usize, *ws.Conn).init(alloc),
            .channel = Channel{},
        };

        return self;
    }

    pub fn deinit(self: *State) void {
        self.positions.deinit();
        self.actions.deinit();
        self.events.deinit();
        self.conns.deinit();
        self.alloc.destroy(self);
    }

    pub fn step(self: *State, dt: core.Seconds) !void {
        self.now += dt;
        // Pull messages off the queue.
        for (self.channel.flip()) |cmd| {
            defer self.alloc.free(cmd.text);
            sys.parse(cmd);
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
