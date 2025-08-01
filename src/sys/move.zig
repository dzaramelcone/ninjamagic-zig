const std = @import("std");
const core = @import("core");
const Level = core.Level;
const Position = core.Position;
const Self = @This();

var positions: std.MultiArrayList(Position) = undefined;
var mob_rows: std.AutoHashMap(usize, usize) = undefined;
var levels: std.AutoHashMap(usize, Level) = undefined;
var test_level: *Level = undefined;
var alloc: std.mem.Allocator = undefined;

pub fn init(allocator: std.mem.Allocator) !void {
    alloc = allocator;
    positions = .{};
    mob_rows = std.AutoHashMap(usize, usize).init(alloc);
    levels = std.AutoHashMap(usize, Level).init(alloc);
    test_level = try Level.initStatic(alloc);
    try levels.put(0, test_level.*);
}

pub fn deinit() void {
    test_level.deinit();
    levels.deinit();
    mob_rows.deinit();
    positions.deinit(alloc);
    alloc = undefined;
}

pub fn toPlayer(_: MovementError) []const u8 {
    // TODO better error messages; e.g. DestinationCollision should be unique to the obstruction.
    return "You can't go there.";
}

pub fn step() void {
    var it = core.bus.walk.flush() catch return;
    while (it.next()) |w| {
        const event = walk(w.*) catch |err| {
            core.bus.enqueue(.{ .Outbound = .{ .Message = .{ .source = w.mob, .text = toPlayer(err) } } }) catch continue;
            continue;
        };
        core.bus.enqueue(.{ .Outbound = event }) catch continue;
    }
}

pub const MobNotFound = error{
    MobNotFound,
};

pub const MovementError = error{
    MobNotFound,
    LevelNotFound,
    PositionOutOfBounds,
    DestinationCollision,
};

pub const PlacementError = MovementError || error{MobUniqueViolation};

pub fn walk(sig: core.sig.Walk) MovementError!core.sig.Outbound {
    const cur = try get(sig.mob);
    const lvl = levels.get(cur.lvl_key) orelse return error.LevelNotFound;

    const next = walk_helper(cur, sig.dir, lvl.width, lvl.height, lvl.wraps);
    if (!lvl.inBounds(next.x, next.y)) return error.PositionOutOfBounds;
    if (lvl.tile(next.x, next.y) == .wall) return error.DestinationCollision;

    // TODO there could be quite a few outbound messages because of a movement
    try set(sig.mob, next);
    return .{ .PosUpdate = .{
        .source = sig.mob,
        .moveFrom = cur,
        .moveTo = next,
    } };
}

pub fn place(mob: usize, p: Position) PlacementError!void {
    const lvl = levels.get(p.lvl_key) orelse return error.LevelNotFound;
    if (!lvl.inBounds(p.x, p.y)) return error.PositionOutOfBounds;
    if (lvl.tile(p.x, p.y) == .wall) return error.DestinationCollision;
    if (mob_rows.contains(mob)) return error.MobUniqueViolation;

    const row = positions.len;
    positions.append(alloc, p) catch @panic("OOM");
    mob_rows.put(mob, row) catch @panic("OOM");
}

pub fn get(mob: usize) MobNotFound!Position {
    const row = mob_rows.get(mob) orelse return error.MobNotFound;
    return Position{
        .lvl_key = positions.items(.lvl_key)[row],
        .x = positions.items(.x)[row],
        .y = positions.items(.y)[row],
    };
}

pub fn set(mob: usize, p: Position) MobNotFound!void {
    const row = mob_rows.get(mob) orelse return error.MobNotFound;
    positions.set(row, p);
}

inline fn inc(v: usize, max: usize, wraps: bool) usize {
    if (wraps) return if (v + 1 == max) 0 else v + 1;
    return if (v + 1 >= max) max - 1 else v + 1;
}

inline fn dec(v: usize, max: usize, wraps: bool) usize {
    if (wraps) return if (v == 0) max - 1 else v - 1;
    return if (v == 0) 0 else v - 1;
}

fn walk_helper(p: Position, dir: core.Cardinal, w: usize, h: usize, wraps: bool) Position {
    return switch (dir) {
        .north => .{ .lvl_key = p.lvl_key, .x = p.x, .y = inc(p.y, h, wraps) },
        .south => .{ .lvl_key = p.lvl_key, .x = p.x, .y = dec(p.y, h, wraps) },
        .east => .{ .lvl_key = p.lvl_key, .x = inc(p.x, w, wraps), .y = p.y },
        .west => .{ .lvl_key = p.lvl_key, .x = dec(p.x, w, wraps), .y = p.y },
        .northeast => .{ .lvl_key = p.lvl_key, .x = inc(p.x, w, wraps), .y = inc(p.y, h, wraps) },
        .southeast => .{ .lvl_key = p.lvl_key, .x = inc(p.x, w, wraps), .y = dec(p.y, h, wraps) },
        .northwest => .{ .lvl_key = p.lvl_key, .x = dec(p.x, w, wraps), .y = inc(p.y, h, wraps) },
        .southwest => .{ .lvl_key = p.lvl_key, .x = dec(p.x, w, wraps), .y = dec(p.y, h, wraps) },
    };
}

