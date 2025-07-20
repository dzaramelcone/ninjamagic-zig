const std = @import("std");

pub const Position = struct { x: u32, y: u32 };
pub const Tile = enum { floor, wall };
pub const MoveArgs = struct {
    pub const Kind = enum { absolute, relative };
    id: usize,
    x: u32,
    y: u32,
};

const PosTable = struct {
    data: std.MultiArrayList(Position) = .{},
    index: std.AutoHashMap(usize, usize),
    alloc: std.mem.Allocator,

    pub fn init(alloc: std.mem.Allocator) PosTable {
        return .{
            .index = std.AutoHashMap(usize, usize).init(alloc),
            .alloc = alloc,
        };
    }

    pub fn deinit(self: *PosTable) void {
        self.data.deinit(self.alloc);
        self.index.deinit();
    }

    pub fn place(self: *PosTable, id: usize, p: Position) !void {
        if (self.index.contains(id)) return error.UniqueViolation;
        const row = self.data.len;
        try self.data.append(self.alloc, p);
        try self.index.put(id, row);
    }

    pub fn get(self: *PosTable, id: usize) !Position {
        const row = self.index.get(id) orelse return error.NotFound;
        return .{
            .x = self.data.items(.x)[row],
            .y = self.data.items(.y)[row],
        };
    }
    pub fn set(self: *PosTable, id: usize, p: Position) !void {
        const row = self.index.get(id) orelse return error.NotFound;
        self.data.set(row, p);
    }
};

pub const System = struct {
    pub fn move(lvl: *Level, args: MoveArgs) !Position {
        const next = Position{ .x = args.x, .y = args.y };
        if (!lvl.inBounds(next)) return error.OutOfBounds;
        if (lvl.tile(next) == .wall) return error.Blocked;
        try lvl.positions.set(args.id, next);
        return next;
    }

    pub fn place(lvl: *Level, id: usize, p: Position) !void {
        if (!lvl.inBounds(p)) return error.OutOfBounds;
        try lvl.positions.place(id, p);
    }
};
pub const Level = struct {
    alloc: std.mem.Allocator,
    width: usize,
    height: usize,
    tiles: []Tile,
    positions: PosTable,

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
            .positions = PosTable.init(alloc),
            .alloc = alloc,
        };
        return self;
    }

    pub fn deinit(self: *Level) void {
        self.alloc.free(self.tiles);
        self.positions.deinit();
        self.alloc.destroy(self);
    }

    fn inBounds(self: *const Level, p: Position) bool {
        return p.x >= 0 and p.y >= 0 and p.x < self.width and p.y < self.height;
    }

    fn tile(self: *const Level, p: Position) Tile {
        return self.tiles[@as(usize, p.y) * self.width + @as(usize, p.x)];
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

test "movement – place & move" {
    const raises = std.testing.expectError;
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const A = gpa.allocator();

    var lvl = try Level.initStatic(A);
    defer lvl.deinit();

    try System.place(lvl, 1, .{ .x = 1, .y = 1 });
    try raises(error.UniqueViolation, System.place(lvl, 1, .{
        .x = 2,
        .y = 0,
    }));

    try std.testing.expectEqual(Position{ .x = 2, .y = 1 }, try System.move(lvl, .{
        .id = 1,
        .x = 2,
        .y = 1,
    }));
    try std.testing.expectEqual(Position{ .x = 3, .y = 4 }, try System.move(lvl, .{
        .id = 1,
        .x = 3,
        .y = 4,
    }));

    // absolute move into wall – expect Blocked
    try raises(error.Blocked, System.move(lvl, .{
        .id = 1,
        .x = 2,
        .y = 0,
    }));

    // move outside bounds – expect OutOfBounds
    try raises(error.OutOfBounds, System.move(lvl, .{
        .id = 1,
        .x = 5,
        .y = 30,
    }));

    // unknown entity
    try raises(error.NotFound, System.move(lvl, .{
        .id = 999,
        .x = 0,
        .y = 0,
    }));
}
