const std = @import("std");
const core = @import("core");
const zts = core.zts;
const Packet = struct { recipient: usize, body: []const u8 };

fn getSource(outbound: core.sig.Outbound) usize {
    return switch (outbound) {
        .Message => |v| v.source,
        .PosUpdate => |v| v.source,
    };
}

pub fn flush(parent: std.mem.Allocator) !OutIter {
    var outb = &core.bus.outbound;
    // Theoretical maximum allocated memory would be largest possible outbound message * static fifo size.
    // If we clip it to a reasonable packet frame, it would be about 4KiB per msg * 1024 = 4MiB,
    // so 16MiB per game frame should be very conservative.
    var alloc = std.heap.ArenaAllocator.init(parent);
    const a = alloc.allocator();
    var it = try outb.flush();
    var pending = std.ArrayList(core.sig.Outbound).init(a);
    while (it.next()) |msg_ptr| try pending.append(msg_ptr.*);

    // TODO this needs to turn into actual recipients..
    std.sort.block(core.sig.Outbound, pending.items, {}, struct {
        pub fn less(_: void, lhs: core.sig.Outbound, rhs: core.sig.Outbound) bool {
            return getSource(lhs) < getSource(rhs);
        }
    }.less);
    var i: usize = 0;
    const slice = pending.items;
    var packets = std.ArrayList(Packet).init(a);
    while (i < slice.len) {
        const rid = getSource(slice[i]);
        var j = i;
        while (j < slice.len and getSource(slice[j]) == rid) : (j += 1) {}
        var lines = std.ArrayList([]const u8).init(a);
        for (slice[i..j]) |out| {
            const line = switch (out) {
                .Message => |msg| msg.text,
                .PosUpdate => return error.NotYetImplemented,
            };
            try lines.append(line);
        }

        const body = try std.json.stringifyAlloc(a, .{ .msgs = lines.items }, .{});
        try packets.append(.{ .recipient = rid, .body = body });

        i = j;
    }
    return .{ .alloc = alloc, .list = packets, .idx = 0 };
}

pub const OutIter = struct {
    alloc: std.heap.ArenaAllocator,
    list: std.ArrayList(Packet),
    idx: usize,

    pub fn next(self: *OutIter) ?Packet {
        if (self.idx == self.list.items.len) {
            _ = self.alloc.reset(.free_all);
            return null;
        }
        const pkt = self.list.items[self.idx];
        self.idx += 1;
        return pkt;
    }
};

test "flush assembles correct json packets by recipient and empty outbox" {
    var outb = &core.bus.outbound;
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const ally = gpa.allocator();
    var it = try flush(ally);
    try std.testing.expectEqual(null, it.next());

    // collect packets so we can assert without caring order
    var got1 = false;
    var got2 = false;
    try outb.append(.{ .Message = .{ .source = 1, .text = "foo" } });
    try outb.append(.{ .Message = .{ .source = 1, .text = "bar" } });
    try outb.append(.{ .Message = .{ .source = 2, .text = "baz" } });

    var iter2 = try flush(ally);
    while (iter2.next()) |pkt| {
        var parsed = std.json.parseFromSlice(
            struct { msgs: []const []const u8 },
            ally,
            pkt.body,
            .{},
        ) catch unreachable;
        defer parsed.deinit();

        if (pkt.recipient == 1) {
            got1 = true;
            try std.testing.expectEqualStrings("foo", parsed.value.msgs[0]);
            try std.testing.expectEqualStrings("bar", parsed.value.msgs[1]);
            try std.testing.expectEqual(@as(usize, 2), parsed.value.msgs.len);
        } else if (pkt.recipient == 2) {
            got2 = true;
            try std.testing.expectEqualStrings("baz", parsed.value.msgs[0]);
            try std.testing.expectEqual(@as(usize, 1), parsed.value.msgs.len);
        } else {
            try std.testing.expect(false);
        }
    }

    try std.testing.expect(got1 and got2);
    // outbox should now be empty
    try std.testing.expectEqual(@as(usize, 0), outb.count);
}
