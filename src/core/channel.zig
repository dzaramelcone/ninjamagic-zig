const std = @import("std");

pub fn Channel(comptime T: type, N: usize) type {
    return struct {
        active_write: std.atomic.Value(u8) = .{ .raw = 0 },
        rings: [2][N]T = undefined,
        write_idx: [2]std.atomic.Value(usize) = .{ .{ .raw = 0 }, .{ .raw = 0 } },

        pub fn push(self: *@This(), item: T) bool {
            const w = self.active_write.load(.acquire);
            const idx = self.write_idx[w].fetchAdd(1, .monotonic);
            if (idx >= N) return false;
            self.rings[w][idx] = item;
            return true;
        }

        pub fn flip(self: *@This()) []const T {
            const old = self.active_write.fetchXor(1, .acq_rel);
            const count = self.write_idx[old].swap(0, .acquire);
            return self.rings[old][0..@min(count, N)];
        }
    };
}

const cap = std.math.pow(usize, 2, 14);

test "basic queue stuff" {
    var q = Channel(usize, 8){};
    try std.testing.expect(q.push(0));
    try std.testing.expect(q.push(1));
    try std.testing.expect(q.push(2));
    for (0.., q.flip()) |i, val| try std.testing.expectEqual(i, val);
    for (q.flip()) |_| unreachable;
}

test "producer overflow returns false" {
    var chan = Channel(usize, 8){};
    for (0..8) |i| try std.testing.expect(chan.push(i));
    try std.testing.expect(!chan.push(255));
    var list = try std.ArrayList(usize).initCapacity(std.testing.allocator, 8);
    defer list.deinit();
    for (chan.flip()) |val| list.appendAssumeCapacity(val);
    try std.testing.expectEqual(8, list.items.len);
}

fn producer(
    chan: *Channel(usize, cap),
    id: usize,
    pushes: usize,
    left: *std.atomic.Value(usize),
) void {
    const base = id << 24;
    for (0..pushes) |n| {
        while (!chan.push(base | n)) std.Thread.sleep(16_000_000);
        std.Thread.sleep(2_000_000);
    }
    _ = left.fetchSub(1, .acq_rel); // signal done
}

test "soak 2k producers + concurrent consumer" {
    const producers = 2000;
    const pushes = 2000; // per producer

    var chan = Channel(usize, cap){};

    var writers_left = std.atomic.Value(usize).init(producers);
    var threads: [producers]std.Thread = undefined;
    for (0..producers) |i| {
        threads[i] = try std.Thread.spawn(.{}, producer, .{ &chan, i, pushes, &writers_left });
    }

    var seen = std.AutoHashMap(usize, void).init(std.testing.allocator);
    try seen.ensureTotalCapacity(producers * pushes);
    defer seen.deinit();

    while (writers_left.load(.acquire) != 0) {
        for (chan.flip()) |val| try seen.putNoClobber(val, {});
        std.Thread.sleep(16_000_000);
    }
    for (threads) |t| t.join();
    for (chan.flip()) |val| try seen.putNoClobber(val, {});

    try std.testing.expectEqual(producers * pushes, seen.count());
}
