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
        
        const create_user_from_o_auth_sql = 
            \\INSERT INTO users (email, email_verified, name, role, ip_address)
            \\VALUES (?, ?, ?, ?, ?)
        ;

        pub const CreateUserFromOAuthParams = struct {
            email: []const u8,
            email_verified: i64,
            name: ?[]const u8 = null,
            role: []const u8,
            ip_address: ?[]const u8 = null,
        };

        pub fn createUserFromOAuth(self: Self, create_user_from_o_auth_params: CreateUserFromOAuthParams) !void {
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

            try conn.exec(create_user_from_o_auth_sql, .{ 
                create_user_from_o_auth_params.email,
                create_user_from_o_auth_params.email_verified,
                create_user_from_o_auth_params.name,
                create_user_from_o_auth_params.role,
                create_user_from_o_auth_params.ip_address,
            });
        }

        const get_user_sql = 
            \\SELECT id, email, email_verified, name, role, notes, ip_address, last_login_at, last_login_ip, created_at, updated_at, archived_at FROM users WHERE id = ? LIMIT 1
        ;

        pub fn getUser(self: Self, id: i64) !models.User {
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

            var rows = try conn.rows(get_user_sql, .{ 
                id,
            });
            defer rows.deinit();
            if (rows.err) |err| {
                return err;
            }
            const row = rows.next() orelse return error.NotFound;

            const row_id = row.int(0);
            const row_email = try allocator.dupe(u8, row.text(1));
            errdefer allocator.free(row_email);
            const row_email_verified = row.int(2);

            const maybe_name = row.nullableText(3);
            const row_name: ?[]const u8 = blk: {
                if (maybe_name) |field| {
                    break :blk try allocator.dupe(u8, field);
                }
                break :blk null;
            };
            errdefer if (row_name) |field| {
                allocator.free(field);
            };
            const row_role = try allocator.dupe(u8, row.text(4));
            errdefer allocator.free(row_role);

            const maybe_notes = row.nullableText(5);
            const row_notes: ?[]const u8 = blk: {
                if (maybe_notes) |field| {
                    break :blk try allocator.dupe(u8, field);
                }
                break :blk null;
            };
            errdefer if (row_notes) |field| {
                allocator.free(field);
            };

            const maybe_ip_address = row.nullableText(6);
            const row_ip_address: ?[]const u8 = blk: {
                if (maybe_ip_address) |field| {
                    break :blk try allocator.dupe(u8, field);
                }
                break :blk null;
            };
            errdefer if (row_ip_address) |field| {
                allocator.free(field);
            };
            const row_last_login_at = row.nullableInt(7);

            const maybe_last_login_ip = row.nullableText(8);
            const row_last_login_ip: ?[]const u8 = blk: {
                if (maybe_last_login_ip) |field| {
                    break :blk try allocator.dupe(u8, field);
                }
                break :blk null;
            };
            errdefer if (row_last_login_ip) |field| {
                allocator.free(field);
            };
            const row_created_at = row.int(9);
            const row_updated_at = row.int(10);
            const row_archived_at = row.nullableInt(11);

            return .{
                .__allocator = allocator,
                .id = row_id,
                .email = row_email,
                .email_verified = row_email_verified,
                .name = row_name,
                .role = row_role,
                .notes = row_notes,
                .ip_address = row_ip_address,
                .last_login_at = row_last_login_at,
                .last_login_ip = row_last_login_ip,
                .created_at = row_created_at,
                .updated_at = row_updated_at,
                .archived_at = row_archived_at,
            };
        }

        const get_user_by_email_sql = 
            \\SELECT id, email, email_verified, name, role, notes, ip_address, last_login_at, last_login_ip, created_at, updated_at, archived_at FROM users WHERE email = ? LIMIT 1
        ;

        //  If you want case-insensitive lookups, add "COLLATE NOCASE" to the WHERE or to the column definition.
        pub fn getUserByEmail(self: Self, email: []const u8) !models.User {
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

            var rows = try conn.rows(get_user_by_email_sql, .{ 
                email,
            });
            defer rows.deinit();
            if (rows.err) |err| {
                return err;
            }
            const row = rows.next() orelse return error.NotFound;

            const row_id = row.int(0);
            const row_email = try allocator.dupe(u8, row.text(1));
            errdefer allocator.free(row_email);
            const row_email_verified = row.int(2);

            const maybe_name = row.nullableText(3);
            const row_name: ?[]const u8 = blk: {
                if (maybe_name) |field| {
                    break :blk try allocator.dupe(u8, field);
                }
                break :blk null;
            };
            errdefer if (row_name) |field| {
                allocator.free(field);
            };
            const row_role = try allocator.dupe(u8, row.text(4));
            errdefer allocator.free(row_role);

            const maybe_notes = row.nullableText(5);
            const row_notes: ?[]const u8 = blk: {
                if (maybe_notes) |field| {
                    break :blk try allocator.dupe(u8, field);
                }
                break :blk null;
            };
            errdefer if (row_notes) |field| {
                allocator.free(field);
            };

            const maybe_ip_address = row.nullableText(6);
            const row_ip_address: ?[]const u8 = blk: {
                if (maybe_ip_address) |field| {
                    break :blk try allocator.dupe(u8, field);
                }
                break :blk null;
            };
            errdefer if (row_ip_address) |field| {
                allocator.free(field);
            };
            const row_last_login_at = row.nullableInt(7);

            const maybe_last_login_ip = row.nullableText(8);
            const row_last_login_ip: ?[]const u8 = blk: {
                if (maybe_last_login_ip) |field| {
                    break :blk try allocator.dupe(u8, field);
                }
                break :blk null;
            };
            errdefer if (row_last_login_ip) |field| {
                allocator.free(field);
            };
            const row_created_at = row.int(9);
            const row_updated_at = row.int(10);
            const row_archived_at = row.nullableInt(11);

            return .{
                .__allocator = allocator,
                .id = row_id,
                .email = row_email,
                .email_verified = row_email_verified,
                .name = row_name,
                .role = row_role,
                .notes = row_notes,
                .ip_address = row_ip_address,
                .last_login_at = row_last_login_at,
                .last_login_ip = row_last_login_ip,
                .created_at = row_created_at,
                .updated_at = row_updated_at,
                .archived_at = row_archived_at,
            };
        }

        const get_user_by_identity_sql = 
            \\SELECT u.id, u.email, u.email_verified, u.name, u.role, u.notes, u.ip_address, u.last_login_at, u.last_login_ip, u.created_at, u.updated_at, u.archived_at FROM users u
            \\JOIN user_identities i ON i.user_id = u.id
            \\WHERE i.provider = ? AND i.provider_user_id = ?
            \\LIMIT 1
        ;

        pub fn getUserByIdentity(self: Self, provider: []const u8, provider_user_id: []const u8) !models.User {
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

            var rows = try conn.rows(get_user_by_identity_sql, .{ 
                provider,
                provider_user_id,
            });
            defer rows.deinit();
            if (rows.err) |err| {
                return err;
            }
            const row = rows.next() orelse return error.NotFound;

            const row_id = row.int(0);
            const row_email = try allocator.dupe(u8, row.text(1));
            errdefer allocator.free(row_email);
            const row_email_verified = row.int(2);

            const maybe_name = row.nullableText(3);
            const row_name: ?[]const u8 = blk: {
                if (maybe_name) |field| {
                    break :blk try allocator.dupe(u8, field);
                }
                break :blk null;
            };
            errdefer if (row_name) |field| {
                allocator.free(field);
            };
            const row_role = try allocator.dupe(u8, row.text(4));
            errdefer allocator.free(row_role);

            const maybe_notes = row.nullableText(5);
            const row_notes: ?[]const u8 = blk: {
                if (maybe_notes) |field| {
                    break :blk try allocator.dupe(u8, field);
                }
                break :blk null;
            };
            errdefer if (row_notes) |field| {
                allocator.free(field);
            };

            const maybe_ip_address = row.nullableText(6);
            const row_ip_address: ?[]const u8 = blk: {
                if (maybe_ip_address) |field| {
                    break :blk try allocator.dupe(u8, field);
                }
                break :blk null;
            };
            errdefer if (row_ip_address) |field| {
                allocator.free(field);
            };
            const row_last_login_at = row.nullableInt(7);

            const maybe_last_login_ip = row.nullableText(8);
            const row_last_login_ip: ?[]const u8 = blk: {
                if (maybe_last_login_ip) |field| {
                    break :blk try allocator.dupe(u8, field);
                }
                break :blk null;
            };
            errdefer if (row_last_login_ip) |field| {
                allocator.free(field);
            };
            const row_created_at = row.int(9);
            const row_updated_at = row.int(10);
            const row_archived_at = row.nullableInt(11);

            return .{
                .__allocator = allocator,
                .id = row_id,
                .email = row_email,
                .email_verified = row_email_verified,
                .name = row_name,
                .role = row_role,
                .notes = row_notes,
                .ip_address = row_ip_address,
                .last_login_at = row_last_login_at,
                .last_login_ip = row_last_login_ip,
                .created_at = row_created_at,
                .updated_at = row_updated_at,
                .archived_at = row_archived_at,
            };
        }

        const get_users_sql = 
            \\SELECT id, email, email_verified, name, role, notes, ip_address, last_login_at, last_login_ip, created_at, updated_at, archived_at FROM users
        ;

        pub fn getUsers(self: Self) ![]models.User {
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

            var rows = try conn.rows(get_users_sql, .{});
            defer rows.deinit();
            var out = std.ArrayList(models.User).init(allocator);
            defer out.deinit();
            while (rows.next()) |row| {
                const row_id = row.int(0);
                const row_email = try allocator.dupe(u8, row.text(1));
                errdefer allocator.free(row_email);
                const row_email_verified = row.int(2);

                const maybe_name = row.nullableText(3);
                const row_name: ?[]const u8 = blk: {
                    if (maybe_name) |field| {
                        break :blk try allocator.dupe(u8, field);
                    }
                    break :blk null;
                };
                errdefer if (row_name) |field| {
                    allocator.free(field);
                };
                const row_role = try allocator.dupe(u8, row.text(4));
                errdefer allocator.free(row_role);

                const maybe_notes = row.nullableText(5);
                const row_notes: ?[]const u8 = blk: {
                    if (maybe_notes) |field| {
                        break :blk try allocator.dupe(u8, field);
                    }
                    break :blk null;
                };
                errdefer if (row_notes) |field| {
                    allocator.free(field);
                };

                const maybe_ip_address = row.nullableText(6);
                const row_ip_address: ?[]const u8 = blk: {
                    if (maybe_ip_address) |field| {
                        break :blk try allocator.dupe(u8, field);
                    }
                    break :blk null;
                };
                errdefer if (row_ip_address) |field| {
                    allocator.free(field);
                };
                const row_last_login_at = row.nullableInt(7);

                const maybe_last_login_ip = row.nullableText(8);
                const row_last_login_ip: ?[]const u8 = blk: {
                    if (maybe_last_login_ip) |field| {
                        break :blk try allocator.dupe(u8, field);
                    }
                    break :blk null;
                };
                errdefer if (row_last_login_ip) |field| {
                    allocator.free(field);
                };
                const row_created_at = row.int(9);
                const row_updated_at = row.int(10);
                const row_archived_at = row.nullableInt(11);
                try out.append(.{
                    .__allocator = allocator,
                    .id = row_id,
                    .email = row_email,
                    .email_verified = row_email_verified,
                    .name = row_name,
                    .role = row_role,
                    .notes = row_notes,
                    .ip_address = row_ip_address,
                    .last_login_at = row_last_login_at,
                    .last_login_ip = row_last_login_ip,
                    .created_at = row_created_at,
                    .updated_at = row_updated_at,
                    .archived_at = row_archived_at,
                });
            }
            if (rows.err) |err| {
                return err;
            }

            return try out.toOwnedSlice();
        }

        const link_identity_sql = 
            \\INSERT INTO user_identities (user_id, provider, provider_user_id)
            \\VALUES (?, ?, ?)
            \\ON CONFLICT(provider, provider_user_id) DO NOTHING
        ;

        //  Idempotent link; will not move an identity between users
        pub fn linkIdentity(self: Self, user_id: i64, provider: []const u8, provider_user_id: []const u8) !void {
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

            try conn.exec(link_identity_sql, .{ 
                user_id,
                provider,
                provider_user_id,
            });
        }

        const touch_last_login_sql = 
            \\UPDATE users
            \\SET last_login_at = CURRENT_TIMESTAMP, last_login_ip = ?
            \\WHERE id = ?
        ;

        pub fn touchLastLogin(self: Self, last_login_ip: []const u8, id: i64) !void {
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

            try conn.exec(touch_last_login_sql, .{ 
                last_login_ip,
                id,
            });
        }

    };
}