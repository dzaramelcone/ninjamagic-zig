const Cardinal = @import("util.zig").Cardinal;
const Position = @import("level.zig").Position;

pub const Request = struct { user: usize, text: []const u8 };

pub const Look = struct { source: usize };
pub const Walk = struct { source: usize, dir: Cardinal };
pub const Say = struct { source: usize, text: []const u8, reach: Reach };
pub const Attack = struct { source: usize, target: usize };
pub const Move = struct { source: usize, move_from: Position, move_to: Position };

pub const Emit = union(enum) { Say: Say };

pub const Reach = enum {
    Sight,
};

pub const Outbound = union(enum) {
    Message: struct { to: usize, text: []const u8 },
    PosUpdate: struct { to: usize, subj: usize, move_from: Position, move_to: Position },
    EntityInSight: struct { to: usize, subj: usize, x: usize, y: usize },
    EntityOutOfSight: struct { to: usize, subj: usize },
};

pub const Signal = union(enum) {
    Walk: Walk,
    Say: Say,
    Look: Look,
    Attack: Attack,
    Move: Move,
    Emit: Emit,
    Outbound: Outbound,
};
