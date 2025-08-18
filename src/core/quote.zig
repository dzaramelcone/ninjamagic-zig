const std = @import("std");
const AnyCaseStringMap = @import("AnyCaseStringMap.zig").AnyCaseStringMap;

pub fn quote(writer: anytype, text: []const u8, safe: []const u8) !void {
    for (text) |c| switch (c) {
        'a'...'z', 'A'...'Z', '0'...'9', '-', '_', '.', '~' => {
            try writer.writeByte(c);
        },
        ' ' => {
            try writer.writeByte('+');
        },
        else => {
            if (std.mem.indexOf(u8, safe, &.{c}) != null) {
                try writer.writeByte(c);
            } else {
                try writer.print("%{X:02}", .{c});
            }
        },
    };
}

/// Formats a slice of key-value pairs into a URL-encoded query string.
pub fn quoteParams(writer: anytype, params: []const [2][]const u8) !void {
    var first_pair = true;
    for (params) |pair| {
        if (!first_pair) {
            try writer.writeByte('&');
        } else {
            first_pair = false;
        }
        try quote(writer, pair[0], "");
        try writer.writeByte('=');
        try quote(writer, pair[1], "");
    }
}

/// Formats a map of key-value pairs into a URL-encoded query string.
pub fn quoteParamsMap(writer: anytype, params: AnyCaseStringMap([]const u8)) !void {
    var first_pair = true;
    var iterator = params.iterator();
    while (iterator.next()) |pair| {
        if (!first_pair) {
            try writer.writeByte('&');
        } else {
            first_pair = false;
        }
        try quote(writer, pair.key_ptr.*, "");
        try writer.writeByte('=');
        try quote(writer, pair.value_ptr.*, "");
    }
}

/// A comptime function that generates a serializer for a given struct type `T`.
/// The generated type can serialize an instance of `T` into the
/// `application/x-www-form-urlencoded` format.
pub fn Form(comptime T: type) type {
    // Ensure at compile time that the provided type is a struct.
    comptime std.debug.assert(@typeInfo(T) == .@"struct");

    return struct {
        /// Serializes an instance of the struct `T` to the given writer.
        pub fn encode(writer: anytype, data: T) !void {
            var first_pair = true;
            const struct_info = @typeInfo(T).@"struct";

            inline for (struct_info.fields) |field| {
                const should_skip = @typeInfo(field.type) == .optional and @field(data, field.name) == null;
                if (!should_skip) {
                    if (!first_pair) {
                        try writer.writeByte('&');
                    }
                    first_pair = false;

                    // URL-encode the field name.
                    try quote(writer, field.name, "");
                    try writer.writeByte('=');

                    // Get the field's value and format it to a string.
                    var buffer: [256]u8 = undefined;

                    const value_slice = blk: {
                        const field_type = field.type;
                        const T_info = @typeInfo(field_type);

                        // Path 1: for `[]const u8`
                        if (T_info == .pointer and T_info.pointer.size == .slice and T_info.pointer.child == u8) {
                            break :blk try std.fmt.bufPrint(&buffer, "{s}", .{@field(data, field.name)});
                        }
                        // Path 2: for `?[]const u8`
                        else if (T_info == .optional and @typeInfo(T_info.optional.child) == .pointer and @typeInfo(T_info.optional.child).pointer.size == .slice and @typeInfo(T_info.optional.child).pointer.child == u8) {
                            // We already checked for null, so we can safely unwrap with .?
                            break :blk try std.fmt.bufPrint(&buffer, "{s}", .{@field(data, field.name).?});
                        }
                        // Path 3: for all other types
                        else {
                            break :blk try std.fmt.bufPrint(&buffer, "{any}", .{@field(data, field.name)});
                        }
                    };

                    // URL-encode the resulting value string.
                    try quote(writer, value_slice, "");
                }
            }
        }
    };
}

const UserProfile = struct {
    username: []const u8,
    age: u32,
    is_active: bool,
    bio: ?[]const u8 = null,
};

test "core/quote.zig: basic struct to form" {
    const profile = UserProfile{
        .username = "Zig User",
        .age = 5,
        .is_active = true,
    };

    // Generate the specific serializer for UserProfile
    const UserProfileSerializer = Form(UserProfile);

    var buffer: [100]u8 = undefined;
    var fbs = std.io.fixedBufferStream(&buffer);

    try UserProfileSerializer.encode(fbs.writer(), profile);
    const result = fbs.getWritten();

    const expected = "username=Zig+User&age=5&is_active=true";
    try std.testing.expectEqualStrings(expected, result);
}

