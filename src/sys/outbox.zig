const std = @import("std");
const core = @import("core");
const zts = core.zts;
const ParseError = @import("parse.zig").ParseError;

const err_tmpl = @embedFile("errors.txt");
const Outbound = struct { recipient: usize, txt: []const u8 };
const Packet = struct { recipient: usize, body: []const u8 };

pub const System = struct {
    alloc: std.mem.Allocator,
    outbox: std.ArrayList(Outbound),
    pub fn init(alloc: std.mem.Allocator) !System {
        return .{
            .alloc = alloc,
            .outbox = std.ArrayList(Outbound).init(alloc),
        };
    }
    pub fn deinit(self: *System) void {
        self.outbox.deinit();
    }
    pub fn handle_parse_err(self: *System, req: core.Request, err: ParseError) void {
        const txt = switch (err) {
            error.UnknownVerb => std.fmt.allocPrint(
                self.alloc,
                zts.s(
                    err_tmpl,
                    "UnknownVerb",
                ),
                .{},
            ) catch unreachable,
            else => std.fmt.allocPrint(
                self.alloc,
                zts.s(
                    err_tmpl,
                    "Unknown",
                ),
                .{},
            ) catch unreachable,
        };
        self.outbox.append(.{ .recipient = req.user, .txt = txt }) catch unreachable;
    }

    pub fn flush(self: *System) !OutIter {
        var map = std.AutoHashMap(usize, std.ArrayList([]const u8)).init(self.alloc);
        defer map.deinit();
        defer self.outbox.clearRetainingCapacity();
        for (self.outbox.items) |m| {
            const sliceList = std.ArrayList([]const u8).init(self.alloc);
            const list = try map.getOrPutValue(m.recipient, sliceList);
            try list.value_ptr.*.append(m.txt);
        }
        var packets = std.ArrayList(Packet).init(self.alloc);
        var it = map.iterator();
        while (it.next()) |entry| {
            const recipient = entry.key_ptr.*;
            const msgs_list = entry.value_ptr.*;
            const body = try std.json.stringifyAlloc(self.alloc, .{ .msgs = msgs_list.items }, .{});
            try packets.append(.{ .recipient = recipient, .body = body });
            msgs_list.deinit();
        }
        for (self.outbox.items) |m| self.alloc.free(m.txt);
        return .{ .alloc = self.alloc, .list = packets, .idx = 0 };
    }

    pub const OutIter = struct {
        alloc: std.mem.Allocator,
        list: std.ArrayList(Packet),
        idx: usize,

        pub fn next(self: *OutIter) ?Packet {
            if (self.idx > 0) {
                self.alloc.free(self.list.items[self.idx - 1].body);
            }
            if (self.idx >= self.list.items.len) {
                self.list.deinit();
                return null;
            }
            const pkt = self.list.items[self.idx];
            self.idx += 1;
            return pkt;
        }
    };
};

fn t_reqs(user: usize) core.Request {
    return .{ .user = user, .text = "" };
}

test "flush groups by recipient then empties outbox, JSON list is correct" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const A = gpa.allocator();

    var sys = try System.init(A);
    defer sys.deinit();

    // enqueue three errors: two for user 1, one for user 2
    sys.handle_parse_err(t_reqs(1), ParseError.UnknownVerb);
    sys.handle_parse_err(t_reqs(1), ParseError.SaidNothing);
    sys.handle_parse_err(t_reqs(2), ParseError.NotYetImplemented);

    var it = try sys.flush();

    // collect packets so we can assert without caring order
    var got1 = false;
    var got2 = false;

    while (it.next()) |pkt| {
        var parsed = std.json.parseFromSlice(
            struct { msgs: []const []const u8 },
            A,
            pkt.body,
            .{},
        ) catch unreachable;
        defer parsed.deinit();

        if (pkt.recipient == 1) {
            got1 = true;
            try std.testing.expectEqual(@as(usize, 2), parsed.value.msgs.len);
        } else if (pkt.recipient == 2) {
            got2 = true;
            try std.testing.expectEqual(@as(usize, 1), parsed.value.msgs.len);
        } else unreachable;
    }

    try std.testing.expect(got1 and got2);
    // outbox should now be empty
    try std.testing.expectEqual(@as(usize, 0), sys.outbox.items.len);
}
