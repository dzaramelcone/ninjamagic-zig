const std = @import("std");
const core = @import("core");
const sig = core.sig;

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
    on_execute: sig.Signal,
};

pub fn startAction(actor: usize, act: Action, now: core.Seconds, dur: core.Seconds) void {
    const evt = Event{
        .id = counter,
        .owner = actor,
        .start = now,
        .end = now + dur,
    };
    counter += 1;
    events.add(evt) catch @panic("OOM");
    actions.put(actor, act) catch @panic("OOM");
}

var actions: std.AutoArrayHashMap(usize, Action) = undefined;
var events: std.PriorityQueue(Event, void, eventCmp) = undefined;

pub fn init(alloc: std.mem.Allocator) void {
    actions = std.AutoArrayHashMap(usize, Action).init(alloc);
    events = std.PriorityQueue(Event, void, eventCmp).init(alloc, undefined);
}

pub fn deinit() void {
    actions.deinit();
    events.deinit();
}

pub fn step(now: core.Seconds) void {
    while (events.peek()) |evt| {
        if (evt.end > now) break;
        const act = actions.get(evt.owner) orelse continue;
        if (act.id != evt.id) continue;
        defer _ = actions.swapRemove(evt.owner);
        defer _ = events.remove();

        core.bus.enqueue(act.on_execute) catch break;
    }
}

test "single event fires at end time" {
    init(std.testing.allocator);
    defer deinit();

    // schedule action that should fire at t = 10
    const now: core.Seconds = 0;
    startAction(
        1,
        .{
            .id = 0,
            .on_execute = .{
                .Attack = .{
                    .source = 0,
                    .target = 1,
                },
            },
        },
        now,
        10,
    );

    // before end, nothing fired
    step(9);
    {
        var it = try core.bus.attack.flush();
        try std.testing.expectEqual(@as(?*sig.Attack, null), it.next());
    }

    // at end, signal fired
    step(10);
    {
        var it = try core.bus.attack.flush();
        const s = it.next() orelse unreachable;
        try std.testing.expectEqualDeep(
            sig.Attack{ .source = 0, .target = 1 },
            s.*,
        );
        try std.testing.expectEqual(@as(?*sig.Attack, null), it.next());
    }
}
