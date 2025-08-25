const std = @import("std");
const zqlite = @import("zqlite");
const models = @import("../db/sqlc-out/models.zig");
const db = @import("../db/sqlc-out/queries.sql.zig");

const SZ = 16;
const format =
    \\[{{"Msg":{{"m":"{s}"}}}}]
;
/// This is a placeholder until oauth is setup.
pub const Airlock = struct {
    const Self = @This();
    const State = enum { AskName, AskSecret, ConfirmCreate, SetSecret };
    fsm: State = .AskName,

    buf: [SZ * 2]u8 = undefined,
    name: []const u8 = undefined,
    secret: []const u8 = undefined,
    fails: u8 = 0,

    q: db.PoolQuerier,

    pub fn init(allocator: std.mem.Allocator, pool: *zqlite.Pool) Airlock {
        return .{
            .q = db.PoolQuerier.init(
                allocator,
                pool,
            ),
        };
    }

    pub fn onText(self: *Self, writer: anytype, raw: []const u8) !enum { Continue, Admit, Close } {
        const text = std.mem.trim(u8, raw, " \t\r\n");
        if (text.len == 0) return .Continue;

        switch (self.fsm) {
            .AskName => {
                if (text.len < 3) {
                    try writer.print(format, .{"Too short.\nUsername:"});
                    return .Continue;
                }
                if (text.len >= SZ) {
                    try writer.print(format, .{"Too long.\nUsername:"});
                    return .Continue;
                }
                for (text) |c| if (!std.ascii.isAlphabetic(c)) {
                    try writer.print(format, .{"Letters only.\nUsername:"});
                    return .Continue;
                };
                self.name = std.ascii.lowerString(self.buf[0..text.len], text);
                self.buf[0] = std.ascii.toUpper(self.buf[0]);
                const u = self.q.getUserByName(self.name) catch |e| switch (e) {
                    error.NotFound => {
                        self.fsm = .ConfirmCreate;
                        try writer.print("{s} not found.\nCreate?", .{self.name});
                        return .Continue;
                    },
                    else => {
                        std.debug.panic("Unexpected error: {s}.", .{@errorName(e)});
                        return e;
                        // try writer.print();
                        // return .Close;
                    },
                };
                defer u.deinit();
                @memcpy(self.buf[0..u.name.len], u.name);
                @memcpy(self.buf[SZ .. SZ + u.secret.len], u.secret);
                self.name = self.buf[0..u.name.len];
                self.secret = self.buf[SZ .. SZ + u.secret.len];
                self.fsm = .AskSecret;
                try writer.print(format, .{"Secret:"});
                return .Continue;
            },

            .AskSecret => {
                if (std.mem.eql(u8, self.secret, text)) {
                    try writer.print("Welcome back, {s}!\n", .{self.name});
                    return .Admit;
                } else {
                    self.fails += 1;
                    if (self.fails == 2) {
                        try writer.print(format, .{"Wrong secret."});
                        return .Close;
                    }
                    try writer.print(format, .{"Wrong secret.\nSecret:"});
                    return .Continue;
                }
            },

            .ConfirmCreate => {
                switch (text[0]) {
                    'y', 'Y' => {
                        self.fsm = .SetSecret;
                        try writer.print(format, .{"Choose a secret:"});
                    },
                    else => {
                        self.fsm = .AskName;
                        try writer.print(format, .{"Username:"});
                    },
                }
                return .Continue;
            },

            .SetSecret => {
                if (text.len < 8) {
                    try writer.print(format, .{"Too short.\nChoose a secret:"});
                    return .Continue;
                }

                if (text.len >= SZ) {
                    try writer.print(format, .{"Too long.\nChoose a secret:"});
                    return .Continue;
                }

                for (text) |c| if (!std.ascii.isAlphanumeric(c)) {
                    try writer.print(format, .{"Must be alnum.\nChoose a secret:"});
                    return .Continue;
                };

                @memcpy(self.buf[SZ .. SZ + text.len], text);
                self.secret = self.buf[SZ .. SZ + text.len];
                const user = try self.q.createUser(self.name, self.secret);
                // TODO reserve an id for them, add their name to names
                defer user.deinit();
                try writer.print(format, .{"Account created. Welcome!\n"});
                return .Admit;
            },
        }
    }
};

