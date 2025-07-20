const Cardinal = @import("util.zig").Cardinal;

pub const Request = struct {
    user: usize,
    text: []const u8,
};
pub const Signal = union(enum) {
    Walk: WalkSignal,
    Say: SaySignal,
    Look,
    Attack: AttackSignal,
};
pub const WalkSignal = struct {
    mob: usize,
    dir: Cardinal,
};
pub const SaySignal = struct {
    speaker: usize,
    text: []const u8,
};
pub const AttackSignal = struct {
    source: usize,
    target: usize,
};
