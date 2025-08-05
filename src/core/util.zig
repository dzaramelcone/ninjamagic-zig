const std = @import("std");

var next_id: std.atomic.Value(usize) = .{ .raw = 1 };

pub fn getId() usize {
    return next_id.fetchAdd(1, .monotonic);
}

pub const Seconds = f64;

pub const Cardinal = enum {
    north,
    northeast,
    east,
    southeast,
    south,
    southwest,
    west,
    northwest,
};
