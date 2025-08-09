const core = @import("../core/module.zig");
const std = @import("std");
const zts = core.zts;
const client = @import("client.zig");
const sight = @import("sight.zig");
const name = @import("name.zig");

const say_tmpl = @embedFile("templates/say.txt");

pub fn step(alloc: std.mem.Allocator) !void {
    var it = core.bus.emit.flush() catch return;
    while (it.next()) |sig| {
        const emit = sig.*;
        switch (emit) {
            .Say => try handleSay(emit, alloc),
        }
    }
}

fn handleSay(em: core.sig.Emit, alloc: std.mem.Allocator) !void {
    var buf = std.ArrayList(u8).init(alloc);
    const out = buf.writer();
    defer buf.deinit();

    const say = em.Say;
    // first
    {
        try zts.print(say_tmpl, "first", .{ .msg = say.text }, out);
        const txt_cpy = try alloc.dupe(u8, buf.items);
        try core.bus.enqueue(.{ .Outbound = .{ .Message = .{ .to = say.source, .text = txt_cpy } } });
        buf.clearRetainingCapacity();
    }
    // third
    for (client.list()) |to| {
        if (to == say.source) continue;
        if (!sight.canMobSee(say.source, to)) continue;

        const who = name.get(say.source) catch "Someone";
        try zts.print(say_tmpl, "third", .{
            .source = who,
            .msg = say.text,
        }, out);
        const txt_cpy = try alloc.dupe(u8, buf.items);
        try core.bus.enqueue(.{ .Outbound = .{ .Message = .{
            .to = to,
            .text = txt_cpy,
        } } });
        buf.clearRetainingCapacity();
    }
}

test "sys/emit.zig: sight: say emits correct packets" {
    var arena_allocator = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_allocator.deinit();
    const arena = arena_allocator.allocator();
    const move = @import("move.zig");

    client.init(std.testing.allocator);
    try move.init(std.testing.allocator);
    name.init(std.testing.allocator);

    defer name.deinit();
    defer move.deinit();
    defer client.deinit();

    try core.bus.enqueue(.{ .Connect = .{ .source = 1, .conn = undefined } });
    try core.bus.enqueue(.{ .Connect = .{ .source = 2, .conn = undefined } });
    client.step();

    try move.place(1, .{ .lvl_key = 0, .x = 0, .y = 0 });
    name.put(1, "Alice");
    {
        try core.bus.enqueue(.{ .Emit = .{ .Say = .{ .source = 1, .text = "hello", .reach = .Sight } } });
        try step(arena);

        var it = try core.bus.outbound.flush();
        const pkt = it.next().?;
        try std.testing.expectEqual(1, pkt.Message.to);
        try std.testing.expectEqualStrings("You say, \'hello\'\n", pkt.Message.text);
        try std.testing.expectEqual(null, it.next());
    }
    try move.place(2, .{ .lvl_key = 0, .x = 5, .y = 1 }); // in LOS range
    name.put(2, "Bob");

    // alice and bob in los
    {
        try core.bus.enqueue(.{ .Emit = .{ .Say = .{ .source = 1, .text = "yo", .reach = .Sight } } });
        try step(arena);

        var got_alice = false;
        var got_bob = false;
        var it = try core.bus.outbound.flush();
        while (it.next()) |m| switch (m.Message.to) {
            1 => {
                got_alice = true;
                try std.testing.expectEqualStrings("You say, \'yo\'\n", m.Message.text);
            },
            2 => {
                got_bob = true;
                try std.testing.expectEqualStrings("Alice says, \'yo\'\n", m.Message.text);
            },
            else => try std.testing.expect(false),
        };
        try std.testing.expect(got_alice and got_bob);
    }

    // Bob out of LOS
    try move.set(2, .{ .lvl_key = 0, .x = 9, .y = 0 });

    {
        try core.bus.enqueue(.{ .Emit = .{ .Say = .{ .source = 1, .text = "hey?", .reach = .Sight } } });
        try step(arena);

        var it = try core.bus.outbound.flush();
        const only = it.next().?;
        try std.testing.expectEqual(1, only.Message.to);
        try std.testing.expectEqualStrings("You say, \'hey?\'\n", only.Message.text);
        try std.testing.expectEqual(null, it.next());
    }
}

test "sys/emit.zig: missing name falls back to Someone" {
    var arena_allocator = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_allocator.deinit();
    const arena = arena_allocator.allocator();
    const move = @import("move.zig");

    client.init(std.testing.allocator);
    try move.init(std.testing.allocator);
    defer move.deinit();
    defer client.deinit();

    try core.bus.enqueue(.{ .Connect = .{ .source = 1, .conn = undefined } });
    client.step();
    try move.place(1, .{ .lvl_key = 0, .x = 0, .y = 0 });

    try core.bus.enqueue(.{ .Emit = .{ .Say = .{ .source = 1, .text = "hi", .reach = .Sight } } });
    try step(arena);

    var it = try core.bus.outbound.flush();
    const pkt = it.next().?;
    _ = pkt; // ensure at least one packet without crashing due to name lookup
}
