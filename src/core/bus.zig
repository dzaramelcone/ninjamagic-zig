const std = @import("std");
const sig = @import("sig.zig");

const DEFAULT_SZ = 64;

pub const MovementError = error{
    MobNotFound,
    LevelNotFound,
    PositionOutOfBounds,
    DestinationCollision,
};
pub const AppendError = error{
    AppendWhileFlushing,
    Full,
};

pub const FlushError = error{FlushWhileFlushing};

fn Topic(comptime T: type, N: usize) type {
    return struct {
        const Self = @This();
        count: usize = 0,
        items: [N]T = undefined,
        flushing: bool = false,

        pub fn append(self: *Self, item: T) AppendError!void {
            if (self.flushing) return error.AppendWhileFlushing;
            if (self.count == N) return error.Full;
            self.items[self.count] = item;
            self.count += 1;
        }

        pub fn flush(self: *Self) FlushError!Iter {
            if (self.flushing) return error.FlushWhileFlushing;
            self.flushing = true;
            return Self.Iter{ .topic = self };
        }

        const Iter = struct {
            topic: *Self,
            idx: usize = 0,

            pub fn next(self: *@This()) ?*T {
                if (self.idx >= self.topic.count) {
                    self.topic.count = 0;
                    self.topic.flushing = false;
                    return null;
                }
                defer self.idx += 1;
                return &self.topic.items[self.idx];
            }
        };
    };
}

// asked community about avoiding this boilerplate by writing metaprogramming/comptime struct def but it didnt go anywhere.
// its something like comptime pub fn blah blah. Living with the boilerplate for now.
pub var walk: Topic(sig.Walk, DEFAULT_SZ) = .{};
pub var connect: Topic(sig.Connect, DEFAULT_SZ) = .{};
pub var disconnect: Topic(sig.Disconnect, DEFAULT_SZ) = .{};
pub var look: Topic(sig.Look, DEFAULT_SZ) = .{};
pub var attack: Topic(sig.Attack, DEFAULT_SZ) = .{};
pub var move: Topic(sig.Move, DEFAULT_SZ) = .{};
pub var emit: Topic(sig.Emit, DEFAULT_SZ) = .{};
pub var outbound: Topic(sig.Outbound, 256) = .{};

pub fn enqueue(signal: sig.Signal) AppendError!void {
    switch (signal) {
        .Walk => |v| try walk.append(v),
        .Connect => |v| try connect.append(v),
        .Disconnect => |v| try disconnect.append(v),
        .Look => |v| try look.append(v),
        .Attack => |v| try attack.append(v),
        .Move => |v| try move.append(v),
        .Emit => |v| try emit.append(v),
        .Outbound => |v| try outbound.append(v),
    }
}

test "core/bus.zig: simple read and write" {
    try enqueue(.{ .Walk = .{ .source = 1, .dir = .north } });

    var it = try walk.flush();
    try std.testing.expect(it.next() != null);
    try std.testing.expect(it.next() == null);
}
