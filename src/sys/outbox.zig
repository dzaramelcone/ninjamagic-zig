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
        self.alloc.destroy(self);
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
        for (self.outbox.items) |m| {
            const list = try map.getOrPutValue(m.recipient, std.ArrayList([]const u8).init(self.alloc));
            try list.value_ptr.*.append(m.txt);
        }

        var packets = std.ArrayList(Packet).init(self.alloc);

        var it = map.iterator();
        while (it.next()) |entry| {
            const recipient = entry.key_ptr.*;
            const sliceLst = entry.value_ptr.*;
            var string = std.ArrayList(u8).init(self.alloc);
            var jw = std.json.writeStream(string.writer(), .{ .whitespace = .indent_2 });

            {
                try jw.beginObject();
                try jw.objectField("msgs");
                try jw.beginArray();
                for (sliceLst.items) |t| try jw.write(t);
                try jw.endArray();
                try jw.endObject();
            }
            const body = try string.toOwnedSlice();
            try packets.append(.{ .recipient = recipient, .body = body });

            // free per‑sender temp list
            sliceLst.deinit();
        }
        map.deinit();

        // 3. clear original message list
        for (self.outbox.items) |m| self.alloc.free(m.txt);
        self.outbox.clearRetainingCapacity();

        return .{ .alloc = self.alloc, .list = packets, .idx = 0 };
    }

    pub const OutIter = struct {
        alloc: std.mem.Allocator,
        list: std.ArrayList(Packet),
        idx: usize,

        pub fn next(self: *OutIter) ?Packet {
            if (self.idx >= self.list.items.len) {
                self.list.deinit();
                return null;
            }
            const pkt = self.list.items[self.idx];
            self.idx += 1;
            // free body afterwards
            defer self.alloc.free(pkt.body);
            return pkt;
        }
    };
};
