const Cardinal = @import("util.zig").Cardinal;
const Position = @import("level.zig").Position;

pub const Request = struct { user: usize, text: []const u8 };

pub const Look = struct { source: usize };
pub const Walk = struct { mob: usize, dir: Cardinal };
pub const Say = struct { speaker: usize, text: []const u8 };
pub const Attack = struct { source: usize, target: usize };

pub const Outbound = union(enum) {
    Message: struct { source: usize, text: []const u8 },
    PosUpdate: struct { source: usize, moveFrom: Position, moveTo: Position },
};

pub const Signal = union(enum) {
    Walk: Walk,
    Say: Say,
    Look: Look,
    Attack: Attack,
    Outbound: Outbound,
};