test "net/airlock.zig: test names" {
    const gpa = std.testing.allocator;
    const pool = try zqlite.Pool.init(gpa, .{
        .size = 5,
        .path = "./test.db",
        .flags = zqlite.OpenFlags.Create | zqlite.OpenFlags.EXResCode,
        .on_connection = null,
        .on_first_connection = null,
    });
    defer pool.deinit();

    var a = Airlock.init(gpa, pool);
    var buf = std.ArrayList(u8).init(gpa);
    defer buf.deinit();
    const w = buf.writer();

    try std.testing.expectEqual(.Continue, try a.onText(w, "ab\n"));
    buf.clearRetainingCapacity();

    try std.testing.expectEqual(.Continue, try a.onText(w, "ABCDEFGHIJKLMNOP"));
    buf.clearRetainingCapacity();

    try std.testing.expectEqual(.Continue, try a.onText(w, "bob_"));
    buf.clearRetainingCapacity();

    try std.testing.expectEqual(.Continue, try a.onText(w, "bob"));
}

test "net/airlock.zig: miss -> reject flows back to ask name" {
    const gpa = std.testing.allocator;
    const pool = try zqlite.Pool.init(gpa, .{
        .size = 5,
        .path = "./test.db",
        .flags = zqlite.OpenFlags.Create | zqlite.OpenFlags.EXResCode,
        .on_connection = null,
        .on_first_connection = null,
    });
    defer pool.deinit();

    var a = Airlock.init(gpa, pool);
    var buf = std.ArrayList(u8).init(gpa);
    defer buf.deinit();
    const w = buf.writer();

    // unknown name triggers confirm
    try std.testing.expectEqual(.Continue, try a.onText(w, "unknown"));

    buf.clearRetainingCapacity();
    try std.testing.expectEqual(.Continue, try a.onText(w, "n"));
    try std.testing.expectEqual(.Continue, try a.onText(w, "Alice"));
    // confirm yes
    buf.clearRetainingCapacity();
    try std.testing.expectEqual(.Continue, try a.onText(w, "Y"));

    // too short
    buf.clearRetainingCapacity();
    try std.testing.expectEqual(.Continue, try a.onText(w, "abc123"));

    buf.clearRetainingCapacity();
    try std.testing.expectEqual(.Continue, try a.onText(w, "A" ** (SZ + 1)));

    buf.clearRetainingCapacity();
    try std.testing.expectEqual(.Continue, try a.onText(w, "abcd$1234"));
    buf.clearRetainingCapacity();

    buf.clearRetainingCapacity();
    try std.testing.expectEqual(.Continue, try a.onText(w, "Y"));
    buf.clearRetainingCapacity();

    try std.testing.expectEqual(.Admit, try a.onText(w, "Secr3tKey"));
    const u = try a.q.getUserByName("Alice");
    try a.q.deleteUser(u.id);
    defer u.deinit();
    try std.testing.expect(std.mem.eql(u8, u.name, "Alice"));
    try std.testing.expect(std.mem.eql(u8, u.secret, "Secr3tKey"));
}

// test "Unknown user → ConfirmCreate → SetSecret validations → create → Admit" {
//     var gpa = std.testing.allocator;
//     var q = MockQuerier.init(gpa);
//     defer q.deinit();

//     var a = Airlock.initWithQuerier(q);

//     var W = try makeWriter(gpa);
//     defer W.deinit();

