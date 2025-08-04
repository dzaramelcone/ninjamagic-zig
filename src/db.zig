const std = @import("std");
const zqlite = @import("zqlite");
const Users = @import("./db/sqlc-out/queries.sql.zig").PoolQuerier;
const schema = @embedFile("./db/schema.sql");

pub fn doQueries(alloc: std.mem.Allocator) !void {
    const allocator = alloc;
    var pool = try zqlite.Pool.init(allocator, .{
        .size = 5,
        .path = "./test.db",
        .flags = zqlite.OpenFlags.Create | zqlite.OpenFlags.EXResCode,
        .on_connection = null,
        .on_first_connection = null,
    });
    defer pool.deinit();
    const c = pool.acquire();
    c.exec(schema, .{}) catch |err| switch (err) {
        error.Error => std.debug.print("Schema was already created.\n", .{}),
        else => return err,
    };
    c.release();

    const querier = Users.init(allocator, pool);

    querier.createUser(.{
        .name = "admin",
        .email = "admin@example.com",
        .password = "password",
        .salary = 1000.50,
    }) catch |err| switch (err) {
        error.ConstraintUnique => std.debug.print("Someone with that e-mail already exists.\n", .{}),
        else => return err,
    };

    querier.createUser(.{
        .name = "user",
        .email = "user@example.com",
        .password = "password",
        .salary = 1000.50,
    }) catch |err| switch (err) {
        error.ConstraintUnique => std.debug.print("Someone with that e-mail already exists.\n", .{}),
        else => return err,
    };

    const by_id = try querier.getUser(1);
    defer by_id.deinit();
    std.debug.print("{d}: {s}\n", .{ by_id.id, by_id.email });

    const by_email = try querier.getUserByEmail("admin@example.com");
    defer by_email.deinit();
    std.debug.print("{d}: {s}\n", .{ by_email.id, by_email.email });
}
