const std = @import("std");
const core = @import("core");
const cfg = core.Config.Combat;
const log = std.debug.print;

const Owner = u16;
var eventCount: u16 = 0;
const Event = struct {
    id: u16,
    owner: Owner,
    start: core.Seconds,
    end: core.Seconds,
};

fn eventCmp(_: void, a: Event, b: Event) std.math.Order {
    return std.math.order(a.end, b.end);
}

const Action = struct {
    id: u16,
    invoke: *fn (Event, Action) void,
};

pub const State = struct {
    alloc: std.mem.Allocator,
    positions: std.ArrayList(core.Point),
    actions: std.AutoHashMap(Owner, Action),
    events: std.PriorityQueue(Event, void, eventCmp),
    now: core.Seconds,

    pub fn init(alloc: std.mem.Allocator) !*State {
        const self = try alloc.create(State);
        self.* = .{
            .alloc = alloc,
            .positions = std.ArrayList(core.Point).init(alloc),

            .actions = std.AutoHashMap(Owner, Action).init(alloc),
            .events = std.PriorityQueue(Event, void, eventCmp).init(alloc, undefined),
            .now = 0,
        };
        return self;
    }

    pub fn deinit(self: *State) void {
        self.positions.deinit();
        self.actions.deinit();
        self.events.deinit();
        self.alloc.destroy(self);
    }

    pub fn step(self: *State, dt: core.Seconds) void {
        self.now += dt;
        while (self.events.peek()) |evt| {
            if (evt.end < self.now) break;
            _ = self.events.remove();
            var act = self.actions.get(evt.owner) orelse continue;
            if (act.id != evt.id) continue;
            _ = self.actions.remove(evt.owner);
            act.invoke(evt, act);
        }
    }

    pub fn startAction(self: *State, actor: Owner, act: Action, dur: core.Seconds) !void {
        const evt = Event{
            .id = eventCount,
            .owner = actor,
            .start = self.now,
            .end = self.now + dur,
        };
        eventCount += 1;
        try self.events.add(evt);
        try self.actions.put(actor, act);
    }
};
