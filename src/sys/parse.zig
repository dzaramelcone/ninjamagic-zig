const std = @import("std");
const core = @import("core");
const Request = core.Request;
const Signal = core.Signal;
pub const ParseError = error{
    NothingSent,
    NotYetImplemented,
    UnknownVerb,
    SaidNothing,
};
pub fn parse(req: Request) ParseError!Signal {
    const input = req.text;
    if (input.len > 0 and input[0] == '\'') {
        return Say.parse(req.user, input[1..]);
    }

    var tokens = std.mem.tokenizeScalar(u8, input, ' ');
    const word = tokens.next() orelse return error.NothingSent;
    inline for (parsers) |P| if (matches(P, word)) {
        ensureParser(P);
        return P.parse(req.user, if (req.text.len == word.len) "" else req.text[word.len + 1 ..]);
    };
    return error.UnknownVerb;
}

fn matches(cmd: anytype, word: []const u8) bool {
    if (word.len < cmd.min_len) return false;
    if (word.len > cmd.verb.len) return false;
    return std.ascii.eqlIgnoreCase(word, cmd.verb[0..word.len]);
}

fn ensureParser(comptime P: type) void {
    comptime {
        if (!@hasDecl(P, "verb") or
            !@hasDecl(P, "min_len") or
            !@hasDecl(P, "parse"))
        {
            @compileError(@typeName(P) ++ " does not satisfy the parser interface");
        }
    }
}

const Say = struct {
    pub const verb: []const u8 = "say";
    pub const min_len: usize = 3;

    pub fn parse(source: usize, args: []const u8) !Signal {
        return if (args.len == 0) error.SaidNothing else .{ .Say = .{ .speaker = source, .text = args } };
    }
};

pub const Look = struct {
    pub const verb: []const u8 = "look";
    pub const min_len: usize = 1;

    pub fn parse(_: usize, _: []const u8) !Signal {
        return error.NotYetImplemented;
    }
};

const Attack = struct {
    pub const verb: []const u8 = "attack";
    pub const min_len: usize = 1;
    pub fn parse(_: usize, _: []const u8) !Signal {
        return error.NotYetImplemented;
    }
};

fn Walk(
    comptime Verb: []const u8,
    comptime MinLen: usize,
    comptime Dir: core.Cardinal,
) type {
    return struct {
        pub const verb = Verb;
        pub const min_len = MinLen;
        pub const dir = Dir;

        pub fn parse(source: usize, _: []const u8) !Signal {
            return .{ .Walk = .{ .mob = source, .dir = dir } };
        }
    };
}
const N = Walk("north", 1, .north);
const NE = Walk("ne", 2, .northeast);
const E = Walk("east", 1, .east);
const SE = Walk("se", 2, .southeast);
const S = Walk("south", 1, .south);
const SW = Walk("sw", 2, .southwest);
const W = Walk("west", 1, .west);
const NW = Walk("nw", 2, .northwest);

const parsers = .{
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
    try raises(error.NothingSent, parse(.{ .user = 0, .text = "" }));
    try raises(error.UnknownVerb, parse(.{ .user = 0, .text = "foobar" }));

    try std.testing.expectEqualDeep(parse(.{
        .user = 0,
        .text = "'north",
    }), Signal{ .Say = .{ .speaker = 0, .text = "north" } });

    try raises(error.NotYetImplemented, parse(.{ .user = 0, .text = "a" }));
    try raises(error.NotYetImplemented, parse(.{ .user = 0, .text = "attack Bob" }));
    try raises(error.NotYetImplemented, parse(.{ .user = 0, .text = "AtTaCk alice" }));
    const cases = [_]struct { verb: []const u8, dir: core.Cardinal }{
        .{ .verb = "n", .dir = .north },
        .{ .verb = "ne", .dir = .northeast },
        .{ .verb = "e", .dir = .east },
        .{ .verb = "se", .dir = .southeast },
        .{ .verb = "s", .dir = .south },
        .{ .verb = "sw", .dir = .southwest },
        .{ .verb = "w", .dir = .west },
    };
    for (cases) |case| {
        try std.testing.expectEqualDeep(parse(.{
            .user = 0,
            .text = case.verb,
        }), Signal{ .Walk = .{ .mob = 0, .dir = case.dir } });
    }
}
