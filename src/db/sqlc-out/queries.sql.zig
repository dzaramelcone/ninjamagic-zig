// Generated with sqlc v1.29.0
 
const std = @import("std");
const Allocator = std.mem.Allocator;

const zqlite = @import("zqlite");
const models = @import("models.zig");

pub const ConnQuerier = Querier(zqlite.Conn);
pub const PoolQuerier = Querier(*zqlite.Pool);

pub fn Querier(comptime T: type) type {
    return struct{
        const Self = @This();
        
        allocator: Allocator,
        conn: T,

        pub fn init(allocator: Allocator, conn: T) Self {
            return .{ .allocator = allocator, .conn = conn };
        }
        
        const create_user_sql = 
            \\INSERT INTO users (name, secret)
            \\VALUES (?, ?)
            \\RETURNING id, name, secret
        ;

        pub fn createUser(self: Self, name: []const u8, secret: []const u8) !models.User {
            const allocator = self.allocator;
            var conn: zqlite.Conn = blk: {
                if (T == *zqlite.Pool) {
                    break :blk self.conn.acquire();
                } else {
                    break :blk self.conn;
                }
            };
            defer if (T == *zqlite.Pool) {
                conn.release();
            };

            var rows = try conn.rows(create_user_sql, .{ 
                name,
                secret,
            });
            defer rows.deinit();
            if (rows.err) |err| {
                return err;
            }
            const row = rows.next() orelse return error.NotFound;

            const row_id = row.int(0);
            const row_name = try allocator.dupe(u8, row.text(1));
            errdefer allocator.free(row_name);
            const row_secret = try allocator.dupe(u8, row.text(2));
            errdefer allocator.free(row_secret);

            return .{
                .__allocator = allocator,
                .id = row_id,
                .name = row_name,
                .secret = row_secret,
            };
        }

        const delete_user_sql = 
            \\DELETE FROM users WHERE id = ?
        ;

        pub fn deleteUser(self: Self, id: i64) !void {
            var conn: zqlite.Conn = blk: {
                if (T == *zqlite.Pool) {
                    break :blk self.conn.acquire();
                } else {
                    break :blk self.conn;
                }
            };
            defer if (T == *zqlite.Pool) {
                conn.release();
            };

            try conn.exec(delete_user_sql, .{ 
                id,
            });
        }

        const get_user_by_name_sql = 
            \\SELECT id, name, secret FROM users WHERE name = ? LIMIT 1
        ;

        pub fn getUserByName(self: Self, name: []const u8) !models.User {
            const allocator = self.allocator;
            var conn: zqlite.Conn = blk: {
                if (T == *zqlite.Pool) {
                    break :blk self.conn.acquire();
                } else {
                    break :blk self.conn;
                }
            };
            defer if (T == *zqlite.Pool) {
                conn.release();
            };

            var rows = try conn.rows(get_user_by_name_sql, .{ 
                name,
            });
            defer rows.deinit();
            if (rows.err) |err| {
                return err;
            }
            const row = rows.next() orelse return error.NotFound;

            const row_id = row.int(0);
            const row_name = try allocator.dupe(u8, row.text(1));
            errdefer allocator.free(row_name);
            const row_secret = try allocator.dupe(u8, row.text(2));
            errdefer allocator.free(row_secret);

            return .{
                .__allocator = allocator,
                .id = row_id,
                .name = row_name,
                .secret = row_secret,
            };
        }

    };
}