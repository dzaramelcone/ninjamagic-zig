const std = @import("std");
const core = @import("core");
pub const Position = struct { lvl_ptr: usize, x: usize, y: usize };
pub const Tile = enum { floor, wall };

pub const MovementEvent = struct {
    mob: usize,
    from: Position,
    to: Position,
};

pub const System = struct {
    alloc: std.mem.Allocator,
    inbox: std.ArrayList(core.Signal),
    outbox: std.ArrayList(MovementEvent),
    positions: std.MultiArrayList(Position),
    positions_idx: std.AutoHashMap(usize, usize),

    levels: std.AutoHashMap(usize, Level),
    test_level: *Level,

    pub fn init(alloc: std.mem.Allocator) !System {
        var out = System{
            .alloc = alloc,
            .inbox = std.ArrayList(core.Signal).init(alloc),
            .outbox = std.ArrayList(MovementEvent).init(alloc),

            .positions = .{},
            .positions_idx = std.AutoHashMap(usize, usize).init(alloc),

            .levels = std.AutoHashMap(usize, Level).init(alloc),
            .test_level = try Level.initStatic(alloc),
        };
        try out.levels.put(0, out.test_level.*);
        return out;
    }

    pub fn deinit(self: *System) void {
        self.inbox.deinit();
        self.outbox.deinit();
        self.positions.deinit(self.alloc);
        self.positions_idx.deinit();
        self.levels.deinit();
        self.test_level.deinit();
        self.alloc.destroy(self);
    }

    // TODO: can do init_frame and create an arena allocator so inbox/outbox are freed
    pub fn recv(self: *System, sig: core.Signal) void {
        self.inbox.appendAssumeCapacity(sig);
    }

    pub fn step(self: *System) !void {
        for (self.inbox.items) |sig| {
            switch (sig) {
                .Walk => |w| {
                    try self.outbox.append(try self.walk(w));
                },
                else => {
                    std.log.err("unhandled signal: {any}", .{sig});
                    return error.UnhandledSignal;
                },
            }
        }
        self.inbox.clearRetainingCapacity();

        // flush outbox
        for (self.outbox.items) |out| {
            // TODO: send to broadcast sys
            std.log.debug("mob {} moved from ({},{}) to ({}, {})", .{ out.mob, out.from.x, out.from.y, out.to.x, out.to.y });
        }
        self.outbox.clearRetainingCapacity();
    }

    pub fn walk(self: *System, sig: core.WalkSignal) !MovementEvent {
        const cur = try self.get(sig.mob);
        const lvl = self.levels.get(cur.lvl_ptr) orelse return error.UnknownLevel;

        const next = walk_helper(cur, sig.dir, lvl.width, lvl.height, lvl.wraps);
        if (!lvl.inBounds(next.x, next.y)) return error.OutOfBounds;
        if (lvl.tile(next.x, next.y) == .wall) return error.Blocked;

        try self.set(sig.mob, next);
        return .{ .mob = sig.mob, .from = cur, .to = next };
    }

    pub fn place(self: *System, id: usize, p: Position) !void {
        if (self.positions_idx.contains(id)) return error.UniqueViolation;
        const lvl = self.levels.get(p.lvl_ptr) orelse return error.UnknownLevel;
        if (!lvl.inBounds(p.x, p.y)) return error.OutOfBounds;
        const row = self.positions.len;
        try self.positions.append(self.alloc, p);
        try self.positions_idx.put(id, row);
    }

    pub fn get(self: *System, id: usize) !Position {
        const row = self.positions_idx.get(id) orelse return error.NotFound;
        return .{
            .lvl_ptr = self.positions.items(.lvl_ptr)[row],
            .x = self.positions.items(.x)[row],
            .y = self.positions.items(.y)[row],
        };
    }
    pub fn set(self: *System, id: usize, p: Position) !void {
        const row = self.positions_idx.get(id) orelse return error.NotFound;
        self.positions.set(row, p);
    }
};

