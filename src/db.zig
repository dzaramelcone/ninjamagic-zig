const std = @import("std");
const zqlite = @import("zqlite");
const db = @import("./db/sqlc-out/queries.sql.zig");
const schema = @embedFile("./db/schema.sql");

test "db.zig: basic queries" {
    const allocator = std.testing.allocator;
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

    const querier = db.PoolQuerier.init(allocator, pool);
    const root = querier.createUser("root", "shush") catch |err| switch (err) {
        error.ConstraintUnique => try querier.getUserByName("root"),
        else => return err,
    };
    defer root.deinit();

    const get = try querier.getUserByName("root");
    defer get.deinit();
    try std.testing.expect(std.mem.eql(u8, root.name, get.name));
    try querier.deleteUser(root.id);
    // querier.createUserFromOAuth(.{
    //     .name = "root",
    //     .email = "admin@admin.com",
    //     .email_verified = 1,
    //     .ip_address = "127.0.0.1",
    //     .role = "admin",
    // }) catch |err| switch (err) {
    //     error.ConstraintUnique => std.debug.print("Someone with that e-mail already exists.\n", .{}),
    //     else => return err,
    // };

    // querier.createUserFromOAuth(.{
    //     .name = "user",
    //     .email = "user@user.com",
    //     .email_verified = 1,
    //     .ip_address = "127.0.0.1",
    //     .role = "user",
    // }) catch |err| switch (err) {
    //     error.ConstraintUnique => std.debug.print("Someone with that e-mail already exists.\n", .{}),
    //     else => return err,
    // };

    // const by_id = try querier.getUser(1);
    // defer by_id.deinit();
    // std.debug.print("{d}: {s}\n", .{ by_id.id, by_id.email });

    // const by_email = try querier.getUserByEmail("user@user.com");
    // defer by_email.deinit();
    // std.debug.print("{d}: {s}\n", .{ by_email.id, by_email.email });
}
