const std = @import("std");
const core = @import("../core/module.zig");
const zts = core.zts;
const Packet = struct { recipient: usize, body: []const u8 };

fn getRecipient(outbound: core.sig.Outbound) usize {
    return switch (outbound) {
        .Message => |v| v.to,
        .EntityInSight => |v| v.to,
        .PosUpdate => |v| v.to,
        .EntityOutOfSight => |v| v.to,
    };
}
const Payload = union(enum) {
    Msg: struct { m: []const u8 },
    Pos: struct { id: usize, x: usize, y: usize },
    See: struct { id: usize, x: usize, y: usize },
    Out: struct { id: usize },
};
fn structure(out: core.sig.Outbound) Payload {
    return switch (out) {
        .Message => |v| .{ .Msg = .{ .m = v.text } },
        .PosUpdate => |v| .{ .Pos = .{ .id = v.subj, .x = v.move_to.x, .y = v.move_to.y } },
        .EntityInSight => |v| .{ .See = .{ .id = v.subj, .x = v.x, .y = v.y } },
        .EntityOutOfSight => |v| .{ .Out = .{ .id = v.subj } },
    };
}

fn sort_sig_asc(_: void, lhs: core.sig.Outbound, rhs: core.sig.Outbound) bool {
    return getRecipient(lhs) < getRecipient(rhs);
}
// Theoretical maximum allocated memory would be largest possible outbound message * static fifo size.
// If we clip it to a reasonable packet frame, it would be about 4KiB per msg * 1024 = 4MiB,
// so 16MiB per frame should be very conservative.
pub fn flush(alloc: std.mem.Allocator) !OutIter {
    var outb = &core.bus.outbound;
    var it = try outb.flush();
    var pending = std.ArrayList(core.sig.Outbound).init(alloc);
    while (it.next()) |msg_ptr| pending.append(msg_ptr.*) catch @panic("OOM");

    std.sort.block(core.sig.Outbound, pending.items, {}, sort_sig_asc);
    var i: usize = 0;
    const slice = pending.items;
    var packets = std.ArrayList(Packet).init(alloc);
    while (i < slice.len) {
        const rid = getRecipient(slice[i]);
        var j = i;
        while (j < slice.len and getRecipient(slice[j]) == rid) : (j += 1) {}
        var msgs = std.ArrayList(Payload).init(alloc);
        for (slice[i..j]) |out| {
            msgs.append(structure(out)) catch @panic("OOM");
        }

        const body = std.json.stringifyAlloc(alloc, msgs.items, .{}) catch @panic("OOM");
        packets.append(.{ .recipient = rid, .body = body }) catch @panic("OOM");

        i = j;
    }
    return .{ .list = packets, .idx = 0 };
}

pub const OutIter = struct {
    list: std.ArrayList(Packet),
    idx: usize,

    pub fn next(self: *OutIter) ?Packet {
        if (self.idx == self.list.items.len) {
            return null;
        }
        const pkt = self.list.items[self.idx];
        self.idx += 1;
        return pkt;
    }
};
test "sys/outbox.zig: render compact JSON, bundle packets" {
    var arena_allocator = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_allocator.deinit();
    const arena = arena_allocator.allocator();

    try core.bus.enqueue(.{ .Outbound = .{ .Message = .{ .to = 1, .text = "foo" } } });
    try core.bus.enqueue(.{ .Outbound = .{ .Message = .{ .to = 1, .text = "bar" } } });
    try core.bus.enqueue(.{ .Outbound = .{ .Message = .{ .to = 2, .text = "baz" } } });

    var seen1 = false;
    var seen2 = false;

    var it = try flush(arena);
    while (it.next()) |pkt| {
        const env = try std.json.parseFromSlice([]const Payload, arena, pkt.body, .{});
        defer env.deinit();

        const msgs = env.value;
        switch (pkt.recipient) {
            1 => {
                seen1 = true;
                try std.testing.expectEqual(2, msgs.len);
                try std.testing.expectEqualStrings("foo", msgs[0].Msg.m);
                try std.testing.expectEqualStrings("bar", msgs[1].Msg.m);
            },
            2 => {
                seen2 = true;
                try std.testing.expectEqual(1, msgs.len);
                try std.testing.expectEqualStrings("baz", msgs[0].Msg.m);
            },
            else => try std.testing.expect(false),
        }
    }

    try std.testing.expect(seen1 and seen2);
    try std.testing.expectEqual(0, core.bus.outbound.count);
}
