const std = @import("std");

pub const Seconds = f64;
pub const PlayerId = u32;

const Position = struct {
    x: u16,
    y: u16,
};

const Attack = struct {
    player: PlayerId,
    start_time: Seconds,
    cancelled: bool = false,
};

const Block = struct {
    player: PlayerId,
    start_time: Seconds,
    active_until: Seconds,
    lag_end: Seconds,
};

const Stun = struct {
    player: PlayerId,
    end_time: Seconds,
};

const State = struct {
    alloc: std.mem.Allocator,
    positions: std.ArrayList(Position)
    attack_queue: std.ArrayList(AttackEntry),
    attack_head: usize,
    blocks: std.ArrayList(Block),
    stuns: std.ArrayList(Stun),

    pub fn init(allocator: std.mem.Allocator) !*State {
        const self = try allocator.create(State);
        self.* = .{
            .allocator = allocator,
            .attack_queue = std.ArrayList(Attack).init(allocator),
            .attack_head = 0,
            .blocks = std.ArrayList(Block).init(allocator),
            .stuns = std.ArrayList(Stun).init(allocator),
        };
        return self;
    }

    pub fn deinit(self: *State) void {
        self.attack_queue.deinit();
        self.blocks.deinit();
        self.stuns.deinit();
        self.alloc.destroy(self);
    }

    pub fn step(self: *State, time: Seconds) void {
        // expire blocks and stuns
        self.blocks.retain((struct {
            fn keep(b: Block, now: Seconds) bool {
                return now < b.lag_end;
            }
        }).keep, time);
        self.stuns.retain((struct {
            fn keep(s: Stun, now: Seconds) bool {
                return now < s.end_time;
            }
        }).keep, time);

        // process attack queue head(s)
        while (self.attack_head < self.attack_queue.items.len) {
            const entry = self.attack_queue.items[self.attack_head];
            if (entry.cancelled) {
                self.attack_head += 1;
                continue;
            }
            // wait until attack delay elapsed
            if (time < entry.start_time + 2.0) break;

            // resolve hit or block
            var blocked: ?*Block = null;
            for (self.blocks.items) |*b| {
                if (b.player != entry.player and entry.start_time + 2.0 >= b.start_time and entry.start_time + 2.0 <= b.active_until) {
                    blocked = b;
                    break;
                }
            }
            if (blocked) |b| {
                std.debug.print("[{d:.2}] Attack by {d} was BLOCKED by {d}\n", .{ time, entry.player, b.player });
                // end lag early
                b.lag_end = time;
                // stun attacker
                self.stuns.append(.{
                    .player = entry.player,
                    .end_time = time + 3.0,
                }) catch {};
            } else {
                std.debug.print("[{d:.2}] Attack by {d} CONNECTED!\n", .{ time, entry.player });
            }
            self.attack_head += 1;
        }
    }

    pub fn isStunned(self: *State, player: PlayerId, now: Seconds) bool {
        for (self.stuns.items) |s| {
            if (s.player == player and now < s.end_time) return true;
        }
        return false;
    }

    pub fn enqueueAttack(self: *State, player: PlayerId, now: Seconds) !void {
        // if player already has a pending attack, cancel it
        for (self.attack_head..self.attack_queue.items.len) |i| {
            var entry = &self.attack_queue.items[i];
            if (entry.player == player and !entry.cancelled) {
                entry.cancelled = true;
            }
        }
        try self.attack_queue.append(.{
            .player = player,
            .start_time = now,
            .cancelled = false,
        });
    }

    pub fn enqueueBlock(self: *State, player: PlayerId, now: Seconds) !void {
        if (self.isStunned(player, now)) return;
        try self.blocks.append(.{
            .player = player,
            .start_time = now,
            .active_until = now + 0.8,
            .lag_end = now + 3.0,
        });
    }
};
