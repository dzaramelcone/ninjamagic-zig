const Mime = @import("zzz").HTTP.Mime;

pub const HostedFile = struct {
    path: []const u8,
    bytes: []const u8,
    mime: Mime,
};

pub const hosted_files = [_]HostedFile{ .{
    .path = "/xterm.js",
    .bytes = @embedFile("vendor/xterm.js"),
    .mime = .JS,
}, .{
    .path = "/xterm.css",
    .bytes = @embedFile("vendor/xterm.css"),
    .mime = .CSS,
}, .{
    .path = "/main.js",
    .bytes = @embedFile("view/main.js"),
    .mime = .JS,
}, .{
    .path = "/style.css",
    .bytes = @embedFile("view/style.css"),
    .mime = .CSS,
}, .{
    .path = "/",
    .bytes = @embedFile("view/main.html"),
    .mime = .HTML,
} };
