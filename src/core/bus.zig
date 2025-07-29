const std = @import("std");
const sig = @import("sig.zig");

const DEFAULT_SZ = 512;

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
const WalkTopic = Topic(sig.Walk, DEFAULT_SZ);
const LookTopic = Topic(sig.Look, DEFAULT_SZ);
const SayTopic = Topic(sig.Say, DEFAULT_SZ);
const AttackTopic = Topic(sig.Attack, DEFAULT_SZ);
const OutboundTopic = Topic(sig.Outbound, DEFAULT_SZ);

pub var walk: WalkTopic = .{};
pub var look: LookTopic = .{};
pub var say: SayTopic = .{};
pub var attack: AttackTopic = .{};
pub var outbound: OutboundTopic = .{};

pub fn enqueue(signal: sig.Signal) AppendError!void {
    switch (signal) {
        .Walk => |v| try walk.append(v),
        .Look => |v| try look.append(v),
        .Say => |v| try say.append(v),
        .Attack => |v| try attack.append(v),
        .Outbound => |v| try outbound.append(v),
    }
}

test "bus read/write" {
    try walk.append(sig.Walk{ .mob = 1, .dir = .north });

    var it = try walk.flush();
    try std.testing.expect(it.next() != null);
    try std.testing.expect(it.next() == null);
}
