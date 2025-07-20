const std = @import("std");

const Mode = enum {
    find_directive,
    reading_directive_name,
    content_line,
    content_start,
};

// s will return the section from the data, as a comptime known string
pub fn s(comptime str: []const u8, comptime directive: ?[]const u8) []const u8 {
    comptime var mode: Mode = .find_directive;
    comptime var maybe_directive_start = 0;
    comptime var directive_start = 0;
    comptime var content_start = 0;
    comptime var content_end = 0;
    comptime var last_start_of_line = 0;

    @setEvalBranchQuota(1_000_000);

    inline for (str, 0..) |c, index| {
        switch (mode) {
            .find_directive => {
                switch (c) {
                    '.' => {
                        maybe_directive_start = index;
                        mode = .reading_directive_name;
                        // @compileLog("maybe new directive at", maybe_directive_start);
                    },
                    ' ', '\t' => {}, // eat whitespace
                    '\n' => {
                        last_start_of_line = index + 1;
                    },
                    else => mode = .content_start,
                }
            },
            .reading_directive_name => {
                switch (c) {
                    '\n' => {
                        if (directive == null) {
                            // then content is the first unlabelled block, so we can return now
                            return str[0..last_start_of_line];
                        }
                        if (content_end > 0) {
                            // that really was a directive following our content then, so we now have the content we are looking for
                            content_end = last_start_of_line;
                            return str[content_start..content_end];
                        }
                        // found a new directive - we need to patch the value of the previous content then
                        directive_start = maybe_directive_start;
                        const directive_name = if (str[index - 1] == '\r')
                            str[directive_start + 1 .. index - 1]
                        else
                            str[directive_start + 1 .. index];
                        content_start = index + 1;
                        if (comptime std.mem.eql(u8, directive_name, directive.?)) {
                            content_end = str.len - 1;
                            // @compileLog("found directive in data", directive_name, "starts at", content_start, "runs to", content_end);
                        }
                        mode = .content_start;
                    },
                    ' ', '\t', '.', '{', '}', '[', ']', ':' => { // invalid chars for directive name
                        // @compileLog("false alarm scanning directive, back to content", str[maybe_directive_start .. index + 1]);
                        mode = .content_start;
                        maybe_directive_start = directive_start;
                    },
                    else => {},
                }
            },
            .content_start => {
                // if the first non-whitespace char of content is a .
                // then we are in find directive mode !
                switch (c) {
                    '\n' => {
                        mode = .find_directive;
                        last_start_of_line = index + 1;
                    },
                    ' ', '\t' => {}, // eat whitespace
                    '.' => {
                        // thinks we are looking for content, but last directive
                        // was empty, so start a new directive on this line
                        maybe_directive_start = index;
                        last_start_of_line = content_start;
                        mode = .reading_directive_name;
                    },
                    else => {
                        mode = .content_line;
                    },
                }
            },
            .content_line => { // just eat the rest of the line till the next line
                switch (c) {
                    '\n' => {
                        mode = .find_directive;
                        last_start_of_line = index + 1;
                    },
                    else => {},
                }
            },
        }
    }

    if (content_end > 0) {
        return str[content_start .. content_end + 1];
    }

    if (directive == null) {
        return str;
    }

    const directiveNotFound = "Data does not contain any section labelled '" ++ directive.? ++ "'\nMake sure there is a line in your data that start with ." ++ directive.?;
    @compileError(directiveNotFound);
}

// lookup will return the section from the data, as a runtime known string, or null if not found
pub fn lookup(str: []const u8, directive: ?[]const u8) ?[]const u8 {
    var mode: Mode = .find_directive;
    var maybe_directive_start: usize = 0;
    var directive_start: usize = 0;
    var content_start: usize = 0;
    var content_end: usize = 0;
    var last_start_of_line: usize = 0;

    for (str, 0..) |c, index| {
        switch (mode) {
            .find_directive => {
                switch (c) {
                    '.' => {
                        maybe_directive_start = index;
                        mode = .reading_directive_name;
                        // @compileLog("maybe new directive at", maybe_directive_start);
                    },
                    ' ', '\t' => {}, // eat whitespace
                    '\n' => {
                        last_start_of_line = index + 1;
                    },
                    else => mode = .content_start,
                }
            },
            .reading_directive_name => {
                switch (c) {
                    '\n' => {
                        if (directive == null) {
                            // then content is the first unlabelled block, so we can return now
                            return str[0..last_start_of_line];
                        }
                        if (content_end > 0) {
                            // that really was a directive following our content then, so we now have the content we are looking for
                            content_end = last_start_of_line;
                            return str[content_start..content_end];
                        }
                        // found a new directive - we need to patch the value of the previous content then
                        directive_start = maybe_directive_start;
                        const directive_name = if (str[index - 1] == '\r')
                            str[directive_start + 1 .. index - 1]
                        else
                            str[directive_start + 1 .. index];
                        content_start = index + 1;
                        if (std.mem.eql(u8, directive_name, directive.?)) {
                            content_end = str.len - 1;
                            // @compileLog("found directive in data", directive_name, "starts at", content_start, "runs to", content_end);
                        }
                        mode = .content_start;
                    },
                    ' ', '\t', '.', '{', '}', '[', ']', ':' => { // invalid chars for directive name
                        // @compileLog("false alarm scanning directive, back to content", str[maybe_directive_start .. index + 1]);
                        mode = .content_start;
                        maybe_directive_start = directive_start;
                    },
                    else => {},
                }
            },
            .content_start => {
                // if the first non-whitespace char of content is a .
                // then we are in find directive mode !
                switch (c) {
                    '\n' => {
                        mode = .find_directive;
                        last_start_of_line = index + 1;
                    },
                    ' ', '\t' => {}, // eat whitespace
                    '.' => {
                        // thinks we are looking for content, but last directive
                        // was empty, so start a new directive on this line
                        maybe_directive_start = index;
                        last_start_of_line = content_start;
                        mode = .reading_directive_name;
                    },
                    else => {
                        mode = .content_line;
                    },
                }
            },
            .content_line => { // just eat the rest of the line till the next line
                switch (c) {
                    '\n' => {
                        mode = .find_directive;
                        last_start_of_line = index + 1;
                    },
                    else => {},
                }
            },
        }
    }

    if (content_end > 0) {
        return str[content_start .. content_end + 1];
    }

    if (directive == null) {
        return str;
    }

    return null;
}

pub fn printHeader(comptime str: []const u8, args: anytype, out: anytype) !void {
    try out.print(comptime s(str, null), args);
}

pub fn print(comptime str: []const u8, comptime section: []const u8, args: anytype, out: anytype) !void {
    try out.print(comptime s(str, section), args);
}

pub fn writeHeader(str: []const u8, out: anytype) !void {
    const data = lookup(str, null);
    if (data != null) try out.writeAll(data.?);
}

pub fn write(str: []const u8, section: []const u8, out: anytype) !void {
    const data = lookup(str, section);
    if (data != null) try out.writeAll(data.?);
}
