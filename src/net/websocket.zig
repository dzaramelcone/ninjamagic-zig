const std = @import("std");
const ws = @import("websocket");
const zqlite = @import("zqlite");
const core = @import("../core/module.zig");
const Airlock = @import("airlock.zig").Airlock;

const cfg = core.Config;
const Phase = enum { Airlock, Session };
var alloc: std.mem.Allocator = undefined;
var pool_ptr: *zqlite.Pool = undefined;

pub fn host(comptime T: type, allocator: std.mem.Allocator, pool: *zqlite.Pool, impl: *T) !void {
    alloc = allocator;
    pool_ptr = pool;
    var server = try ws.Server(Handler(T)).init(allocator, cfg.Ws);
    defer server.deinit();
    try server.listen(impl);
}

pub const WsWriter = struct {
    conn: *ws.Conn,

    pub fn writeAll(self: WsWriter, bytes: []const u8) !void {
        try self.conn.writeText(bytes);
    }

    pub fn print(self: WsWriter, comptime fmt: []const u8, args: anytype) !void {
        var scratch: [256]u8 = undefined;
        var fbs = std.io.fixedBufferStream(&scratch);
        try fbs.writer().print(fmt, args);
        try self.writeAll(fbs.getWritten());
    }
};

pub fn Handler(comptime T: type) type {
    return struct {
        const Self = @This();
        impl: *T,
        conn: *ws.Conn,
        id: usize,

        phase: Phase = .Airlock,
        air: Airlock,

        pub fn init(h: *const ws.Handshake, conn: *ws.Conn, impl: *T) !Self {
            _ = h;
            return .{
                .impl = impl,
                .conn = conn,
                .id = core.getId(),
                .air = Airlock.init(alloc, pool_ptr),
            };
        }
        fn connWriter(self: *Self) WsWriter {
            return .{ .conn = self.conn };
        }
        pub fn deinit(self: *Self) void {
            if (self.phase == .Session) self.impl.onDisconnect(self.id);
        }

        pub fn clientMessage(self: *Self, raw: []const u8) !void {
            switch (self.phase) {
                .Airlock => {
                    switch (try self.air.onText(self.connWriter(), raw)) {
                        .Continue => return,
                        .Admit => {
                            self.id = core.getId();
                            self.phase = .Session;
                            try self.impl.onConnect(self.id, self.conn);
                            return;
                        },
                        .Close => self.close(),
                    }
                },
                .Session => {
                    self.impl.onMessage(self.id, raw) catch |err| try self.conn.write(@errorName(err));
                },
            }
        }

        pub fn close(self: *Self) void {
            self.impl.onDisconnect(self.id);
            self.conn.close(.{}) catch {};
            self.deinit();
        }
    };
}