test "system – directional walk validates blocked/out-of-bounds" {
    const raises = std.testing.expectError;
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const A = gpa.allocator();
    try init(A);
    defer deinit();
    try place(1, .{ .lvl_key = 0, .x = 1, .y = 1 });

    // simple east move
    const outb = try walk(.{ .mob = 1, .dir = .east });
    try std.testing.expectEqual(2, outb.PosUpdate.moveTo.x);
    try std.testing.expectEqual(1, outb.PosUpdate.moveTo.y);

    try raises(
        MovementError.DestinationCollision,
        walk(.{ .mob = 1, .dir = .north }),
    );
    try raises(
        MovementError.MobNotFound,
        walk(.{ .mob = 999, .dir = .south }),
    );
    try raises(
        PlacementError.MobUniqueViolation,
        place(1, .{ .lvl_key = 0, .x = 1, .y = 1 }),
    );
    try raises(
        PlacementError.PositionOutOfBounds,
        place(2, .{ .lvl_key = 0, .x = 0, .y = 200 }),
    );
    try raises(
        PlacementError.LevelNotFound,
        place(2, .{ .lvl_key = 20, .x = 1, .y = 1 }),
    );
}

test "system – directional walk wraps on wrapped levels" {
    const raises = std.testing.expectError;
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const A = gpa.allocator();

    try init(A);
    defer deinit();
    // hack level to wrap
    levels.getPtr(0).?.wraps = true;

    try place(1, .{ .lvl_key = 0, .x = 9, .y = 1 });

    // east from (9,1) -> (0,1)
    {
        const outb = try walk(.{ .mob = 1, .dir = .east });
        try std.testing.expectEqual(0, outb.PosUpdate.moveTo.x);
        try std.testing.expectEqual(1, outb.PosUpdate.moveTo.y);
    }

    // West from (0,1) -> (9,1)
    {
        const outb = try walk(.{ .mob = 1, .dir = .west });
        try std.testing.expectEqual(9, outb.PosUpdate.moveTo.x);
        try std.testing.expectEqual(1, outb.PosUpdate.moveTo.y);
    }

    // north from (9,9) -> (9,0)
    try set(1, .{ .lvl_key = 0, .x = 9, .y = 9 });
    {
        const outb = try walk(.{ .mob = 1, .dir = .north });
        try std.testing.expectEqual(9, outb.PosUpdate.moveTo.x);
        try std.testing.expectEqual(0, outb.PosUpdate.moveTo.y);
    }

    // south from (9,0) -> (9,9)
    {
        const outb = try walk(.{ .mob = 1, .dir = .south });
        try std.testing.expectEqual(9, outb.PosUpdate.moveTo.x);
        try std.testing.expectEqual(9, outb.PosUpdate.moveTo.y);
    }

    // northeast from (9,9) -> (0,0)
    try set(1, .{ .lvl_key = 0, .x = 9, .y = 9 });
    {
        const outb = try walk(.{ .mob = 1, .dir = .northeast });
        try std.testing.expectEqual(0, outb.PosUpdate.moveTo.x);
        try std.testing.expectEqual(0, outb.PosUpdate.moveTo.y);
    }

    // southeast from (9,0) -> (0,9)
    try set(1, .{ .lvl_key = 0, .x = 9, .y = 0 });
    {
        const outb = try walk(.{ .mob = 1, .dir = .southeast });
        try std.testing.expectEqual(0, outb.PosUpdate.moveTo.x);
        try std.testing.expectEqual(9, outb.PosUpdate.moveTo.y);
    }

    // southwest from (0,0) -> (9,9)
    try set(1, .{ .lvl_key = 0, .x = 0, .y = 0 });
    {
        const outb = try walk(.{ .mob = 1, .dir = .southwest });
        try std.testing.expectEqual(9, outb.PosUpdate.moveTo.x);
        try std.testing.expectEqual(9, outb.PosUpdate.moveTo.y);
    }

    // northwest from (0,9) -> (9,0)
    try set(1, .{ .lvl_key = 0, .x = 0, .y = 9 });
    {
        const outb = try walk(.{ .mob = 1, .dir = .northwest });
        try std.testing.expectEqual(9, outb.PosUpdate.moveTo.x);
        try std.testing.expectEqual(0, outb.PosUpdate.moveTo.y);
    }

    // collision after wrap: south from (2,0) wraps to (2,9) which is a wall
    try set(1, .{ .lvl_key = 0, .x = 2, .y = 0 });
    try raises(
        MovementError.DestinationCollision,
        walk(.{ .mob = 1, .dir = .south }),
    );
}