test "core/quote.zig: struct to form with special chars" {
    const profile = UserProfile{
        .username = "foo&bar=baz",
        .age = 99,
        .is_active = false,
        .bio = "A bio with spaces & symbols!",
    };

    const UserProfileSerializer = Form(UserProfile);

    var buffer: [200]u8 = undefined;
    var fbs = std.io.fixedBufferStream(&buffer);

    try UserProfileSerializer.encode(fbs.writer(), profile);
    const result = fbs.getWritten();

    const expected = "username=foo%26bar%3Dbaz&age=99&is_active=false&bio=A+bio+with+spaces+%26+symbols%21";
    try std.testing.expectEqualStrings(expected, result);
}

test "core/quote.zig: struct to form with null optional field" {
    // The `.bio` field is null by default and should be omitted from the output.
    const profile = UserProfile{
        .username = "Test",
        .age = 10,
        .is_active = true,
    };

    const UserProfileSerializer = Form(UserProfile);

    var buffer: [100]u8 = undefined;
    var fbs = std.io.fixedBufferStream(&buffer);

    try UserProfileSerializer.encode(fbs.writer(), profile);
    const result = fbs.getWritten();

    const expected = "username=Test&age=10&is_active=true";
    try std.testing.expectEqualStrings(expected, result);
}

test "core/quote.zig: quoteParams with realistic OAuth example" {
    var map = AnyCaseStringMap([]const u8).init(std.testing.allocator);
    defer map.deinit();

    try map.put("response_type", "code");
    try map.put("client_id", "my-client-id");
    try map.put("redirect_uri", "http://localhost:8001/callback");
    try map.put("scope", "openid profile email");
    try map.put("state", "a-unique-state-for-csrf-prevention");

    var buffer: [300]u8 = undefined;
    var fbs = std.io.fixedBufferStream(&buffer);
    const writer = fbs.writer();

    try quoteParamsMap(writer, map);
    const encoded = fbs.getWritten();

    const expected_parts = [_][]const u8{
        "response_type=code",
        "client_id=my-client-id",
        "redirect_uri=http%3A%2F%2Flocalhost%3A8001%2Fcallback",
        "scope=openid+profile+email",
        "state=a-unique-state-for-csrf-prevention",
    };

    for (expected_parts) |part| {
        try std.testing.expect(std.mem.indexOf(u8, encoded, part) != null);
    }
}

test "core/quote.zig: quoteParams with fixed buffer" {
    var map = AnyCaseStringMap([]const u8).init(std.testing.allocator);
    defer map.deinit();

    try map.put("query", "hello world");
    try map.put("filter", "foo & bar");
    try map.put("array[]", "value1");

    var buffer: [200]u8 = undefined;
    var fbs = std.io.fixedBufferStream(&buffer);
    const writer = fbs.writer();

    try quoteParamsMap(writer, map);
    const encoded = fbs.getWritten();

    const expected1 = "query=hello+world";
    const expected2 = "filter=foo+%26+bar";
    const expected3 = "array%5B%5D=value1";

    try std.testing.expect(std.mem.indexOf(u8, encoded, expected1) != null);
    try std.testing.expect(std.mem.indexOf(u8, encoded, expected2) != null);
    try std.testing.expect(std.mem.indexOf(u8, encoded, expected3) != null);
}

test "core/quote.zig: quote with fixed buffer" {
    const text = "/path/to/my/file.txt?query=test";
    const safe_chars = ":/%#?=@[]!$&'()*+,;";
    var buffer: [100]u8 = undefined;
    var fbs = std.io.fixedBufferStream(&buffer);
    const writer = fbs.writer();

    try quote(writer, text, safe_chars);
    const encoded = fbs.getWritten();

    const expected_encoded = "/path/to/my/file.txt?query=test";
    try std.testing.expect(std.mem.eql(u8, encoded, expected_encoded));

    const special_chars = "Hello, World! Here are some special chars: `~!@#$%^&*()_+-=[]\\{}|;':\"<>,.?/";
    const no_safe_chars = "";
    var special_buffer: [300]u8 = undefined;
    var special_fbs = std.io.fixedBufferStream(&special_buffer);
    const special_writer = special_fbs.writer();

    try quote(special_writer, special_chars, no_safe_chars);
    const encoded_special = special_fbs.getWritten();

    const expected_special = "Hello%2C+World%21+Here+are+some+special+chars%3A+%60~%21%40%23%24%25%5E%26%2A%28%29_%2B-%3D%5B%5D%5C%7B%7D%7C%3B%27%3A%22%3C%3E%2C.%3F%2F";
    try std.testing.expect(std.mem.eql(u8, encoded_special, expected_special));
}