//     // unknown name → confirm
//     try std.testing.expectEqual(.Continue, try a.onText(w, "Alice"));
//     // confirm yes
//     buf.clearRetainingCapacity();
//     try std.testing.expectEqual(.Continue, try a.onText(w, "Y"));
//     try std.testing.expect(std.mem.endsWith(u8, buf.items, "Choose a secret: "));

//     // too short
//     buf.clearRetainingCapacity();
//     try std.testing.expectEqual(.Continue, try a.onText(w, "abc123"));
//     try std.testing.expect(std.mem.endsWith(u8, buf.items, "Too short.\nChoose a secret: "));

//     // too long (>= 16)
//     buf.clearRetainingCapacity();
//     try std.testing.expectEqual(.Continue, try a.onText(w, "ABCDEFGHIJKLMNOP"));
//     try std.testing.expect(std.mem.endsWith(u8, buf.items, "Too long.\nChoose a secret: "));

//     // non-alnum
//     buf.clearRetainingCapacity();
//     try std.testing.expectEqual(.Continue, try a.onText(w, "abcd$1234"));
//     try std.testing.expect(std.mem.endsWith(u8, buf.items, "Must be alnum.\nUsername:"));

//     // valid path
//     buf.clearRetainingCapacity();
//     // We need to go back to SetSecret prompt because previous branch wrote "Username:"
//     // Provide the username again:
//     try std.testing.expectEqual(.Continue, try a.onText(w, "Alice"));
//     buf.clearRetainingCapacity();
//     try std.testing.expectEqual(.Continue, try a.onText(w, "Y"));
//     buf.clearRetainingCapacity();

//     try std.testing.expectEqual(.Admit, try a.onText(w, "Secr3tKey"));
//     try std.testing.expect(q.created);
//     try std.testing.expect(std.mem.endsWith(u8, buf.items, "Account created. Welcome!\n"));
// }

// test "Existing user → AskSecret success → Admit" {
//     var gpa = std.testing.allocator;
//     var q = MockQuerier.init(gpa);
//     defer q.deinit();

//     // seed mock db
//     q.has_user = true;
//     q.user_name = "bob";
//     q.user_secret = "hunter22";

//     var a = Airlock.initWithQuerier(q);
//     var W = try makeWriter(gpa);
//     defer W.deinit();

//     // enter username → transitions to AskSecret
//     try std.testing.expectEqual(.Continue, try a.onText(w, "bob"));

//     // correct secret → Admit
//     try std.testing.expectEqual(.Admit, try a.onText(w, "hunter22"));
// }

// test "Existing user → AskSecret wrong twice → Close" {
//     var gpa = std.testing.allocator;
//     var q = MockQuerier.init(gpa);
//     defer q.deinit();

//     q.has_user = true;
//     q.user_name = "eve";
//     q.user_secret = "passw0rd";

//     var a = Airlock.initWithQuerier(q);
//     var W = try makeWriter(gpa);
//     defer W.deinit();

//     try std.testing.expectEqual(.Continue, try a.onText(w, "eve"));

//     // 1st wrong
//     try std.testing.expectEqual(.Continue, try a.onText(w, "nope"));
//     try std.testing.expect(std.mem.endsWith(u8, buf.items, "Wrong secret.\nSecret: "));

//     // 2nd wrong → Close
//     try std.testing.expectEqual(.Close, try a.onText(w, "stillno"));
// }

// test "Trims whitespace on input" {
//     var gpa = std.testing.allocator;
//     var q = MockQuerier.init(gpa);
//     defer q.deinit();

//     q.has_user = true;
//     q.user_name = "zoe";
//     q.user_secret = "abcdef12";

//     var a = Airlock.initWithQuerier(q);
//     var W = try makeWriter(gpa);
//     defer W.deinit();

//     try std.testing.expectEqual(.Continue, try a.onText(w, "  zoe \t\r\n"));
//     try std.testing.expectEqual(.Admit, try a.onText(w, "\nabcdef12  "));
// }
