const std = @import("std");
const core = @import("core");
const sig = core.sig;
const net = @import("net");
const move = @import("move.zig");
const VIEW_RADIUS: usize = 7; // tweak later

pub fn canSee(a: core.Position, b: core.Position) bool {
    return a.lvl_key == b.lvl_key and @max(a.x, b.x) - @min(a.x, b.x) <= VIEW_RADIUS and @max(a.y, b.y) - @min(a.y, b.y) <= VIEW_RADIUS;
}

pub fn step() void {
    var it = core.bus.move.flush() catch return;

    while (it.next()) |mv_ptr| {
        const mv = mv_ptr.*;
        const this = mv.source;

        for (move.list()) |that| {
            if (this == that) continue;
            const that_pos = move.get(that) catch unreachable;
            const was_vis = canSee(mv.move_from, that_pos);
            const now_vis = canSee(mv.move_to, that_pos);

            if (was_vis == now_vis) continue;

            if (now_vis) {
                core.bus.enqueue(sig.Signal{ .Outbound = .{
                    .EntityInSight = .{
                        .to = that,
                        .subj = this,
                        .x = mv.move_to.x,
                        .y = mv.move_to.y,
                    },
                } }) catch continue;
                core.bus.enqueue(sig.Signal{ .Outbound = .{
                    .EntityInSight = .{
                        .to = this,
                        .subj = that,
                        .x = that_pos.x,
                        .y = that_pos.y,
                    },
                } }) catch continue;
            } else { // lost sight of each other
                core.bus.enqueue(sig.Signal{ .Outbound = .{
                    .EntityOutOfSight = .{
                        .to = that,
                        .subj = this,
                    },
                } }) catch continue;
                core.bus.enqueue(sig.Signal{ .Outbound = .{
                    .EntityOutOfSight = .{
                        .to = this,
                        .subj = that,
                    },
                } }) catch continue;
            }
        }

        // _ = core.bus.enqueue(ev_ptr.*, mv.source) catch {};
        // const dest = @field(ev_ptr.*, "source");
        // _ = core.bus.enqueue(ev_ptr.*, dest) catch {};
    }
}

test "sight.step emits symmetrical In/Out events" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const A = gpa.allocator();

    try move.init(A);
    defer move.deinit();

    try move.place(1, .{ .lvl_key = 0, .x = 0, .y = 0 });
    try move.place(2, .{ .lvl_key = 0, .x = 8, .y = 0 });

    try core.bus.enqueue(.{ .Move = .{
        .source = 2,
        .move_from = .{ .lvl_key = 0, .x = 8, .y = 0 },
        .move_to = .{ .lvl_key = 0, .x = 7, .y = 0 },
    } });

    step();
    {
        var out_iter = try core.bus.outbound.flush();
        var seen_a = false;
        var seen_b = false;
        while (out_iter.next()) |outb| switch (outb.*) {
            .EntityInSight => |v| {
                if (v.to == 1 and v.subj == 2) seen_a = true;
                if (v.to == 2 and v.subj == 1) seen_b = true;
            },
            .PosUpdate => |v| try std.testing.expectEqual(2, v.to),
            else => unreachable,
        };
        try std.testing.expect(seen_a and seen_b);
    }

    // move back east out of view
    try core.bus.enqueue(.{ .Move = .{
        .source = 2,
        .move_from = .{ .lvl_key = 0, .x = 7, .y = 0 },
        .move_to = .{ .lvl_key = 0, .x = 8, .y = 0 },
    } });

    step();
    {
        var out_iter = try core.bus.outbound.flush();
        var lost_a = false;
        var lost_b = false;
        while (out_iter.next()) |outb| switch (outb.*) {
            .EntityOutOfSight => |e| {
                if (e.to == 1 and e.subj == 2) lost_a = true;
                if (e.to == 2 and e.subj == 1) lost_b = true;
            },
            .PosUpdate => |p| try std.testing.expectEqual(2, p.to),
            else => unreachable,
        };
        try std.testing.expect(lost_a and lost_b);
    }
}
