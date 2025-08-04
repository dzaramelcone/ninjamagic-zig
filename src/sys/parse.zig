const std = @import("std");
const core = @import("core");
const Request = core.sig.Request;
const Signal = core.sig.Signal;

pub const ParseError = error{
    NotYetImplemented,
    UnknownVerb,
    NothingSaid,
};

fn toPlayer(user: usize, err: ParseError) Signal {
    return .{
        .Outbound = .{
            .Message = .{
                .to = user,
                .text = switch (err) {
                    error.UnknownVerb => "Huh?",
                    error.NothingSaid => "You open your mouth, as if to speak.",
                    error.NotYetImplemented => "That feature isn't ready yet.",
                },
            },
        },
    };
}

pub fn parse(req: Request) error{NoInput}!Signal {
    const input = req.text;
    if (input.len > 0 and input[0] == '\'') {
        return Say.parse(req.user, input[1..]) catch |err| toPlayer(req.user, err);
    }

    var tokens = std.mem.tokenizeScalar(u8, input, ' ');
    const first = tokens.next() orelse return error.NoInput;
    const rest = if (req.text.len == first.len) "" else req.text[first.len + 1 ..];
    inline for (parsers) |P| if (matches(P, first)) {
        ensureParser(P);
        return P.parse(req.user, rest) catch |err| toPlayer(req.user, err);
    };

    return toPlayer(req.user, error.UnknownVerb);
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
        const trimmed = std.mem.trim(u8, args, " \t\r\n");
        return if (trimmed.len == 0)
            error.NothingSaid
        else
            .{ .Emit = .{ .Say = .{ .source = source, .text = trimmed, .reach = .Sight } } };
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

fn Walk(comptime Verb: []const u8, comptime MinLen: usize, comptime Dir: core.Cardinal) type {
    return struct {
        pub const verb = Verb;
        pub const min_len = MinLen;
        pub const dir = Dir;

        pub fn parse(source: usize, _: []const u8) !Signal {
            return .{ .Walk = .{ .source = source, .dir = dir } };
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

test "basic verbs and error cases" {
    try std.testing.expectError(error.NoInput, parse(.{ .user = 0, .text = "" }));
    try std.testing.expectEqualDeep(
        try parse(.{ .user = 0, .text = "foobar" }),
        Signal{ .Outbound = .{ .Message = .{ .to = 0, .text = "Huh?" } } },
    );

    try std.testing.expectEqualDeep(parse(.{
        .user = 0,
        .text = "'north ",
    }), Signal{ .Emit = .{ .Say = .{ .source = 0, .text = "north", .reach = .Sight } } });

    const not_yet_implemented_cases = [_][]const u8{ "look", "a", "attack Bob", "AtTaCk alice" };
    for (not_yet_implemented_cases) |txt| {
        try std.testing.expectEqualDeep(
            try parse(.{ .user = 0, .text = txt }),
            Signal{ .Outbound = .{ .Message = .{ .to = 0, .text = "That feature isn't ready yet." } } },
        );
    }
    const ur_quiet_cases = [_][]const u8{ "'", "' ", "say", "say   " };
    for (ur_quiet_cases) |txt| {
        try std.testing.expectEqualDeep(
            try parse(.{ .user = 0, .text = txt }),
            Signal{ .Outbound = .{ .Message = .{ .to = 0, .text = "You open your mouth, as if to speak." } } },
        );
    }
    const walk_in_a_dir_cases = [_]struct { verb: []const u8, dir: core.Cardinal }{
        .{ .verb = "n", .dir = .north },
        .{ .verb = "Ne", .dir = .northeast },
        .{ .verb = "e  ", .dir = .east },
        .{ .verb = "se", .dir = .southeast },
        .{ .verb = " s", .dir = .south },
        .{ .verb = " sw ", .dir = .southwest },
        .{ .verb = "w", .dir = .west },
    };
    for (walk_in_a_dir_cases) |case| {
        try std.testing.expectEqualDeep(parse(.{
            .user = 0,
            .text = case.verb,
        }), Signal{ .Walk = .{ .source = 0, .dir = case.dir } });
    }
}
