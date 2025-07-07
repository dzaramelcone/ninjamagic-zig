pub fn Channel(comptime T: type, comptime N: usize) type {
    return struct {
        var active_write: u8 = 0;            // 0 or 1 (atomic)
        rings: [2][N]T = undefined,
        write_idx: [2]std.atomic.Size = .{ .{ .value = 0 }, .{ .value = 0 } };

        /// Producer-side
        pub fn push(self: *@This(), item: T) bool {
            const w = @atomicLoad(u8, &active_write, .Acquire);
            const idx = self.write_idx[w].fetchAdd(1, .Release);
            if (idx >= N) return false;       // overflow – drop or spin
            self.rings[w][idx] = item;
            return true;
        }

        /// Consumer-side: returns slice of items just flipped into read view.
        pub fn flip(self: *@This()) []const T {
            const old = @atomicRmw(u8, &active_write, .Xchg, 1 ^ active_write, .AcqRel);
            const w_idx = self.write_idx[old].swap(0, .Acquire);
            return self.rings[old][0 .. w_idx];
        }
    };
}
