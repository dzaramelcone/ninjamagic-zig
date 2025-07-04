const std = @import("std");

pub const Entry = struct {
    path: []const u8,
    bytes: []const u8,
    mime: std.http.MimeType,
};

pub const files = [_]Entry{ .{
    .path = "/xterm.js",
    .bytes = @embedFile("view/vendor/xterm.js"),
    .mime = .JS,
}, .{
    .path = "/xterm.css",
    .bytes = @embedFile("view/vendor/xterm.css"),
    .mime = .CSS,
}, .{
    .path = "/main.js",
    .bytes = @embedFile("view/main.js"),
    .mime = .JS,
}, .{
    .path = "/style.css",
    .bytes = @embedFile("view/style.css"),
    .mime = .CSS,
} };
