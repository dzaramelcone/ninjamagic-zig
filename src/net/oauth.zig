const std = @import("std");

pub const Provider = enum { google, github };

pub const Config = struct {
    client_id: []const u8,
    client_secret: []const u8,
    redirect_uri: []const u8,
    scope: ?[]const u8 = null,
};

pub const AuthParams = struct {
    state: []const u8,
    code_challenge: []const u8,
    nonce: ?[]const u8 = null,
};

pub fn randomString(alloc: std.mem.Allocator, len: usize) ![]u8 {
    var buf = try alloc.alloc(u8, len);
    defer alloc.free(buf);
    std.crypto.random.bytes(buf);
    return try std.base64.urlSafeNoPad.Encoder.encodeAlloc(alloc, buf);
}

pub fn pkceChallenge(alloc: std.mem.Allocator, verifier: []const u8) ![]u8 {
    var hash: [std.crypto.hash.sha2.Sha256.digest_length]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(verifier, &hash, .{});
    return try std.base64.urlSafeNoPad.Encoder.encodeAlloc(alloc, &hash);
}

pub const TokenResponse = union(enum) {
    google: struct {
        access_token: []u8,
        token_type: []u8,
        scope: []u8,
        id_token: ?[]u8,
    },
    github: struct {
        access_token: []u8,
        token_type: []u8,
        scope: []u8,
    },
};

pub fn authUrl(alloc: std.mem.Allocator, provider: Provider, cfg: Config, params: AuthParams) ![]u8 {
    var list = std.ArrayList(std.Uri.QueryParam).init(alloc);
    defer list.deinit();
    try list.append(.{ .name = "client_id", .value = cfg.client_id });
    try list.append(.{ .name = "redirect_uri", .value = cfg.redirect_uri });
    try list.append(.{ .name = "response_type", .value = "code" });
    const scope = cfg.scope orelse switch (provider) {
        .google => "openid email profile",
        .github => "user:email",
    };
    try list.append(.{ .name = "scope", .value = scope });
    try list.append(.{ .name = "state", .value = params.state });
    try list.append(.{ .name = "code_challenge", .value = params.code_challenge });
    try list.append(.{ .name = "code_challenge_method", .value = "S256" });
    if (provider == .google) {
        if (params.nonce) |n| try list.append(.{ .name = "nonce", .value = n });
    }

    const base_path = switch (provider) {
        .google => "/o/oauth2/v2/auth",
        .github => "/login/oauth/authorize",
    };
    const host = switch (provider) {
        .google => "accounts.google.com",
        .github => "github.com",
    };

    var uri = std.Uri{ .scheme = "https", .host = host, .path = base_path, .query_params = list.items, .fragment = null };
    return uri.renderAlloc(alloc);
}

pub const ExchangeError = error{BadRequest, Upstream};

pub fn exchangeCode(
    alloc: std.mem.Allocator,
    provider: Provider,
    cfg: Config,
    code: []const u8,
    code_verifier: []const u8,
) ExchangeError!TokenResponse {
    var client = std.http.Client{ .allocator = alloc, .max_response_body_size = 16 * 1024 };
    defer client.deinit();

    const token_uri = switch (provider) {
        .google => "https://oauth2.googleapis.com/token",
        .github => "https://github.com/login/oauth/access_token",
    };

    var headers = std.http.Headers.init(alloc);
    defer headers.deinit();
    try headers.append("content-type", "application/x-www-form-urlencoded");
    if (provider == .github) try headers.append("accept", "application/json");
    try headers.append("user-agent", "ninjamagic-zig");

    var body_writer = std.ArrayList(u8).init(alloc);
    defer body_writer.deinit();
    var q = std.Uri.QueryWriter.init(body_writer.writer());
    try q.append("code", code);
    try q.append("client_id", cfg.client_id);
    try q.append("client_secret", cfg.client_secret);
    try q.append("redirect_uri", cfg.redirect_uri);
    if (provider == .google) try q.append("grant_type", "authorization_code");
    try q.append("code_verifier", code_verifier);
    const body = body_writer.toOwnedSlice();

    var req = try client.request(.POST, try std.Uri.parse(token_uri), headers, body);
    defer req.deinit();
    try req.send();
    const res = try req.finish();
    if (res.status != .ok) {
        if (res.status == .bad_request or res.status == .unauthorized) return ExchangeError.BadRequest;
        return ExchangeError.Upstream;
    }
    const data = try res.reader().readAllAlloc(alloc, 16 * 1024);
    defer alloc.free(data);

    var parsed = try std.json.parseFromSlice(std.json.Value, alloc, data, .{});
    defer parsed.deinit();
    switch (provider) {
        .google => {
            const obj = parsed.value.object;
            return TokenResponse{ .google = .{
                .access_token = try alloc.dupe(u8, obj.get("access_token").?.string),
                .token_type = try alloc.dupe(u8, obj.get("token_type").?.string),
                .scope = try alloc.dupe(u8, obj.get("scope").?.string),
                .id_token = if (obj.get("id_token")) |id| try alloc.dupe(u8, id.string) else null,
            } };
        },
        .github => {
            const obj = parsed.value.object;
            return TokenResponse{ .github = .{
                .access_token = try alloc.dupe(u8, obj.get("access_token").?.string),
                .token_type = try alloc.dupe(u8, obj.get("token_type").?.string),
                .scope = try alloc.dupe(u8, obj.get("scope").?.string),
            } };
        },
    }
}

test "authUrl builds google URL" {
    var alloc = std.testing.allocator;
    const cfg = Config{
        .client_id = "id",
        .client_secret = "secret",
        .redirect_uri = "http://localhost",
    };
    const url = try authUrl(alloc, .google, cfg, .{
        .state = "s",
        .code_challenge = "c",
        .nonce = null,
    });
    defer alloc.free(url);
    try std.testing.expect(std.mem.startsWith(u8, url, "https://accounts.google.com"));
}

test "authUrl builds github URL" {
    var alloc = std.testing.allocator;
    const cfg = Config{
        .client_id = "id",
        .client_secret = "secret",
        .redirect_uri = "http://localhost",
    };
    const url = try authUrl(alloc, .github, cfg, .{
        .state = "s",
        .code_challenge = "c",
        .nonce = null,
    });
    defer alloc.free(url);
    try std.testing.expect(std.mem.startsWith(u8, url, "https://github.com"));
}
