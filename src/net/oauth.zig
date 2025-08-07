const std = @import("std");

pub const Provider = enum { google, github };

pub const Config = struct {
    client_id: []const u8,
    client_secret: []const u8,
    redirect_uri: []const u8,
};

pub fn authUrl(alloc: std.mem.Allocator, provider: Provider, cfg: Config) ![]u8 {
    return switch (provider) {
        .google => try std.fmt.allocPrint(alloc,
            "https://accounts.google.com/o/oauth2/v2/auth?client_id={s}&redirect_uri={s}&response_type=code&scope=openid%20email",
            .{ cfg.client_id, cfg.redirect_uri }),
        .github => try std.fmt.allocPrint(alloc,
            "https://github.com/login/oauth/authorize?client_id={s}&redirect_uri={s}&scope=user:email",
            .{ cfg.client_id, cfg.redirect_uri }),
    };
}

pub fn exchangeCode(alloc: std.mem.Allocator, provider: Provider, cfg: Config, code: []const u8) ![]u8 {
    var client = std.http.Client{ .allocator = alloc };
    defer client.deinit();

    const token_uri = switch (provider) {
        .google => "https://oauth2.googleapis.com/token",
        .github => "https://github.com/login/oauth/access_token",
    };

    var uri = try std.Uri.parse(token_uri);
    var headers = std.http.Headers.init(alloc);
    defer headers.deinit();
    try headers.append("content-type", "application/x-www-form-urlencoded");

    var body = switch (provider) {
        .google => try std.fmt.allocPrint(alloc,
            "code={s}&client_id={s}&client_secret={s}&redirect_uri={s}&grant_type=authorization_code",
            .{ code, cfg.client_id, cfg.client_secret, cfg.redirect_uri }),
        .github => try std.fmt.allocPrint(alloc,
            "code={s}&client_id={s}&client_secret={s}&redirect_uri={s}",
            .{ code, cfg.client_id, cfg.client_secret, cfg.redirect_uri }),
    };
    defer alloc.free(body);

    var req = try client.request(.POST, uri, headers, body);
    defer req.deinit();
    try req.send();
    const res = try req.finish();
    const data = try res.reader().readAllAlloc(alloc, 16 * 1024);
    return data;
}

test "authUrl builds google URL" {
    var alloc = std.testing.allocator;
    const cfg = Config{
        .client_id = "id",
        .client_secret = "secret",
        .redirect_uri = "http://localhost",
    };
    const url = try authUrl(alloc, .google, cfg);
    defer alloc.free(url);
    try std.testing.expectEqualStrings(
        "https://accounts.google.com/o/oauth2/v2/auth?client_id=id&redirect_uri=http://localhost&response_type=code&scope=openid%20email",
        url,
    );
}

test "authUrl builds github URL" {
    var alloc = std.testing.allocator;
    const cfg = Config{
        .client_id = "id",
        .client_secret = "secret",
        .redirect_uri = "http://localhost",
    };
    const url = try authUrl(alloc, .github, cfg);
    defer alloc.free(url);
    try std.testing.expectEqualStrings(
        "https://github.com/login/oauth/authorize?client_id=id&redirect_uri=http://localhost&scope=user:email",
        url,
    );
}
