const std = @import("std");
const core = @import("core");
const State = @import("state.zig").State;

pub fn parse(input: []const u8) !void {
    if (input.len > 0 and input[0] == '\'') {
        try Say.gather(input);
        try Say.run(input);
        return;
    }
    var tokens = std.mem.tokenizeScalar(u8, input, ' ');
    const word = tokens.next() orelse return error.NothingSent;
    inline for (cmds) |C| if (matches(C, word)) {
        ensureCommand(C);
        try C.gather(input);
        try C.run(input);
        return;
    };
    return error.UnknownVerb;
}

fn matches(cmd: anytype, word: []const u8) bool {
    if (word.len < cmd.min_len) return false;
    if (word.len > cmd.verb.len) return false;
    return std.ascii.eqlIgnoreCase(word, cmd.verb[0..word.len]);
}

fn ensureCommand(comptime C: type) void {
    comptime {
        if (!@hasDecl(C, "verb") or
            !@hasDecl(C, "min_len") or
            !@hasDecl(C, "gather") or
            !@hasDecl(C, "run"))
        {
            @compileError(@typeName(C) ++ " does not satisfy the Command interface");
        }
    }
}

const Say = struct {
    pub const verb: []const u8 = "say";
    pub const min_len: usize = 3;

    pub fn gather(_: []const u8) !void {
        return error.NotYetImplemented;
    }
    pub fn run(_: []const u8) !void {
        return error.NotYetImplemented;
    }
};

pub const Look = struct {
    pub const verb: []const u8 = "look";
    pub const min_len: usize = 1;

    pub fn gather(_: []const u8) !void {
        return error.NotYetImplemented;
    }
    pub fn run(_: []const u8) !void {
        return error.NotYetImplemented;
    }
};

const Attack = struct {
    pub const verb: []const u8 = "attack";
    pub const min_len: usize = 1;

    fn gather(_: []const u8) !void {
        return error.NotYetImplemented;
    }
    fn run(_: []const u8) !void {
        return error.NotYetImplemented;
    }
};

fn Move(
    comptime Verb: []const u8,
    comptime MinLen: usize,
    Dir: core.Cardinal,
) type {
    return struct {
        pub const verb = Verb;
        pub const min_len = MinLen;
        pub const dir = Dir;

        pub fn gather(_: []const u8) !void {
            return error.NotYetImplemented;
        }
        pub fn run(_: []const u8) !void {
            return error.NotYetImplemented;
        }
    };
}
const N = Move("north", 1, .north);
const NE = Move("ne", 2, .northeast);
const E = Move("east", 1, .east);
const SE = Move("se", 2, .southeast);
const S = Move("south", 1, .south);
const SW = Move("sw", 2, .southwest);
const W = Move("west", 1, .west);
const NW = Move("nw", 2, .northwest);

const cmds = .{
    Say,
    Look,
    Attack,
    N,
    NE,
    E,
    SE,
    S,
    SW,
    W,
    NW,
};
const raises = std.testing.expectError;
test "parser – basic verbs and error cases" {

    // 1.  Empty input  →  NothingSent
    try raises(error.NothingSent, parse(""));
    try raises(error.UnknownVerb, parse("foobar"));

    try raises(error.NotYetImplemented, parse("'blah"));

    try raises(error.NotYetImplemented, parse("a"));
    try raises(error.NotYetImplemented, parse("attack Bob"));
    try raises(error.NotYetImplemented, parse("AtTaCk alice"));

    try raises(error.NotYetImplemented, parse("north"));
    try raises(error.NotYetImplemented, parse("ne")); // maps to northeast
    try raises(error.NotYetImplemented, parse("nw")); // northwest

}