fn inc(v: usize, max: usize) usize {
    return @min(v +| 1, max);
}
fn dec(v: usize) usize {
    return if (v == 0) 0 else v - 1;
}

fn walk_helper(p: Position, dir: core.Cardinal, w: usize, h: usize, _: bool) Position {
    return switch (dir) {
        .north => .{ .lvl_ptr = p.lvl_ptr, .x = p.x, .y = inc(p.y, h) },
        .northeast => .{ .lvl_ptr = p.lvl_ptr, .x = inc(p.x, w), .y = inc(p.y, h) },
        .east => .{ .lvl_ptr = p.lvl_ptr, .x = inc(p.x, w), .y = p.y },
        .southeast => .{ .lvl_ptr = p.lvl_ptr, .x = inc(p.x, w), .y = dec(p.y) },
        .south => .{ .lvl_ptr = p.lvl_ptr, .x = p.x, .y = dec(p.y) },
        .southwest => .{ .lvl_ptr = p.lvl_ptr, .x = dec(p.x), .y = dec(p.y) },
        .west => .{ .lvl_ptr = p.lvl_ptr, .x = dec(p.x), .y = p.y },
        .northwest => .{ .lvl_ptr = p.lvl_ptr, .x = dec(p.x), .y = inc(p.y, h) },
    };
}

pub const Level = struct {
    alloc: std.mem.Allocator,
    width: usize,
    height: usize,
    tiles: []Tile,
    wraps: bool = false,

    pub fn initStatic(alloc: std.mem.Allocator) !*Level {
        const W = static_tiles[0].len;
        const H = static_tiles.len;
        const buf = try alloc.alloc(Tile, W * H);
        for (static_tiles, 0..) |row, ry| {
            for (row, 0..) |t, rx| buf[ry * W + rx] = t;
        }
        const self = try alloc.create(Level);
        self.* = .{
            .width = W,
            .height = H,
            .tiles = buf,
            .alloc = alloc,
        };
        return self;
    }

    pub fn deinit(self: *Level) void {
        self.alloc.free(self.tiles);
        self.alloc.destroy(self);
    }

    pub fn inBounds(self: *const Level, x: usize, y: usize) bool {
        return x >= 0 and y >= 0 and x < self.width and y < self.height;
    }

    pub fn tile(self: *const Level, x: usize, y: usize) Tile {
        return self.tiles[y * self.width + x];
    }
};

const static_tiles = [_][10]Tile{
    toTiles("..######.."),
    toTiles(".........."),
    toTiles("#.######.#"),
    toTiles("#.#....#.#"),
    toTiles(".........."),
    toTiles(".........."),
    toTiles("#.#....#.#"),
    toTiles("#.######.#"),
    toTiles(".........."),
    toTiles("..######.."),
};

fn toTiles(s: []const u8) [10]Tile {
    var out: [10]Tile = undefined;
    for (s, 0..) |c, i| out[i] = if (c == '#') .wall else .floor;
    return out;
}
test "system – directional walk validates blocked/out-of-bounds" {
    const raises = std.testing.expectError;
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const A = gpa.allocator();

    var sys = try System.init(A);
    defer sys.deinit();

    try sys.levels.put(0, sys.test_level.*);

    try sys.place(1, .{ .lvl_ptr = 0, .x = 1, .y = 1 });

    // Simple east move (x + 1)
    const pos1 = try sys.walk(.{ .mob = 1, .dir = .east });
    try std.testing.expectEqual(@as(u32, 2), pos1.to.x);
    try std.testing.expectEqual(@as(u32, 1), pos1.to.y);

    // Move into wall
    try raises(error.Blocked, sys.walk(.{ .mob = 1, .dir = .north }));

    // Move non-existent mob
    try raises(error.NotFound, sys.walk(.{ .mob = 999, .dir = .south }));
}
