const std = @import("std");
const pg = @import("pg");
const cfg = @import("config.zig").cfg;
const Users = @import("models/queries.sql.zig").PoolQuerier;

pub fn doQueries(alloc: std.mem.Allocator) !void {
    var pool = try pg.Pool.init(alloc, .{});
    defer pool.deinit();

    const querier = Users.init(alloc, pool);

    try querier.createUser(.{
        .name = "admin",
        .email = "admin@example.com",
        .password = "password",
        .role = .admin,
        .ip_address = "192.168.1.1",
        .salary = 1000.50,
    });

    try querier.createUser(.{
        .name = "user",
        .email = "user@example.com",
        .password = "password",
        .role = .user,
        .ip_address = "192.168.1.1",
        .salary = 1000.50,
    });

    const by_id = try querier.getUser(1);
    defer by_id.deinit();
    std.debug.print("{d}: {s}\n", .{ by_id.id, by_id.email });

    const by_email = try querier.getUserByEmail("admin@example.com");
    defer by_email.deinit();
    std.debug.print("{d}: {s}\n", .{ by_email.id, by_email.email });

    const by_role = try querier.getUsersByRole(.admin);
    defer {
        if (by_role.len > 0) {
            for (by_role) |user| {
                user.deinit();
            }
            alloc.free(by_role);
        }
    }
    for (by_role) |user| {
        std.debug.print("{d}: {s}\n", .{ user.id, user.email });
    }
}
