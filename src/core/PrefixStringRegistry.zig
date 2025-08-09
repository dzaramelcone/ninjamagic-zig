const std = @import("std");
const AnyCaseStringMap = @import("AnyCaseStringMap.zig").AnyCaseStringMap;

pub const PrefixStringRegistry = struct {
    alloc: std.mem.Allocator,
    map: AnyCaseStringMap(u16),

    pub fn init(alloc: std.mem.Allocator) PrefixStringRegistry {
        return .{
            .alloc = alloc,
            .map = AnyCaseStringMap(u16).init(alloc),
        };
    }
    pub fn deinit(self: *PrefixStringRegistry) void {
        self.map.deinit();
    }

    pub fn upsert(self: *PrefixStringRegistry, id: u16, name: []const u8) !void {
        try self.map.put(name, id);
    }

    pub fn idOf(self: *PrefixStringRegistry, name: []const u8) ?u16 {
        return self.map.get(name);
    }
    pub fn matchPrefix(self: *PrefixStringRegistry, prefix_raw: []const u8) ?u16 {
        if (prefix_raw.len == 0) return null;
        var buf: [64]u8 = undefined;
        const prefix = std.ascii.lowerString(&buf, prefix_raw);

        var it = self.map.iterator();
        while (it.next()) |entry| {
            const name = entry.key_ptr.*;
            if (iStartsWith(name, prefix)) return entry.value_ptr.*;
        }
        return null;
    }
    fn iStartsWith(haystack: []const u8, needle: []const u8) bool {
        if (haystack.len < needle.len) return false;
        for (needle, 0..) |nb, i| {
            if (std.ascii.toLower(nb) != std.ascii.toLower(haystack[i]))
                return false;
        }
        return true;
    }
};

test "core/PrefixStringRegistry.zig: upsert / idOf / matchPrefix" {
    const gpa = std.testing.allocator;

    var reg = PrefixStringRegistry.init(gpa);
    defer reg.deinit();

    // Insert three players with deliberately tricky casing
    try reg.upsert(1, "Alice");
    try reg.upsert(2, "ALICE2");
    try reg.upsert(3, "Bob");

    // idOf must be case-insensitive
    try std.testing.expectEqual(@as(?u16, 1), reg.idOf("alice"));
    try std.testing.expectEqual(@as(?u16, 1), reg.idOf("ALICE"));
    try std.testing.expectEqual(@as(?u16, 3), reg.idOf("bOB"));
    try std.testing.expectEqual(@as(?u16, null), reg.idOf("charlie"));

    // matchPrefix – unique hit succeeds
    try std.testing.expectEqual(@as(?u16, 1), reg.matchPrefix("ali"));
    try std.testing.expectEqual(@as(?u16, 3), reg.matchPrefix("bo"));

    // matchPrefix – zero-length prefix = null
    try std.testing.expectEqual(@as(?u16, null), reg.matchPrefix(""));

    //  Both “alice” and “alice2” match “alic”, so ambiguity. this might be nondeterministic.
    try std.testing.expectEqual(@as(?u16, 1), reg.matchPrefix("alic"));

    // matchPrefix – no match at all ⇒ null
    try std.testing.expectEqual(@as(?u16, null), reg.matchPrefix("z"));
}

test "core/PrefixStringRegistry.zig: round-trip fuzz" {
    const gpa = std.testing.allocator;
    var reg = PrefixStringRegistry.init(gpa);
    defer reg.deinit();
    const IdType = u16;

    // deterministic RNG
    var prng = std.Random.DefaultPrng.init(0xDEADBEEFCAFEBABE);
    const rng = prng.random();

    const max_names = 200;
    const max_len = 10;
    var names = try std.ArrayList([]const u8).initCapacity(gpa, max_names);
    defer {
        for (names.items) |s| gpa.free(s);
        names.deinit();
    }

    // generate unique lower-case names
    var id: IdType = 1;
    while (names.items.len < max_names) {
        var buf: [max_len]u8 = undefined;
        const len = rng.intRangeAtMostBiased(usize, 3, max_len);
        for (buf[0..len]) |*c| c.* = rng.intRangeLessThan(u8, 'a', 'z' + 1);

        const name = gpa.dupe(u8, buf[0..len]) catch unreachable;

        // ensure uniqueness wrt case-insensitive map
        if (reg.idOf(name) != null) {
            gpa.free(name);
            continue; // collision – try again
        }

        try reg.upsert(id, name);
        try names.append(name);
        id += 1;
    }

    // now fuzz queries
    const trials = 1_000;
    var tmp_buf: [max_len]u8 = undefined;

    for (0..trials) |_| {
        // pick a random inserted name
        const idx = rng.uintLessThan(usize, names.items.len);
        const orig = names.items[idx];

        // idOf with random casing
        for (orig, 0..) |c, i| tmp_buf[i] = if (rng.boolean()) std.ascii.toUpper(c) else c;
        const cased = tmp_buf[0..orig.len];
        try std.testing.expect(reg.idOf(orig) == reg.idOf(cased));

        // random prefix query
        const pref_len = rng.intRangeAtMostBiased(usize, 1, orig.len);
        const pref = orig[0..pref_len];

        const got = reg.matchPrefix(pref);

        // reference: verify whatever we got is a valid prefix match (or null if no match)
        if (got) |gid| {
            // look the name up and confirm it shares the prefix (case-insensitive)
            const nm = names.items[gid - 1]; // IDs start at 1
            try std.testing.expect(PrefixStringRegistry.iStartsWith(nm, pref));
        } else {
            // there truly must be no matches
            var any = false;
            for (names.items) |nm| {
                if (PrefixStringRegistry.iStartsWith(nm, pref)) any = true;
            }
            try std.testing.expect(!any);
        }
    }
}
