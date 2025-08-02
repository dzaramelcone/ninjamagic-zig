const std = @import("std");
const core = @import("core");
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

fn encode(out: core.sig.Outbound, a: std.mem.Allocator) ![]const u8 {
    return try switch (out) {
        .Message => |v| std.json.stringifyAlloc(a, .{
            .t = "Msg",
            .d = .{ .m = v.text },
        }, .{}),
        .PosUpdate => |v| std.json.stringifyAlloc(a, .{
            .t = "Pos",
            .d = .{ .id = v.subj, .x = v.move_to.x, .y = v.move_to.y },
        }, .{}),
        .EntityInSight => |v| std.json.stringifyAlloc(a, .{
            .t = "See",
            .d = .{ .id = v.subj, .x = v.x, .y = v.y },
        }, .{}),
        .EntityOutOfSight => |v| std.json.stringifyAlloc(a, .{
            .t = "Out",
            .d = .{ .id = v.subj },
        }, .{}),
    };
}

fn sort_sig_asc(_: void, lhs: core.sig.Outbound, rhs: core.sig.Outbound) bool {
    return getRecipient(lhs) < getRecipient(rhs);
}
// Theoretical maximum allocated memory would be largest possible outbound message * static fifo size.
// If we clip it to a reasonable packet frame, it would be about 4KiB per msg * 1024 = 4MiB,
// so 16MiB per frame should be very conservative.
pub fn flush(parent: std.mem.Allocator) !OutIter {
    var outb = &core.bus.outbound;
    var alloc = std.heap.ArenaAllocator.init(parent);
    const a = alloc.allocator();
    var it = try outb.flush();
    var pending = std.ArrayList(core.sig.Outbound).init(a);
    while (it.next()) |msg_ptr| pending.append(msg_ptr.*) catch @panic("OOM");

    std.sort.block(core.sig.Outbound, pending.items, {}, sort_sig_asc);
    var i: usize = 0;
    const slice = pending.items;
    var packets = std.ArrayList(Packet).init(a);
    while (i < slice.len) {
        const rid = getRecipient(slice[i]);
        var j = i;
        while (j < slice.len and getRecipient(slice[j]) == rid) : (j += 1) {}
        var msgs = std.ArrayList([]const u8).init(a);
        for (slice[i..j]) |out| {
            const msg = encode(out, a) catch @panic("OOM");
            msgs.append(msg) catch @panic("OOM");
        }

        const body = std.json.stringifyAlloc(a, .{ .msgs = msgs.items }, .{}) catch @panic("OOM");
        packets.append(.{ .recipient = rid, .body = body }) catch @panic("OOM");

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

test "render compact JSON, bundle packets" {
    var outb = &core.bus.outbound;

    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const A = gpa.allocator();

    var it = try flush(A);
    _ = it.next();

    try outb.append(.{ .Message = .{ .to = 1, .text = "foo" } });
    try outb.append(.{ .Message = .{ .to = 1, .text = "bar" } });
    try outb.append(.{ .Message = .{ .to = 2, .text = "baz" } });

    var got1 = false;
    var got2 = false;

    var it2 = try flush(A);
    while (it2.next()) |pkt| {
        const envelope = try std.json.parseFromSlice(
            struct { msgs: []const []const u8 },
            A,
            pkt.body,
            .{},
        );
        defer envelope.deinit();

        const msgs = envelope.value.msgs;

        switch (pkt.recipient) {
            1 => {
                got1 = true;
                try std.testing.expectEqual(2, msgs.len);
                try expectMessage(A, msgs[0], "Msg", "foo");
                try expectMessage(A, msgs[1], "Msg", "bar");
            },
            2 => {
                got2 = true;
                try std.testing.expectEqual(1, msgs.len);
                try expectMessage(A, msgs[0], "Msg", "baz");
            },
            else => try std.testing.expect(false),
        }
    }

    try std.testing.expect(got1 and got2);
    try std.testing.expectEqual(0, outb.count);
}

fn expectMessage(alloc: std.mem.Allocator, raw: []const u8, wanted_type: []const u8, wanted: []const u8) !void {
    const m = try std.json.parseFromSlice(
        struct { t: []const u8, d: struct { m: []const u8 } },
        alloc,
        raw,
        .{},
    );
    defer m.deinit();

    try std.testing.expectEqualStrings(wanted_type, m.value.t);
    try std.testing.expectEqualStrings(wanted, m.value.d.m);
}
