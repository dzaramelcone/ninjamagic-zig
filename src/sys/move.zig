const std = @import("std");
const core = @import("core");
const Level = core.Level;
const Position = core.Position;
const Self = @This();

var positions: std.MultiArrayList(Position) = .{};
var mob_rows: std.AutoHashMap(usize, usize) = undefined;
var levels: std.AutoHashMap(usize, Level) = undefined;
var test_level: *Level = undefined;
var alloc: std.mem.Allocator = undefined;

pub fn init(allocator: std.mem.Allocator) !void {
    alloc = allocator;
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

pub fn step() !void {
    var it = try core.bus.walk.flush();
    while (it.next()) |w| {
        // TODO handle errors.
        const event = try walk(w.*);
        try core.bus.enqueue(.{ .Outbound = event });
    }
}

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
    if (mob_rows.contains(mob)) return error.MobUniqueViolation;
    const lvl = levels.get(p.lvl_key) orelse return error.LevelNotFound;
    if (!lvl.inBounds(p.x, p.y)) return error.PositionOutOfBounds;
    if (lvl.tile(p.x, p.y) == .wall) return error.DestinationCollision;

    const row = positions.len;
    positions.append(alloc, p) catch @panic("OOM");
    mob_rows.put(mob, row) catch @panic("OOM");
}

pub fn get(mob: usize) !Position {
    const row = mob_rows.get(mob) orelse return error.MobNotFound;
    return Position{
        .lvl_key = positions.items(.lvl_key)[row],
        .x = positions.items(.x)[row],
        .y = positions.items(.y)[row],
    };
}

pub fn set(mob: usize, p: Position) !void {
    const row = mob_rows.get(mob) orelse return error.MobNotFound;
    positions.set(row, p);
}

fn inc(v: usize, max: usize) usize {
    return @min(v +| 1, max);
}
fn dec(v: usize) usize {
    return if (v == 0) 0 else v - 1;
}

fn walk_helper(p: Position, dir: core.Cardinal, w: usize, h: usize, _: bool) Position {
    return switch (dir) {
        .north => .{ .lvl_key = p.lvl_key, .x = p.x, .y = inc(p.y, h) },
        .northeast => .{ .lvl_key = p.lvl_key, .x = inc(p.x, w), .y = inc(p.y, h) },
        .east => .{ .lvl_key = p.lvl_key, .x = inc(p.x, w), .y = p.y },
        .southeast => .{ .lvl_key = p.lvl_key, .x = inc(p.x, w), .y = dec(p.y) },
        .south => .{ .lvl_key = p.lvl_key, .x = p.x, .y = dec(p.y) },
        .southwest => .{ .lvl_key = p.lvl_key, .x = dec(p.x), .y = dec(p.y) },
        .west => .{ .lvl_key = p.lvl_key, .x = dec(p.x), .y = p.y },
        .northwest => .{ .lvl_key = p.lvl_key, .x = dec(p.x), .y = inc(p.y, h) },
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

    // Simple east move (x + 1)
    const outb = try walk(.{ .mob = 1, .dir = .east });
    try std.testing.expectEqual(@as(u32, 2), outb.PosUpdate.moveTo.x);
    try std.testing.expectEqual(@as(u32, 1), outb.PosUpdate.moveTo.y);

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
        place(1, .{ .lvl_key = 20, .x = 1, .y = 1 }),
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
