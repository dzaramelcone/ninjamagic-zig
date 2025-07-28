const std = @import("std");
pub const Tile = enum { floor, wall };
pub const Position = struct { lvl_key: usize, x: usize, y: usize };

fn toTiles(s: []const u8) [10]Tile {
    var out: [10]Tile = undefined;
    for (s, 0..) |c, i| out[i] = if (c == '#') .wall else .floor;
    return out;
}

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
