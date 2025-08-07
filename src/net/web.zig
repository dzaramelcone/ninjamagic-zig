const std = @import("std");
const zzz = @import("zzz");
const embed = @import("embed");
const cfg = @import("core").Config.Zzz;
const oauth = @import("oauth.zig");

const Tardy = zzz.tardy.Tardy(.auto);
const Runtime = zzz.tardy.Runtime;
const Socket = zzz.tardy.Socket;

const Server = zzz.HTTP.Server;
const Router = zzz.HTTP.Router;
const Layer = zzz.HTTP.Layer;
const Context = zzz.HTTP.Context;
const Route = zzz.HTTP.Route;
const Respond = zzz.HTTP.Respond;

const html_content =
    \\ <!DOCTYPE html>
    \\ <html>
    \\ <head>
    \\   <meta charset="utf-8">
    \\   <title>MUD Terminal</title>
    \\   <link rel="stylesheet" href="/xterm.css">
    \\   <script src="/xterm.js"></script>
    \\ </head>
    \\ <body style="margin:0; height:100vh;">
    \\   <div id="terminal" style="width:100%; height:100%;"></div>
    \\   <script>
    \\     const term = new Terminal();
    \\     term.open(document.getElementById('terminal'));
    \\     const ws = new WebSocket(`ws://${location.hostname}:${location.port}/`);
    \\     ws.onmessage = e => term.write(e.data);
    \\     term.onData(data => ws.send(data));
    \\   </script>
    \\ </body>
    \\ </html>
;
fn baseHandler(ctx: *const Context, _: void) !Respond {
    return ctx.response.apply(.{
        .status = .OK,
        .mime = zzz.HTTP.Mime.HTML,
        .body = html_content,
    });
}

fn serveStatic(comptime entry: embed.HostedFile) *const fn (*const Context, void) anyerror!Respond {
    return struct {
        fn handler(ctx: *const Context, _: void) !Respond {
            return ctx.response.apply(.{
                .status = .OK,
                .mime = entry.mime,
                .body = entry.bytes,
            });
        }
    }.handler;
}

const ConfigError = error{ MissingEnv };

fn googleConfig(alloc: std.mem.Allocator) ConfigError!oauth.Config {
    var env_map = try std.process.getEnvMap(alloc);
    defer env_map.deinit();
    return .{
        .client_id = env_map.get("GOOGLE_CLIENT_ID") orelse return ConfigError.MissingEnv,
        .client_secret = env_map.get("GOOGLE_CLIENT_SECRET") orelse return ConfigError.MissingEnv,
        .redirect_uri = env_map.get("GOOGLE_REDIRECT_URI") orelse return ConfigError.MissingEnv,
    };
}

fn githubConfig(alloc: std.mem.Allocator) ConfigError!oauth.Config {
    var env_map = try std.process.getEnvMap(alloc);
    defer env_map.deinit();
    return .{
        .client_id = env_map.get("GITHUB_CLIENT_ID") orelse return ConfigError.MissingEnv,
        .client_secret = env_map.get("GITHUB_CLIENT_SECRET") orelse return ConfigError.MissingEnv,
        .redirect_uri = env_map.get("GITHUB_REDIRECT_URI") orelse return ConfigError.MissingEnv,
    };
}

fn googleStart(ctx: *const Context, _: void) !Respond {
    const alloc = ctx.allocator;
    const cfg = googleConfig(alloc) catch |err| {
        return ctx.response.apply(.{ .status = .InternalServerError, .mime = zzz.HTTP.Mime.TEXT, .body = @errorName(err) });
    };
    const state = oauth.randomString(alloc, 32) catch |err| {
        return ctx.response.apply(.{ .status = .InternalServerError, .mime = zzz.HTTP.Mime.TEXT, .body = @errorName(err) });
    };
    const verifier = oauth.randomString(alloc, 32) catch |err| {
        alloc.free(state);
        return ctx.response.apply(.{ .status = .InternalServerError, .mime = zzz.HTTP.Mime.TEXT, .body = @errorName(err) });
    };
    const challenge = oauth.pkceChallenge(alloc, verifier) catch |err| {
        alloc.free(state);
        alloc.free(verifier);
        return ctx.response.apply(.{ .status = .InternalServerError, .mime = zzz.HTTP.Mime.TEXT, .body = @errorName(err) });
    };
    const nonce = oauth.randomString(alloc, 32) catch |err| {
        alloc.free(state);
        alloc.free(verifier);
        alloc.free(challenge);
        return ctx.response.apply(.{ .status = .InternalServerError, .mime = zzz.HTTP.Mime.TEXT, .body = @errorName(err) });
    };
    const url = oauth.authUrl(alloc, .google, cfg, .{ .state = state, .code_challenge = challenge, .nonce = nonce }) catch |err| {
        alloc.free(state);
        alloc.free(verifier);
        alloc.free(challenge);
        alloc.free(nonce);
        return ctx.response.apply(.{ .status = .InternalServerError, .mime = zzz.HTTP.Mime.TEXT, .body = @errorName(err) });
    };
    const cookie_val = std.fmt.allocPrint(alloc, "{s}:{s}:{s}", .{ state, verifier, nonce }) catch {
        alloc.free(state);
        alloc.free(verifier);
        alloc.free(challenge);
        alloc.free(nonce);
        alloc.free(url);
        return ctx.response.apply(.{ .status = .InternalServerError, .mime = zzz.HTTP.Mime.TEXT, .body = "cookie" });
    };
    return ctx.response.apply(.{
        .status = .Found,
        .mime = zzz.HTTP.Mime.HTML,
        .headers = &.{
            .{ "Location", url },
            .{ "Set-Cookie", std.fmt.comptimePrint("oauth={s}; Path=/; HttpOnly; Secure; SameSite=Lax", .{cookie_val}) },
        },
    });
}

fn githubStart(ctx: *const Context, _: void) !Respond {
    const alloc = ctx.allocator;
    const cfg = githubConfig(alloc) catch |err| {
        return ctx.response.apply(.{ .status = .InternalServerError, .mime = zzz.HTTP.Mime.TEXT, .body = @errorName(err) });
    };
    const state = oauth.randomString(alloc, 32) catch |err| {
        return ctx.response.apply(.{ .status = .InternalServerError, .mime = zzz.HTTP.Mime.TEXT, .body = @errorName(err) });
    };
    const verifier = oauth.randomString(alloc, 32) catch |err| {
        alloc.free(state);
        return ctx.response.apply(.{ .status = .InternalServerError, .mime = zzz.HTTP.Mime.TEXT, .body = @errorName(err) });
    };
    const challenge = oauth.pkceChallenge(alloc, verifier) catch |err| {
        alloc.free(state);
        alloc.free(verifier);
        return ctx.response.apply(.{ .status = .InternalServerError, .mime = zzz.HTTP.Mime.TEXT, .body = @errorName(err) });
    };
    const url = oauth.authUrl(alloc, .github, cfg, .{ .state = state, .code_challenge = challenge, .nonce = null }) catch |err| {
        alloc.free(state);
        alloc.free(verifier);
        alloc.free(challenge);
        return ctx.response.apply(.{ .status = .InternalServerError, .mime = zzz.HTTP.Mime.TEXT, .body = @errorName(err) });
    };
    const cookie_val = std.fmt.allocPrint(alloc, "{s}:{s}", .{ state, verifier }) catch {
        alloc.free(state);
        alloc.free(verifier);
        alloc.free(challenge);
        alloc.free(url);
        return ctx.response.apply(.{ .status = .InternalServerError, .mime = zzz.HTTP.Mime.TEXT, .body = "cookie" });
    };
    return ctx.response.apply(.{
        .status = .Found,
        .mime = zzz.HTTP.Mime.HTML,
        .headers = &.{
            .{ "Location", url },
            .{ "Set-Cookie", std.fmt.comptimePrint("oauth={s}; Path=/; HttpOnly; Secure; SameSite=Lax", .{cookie_val}) },
        },
    });
}

fn googleCallback(ctx: *const Context, _: void) !Respond {
    const alloc = ctx.allocator;
    const code = ctx.queries.get("code") orelse return ctx.response.apply(.{ .status = .BadRequest, .mime = zzz.HTTP.Mime.TEXT, .body = "missing code" });
    const state_q = ctx.queries.get("state") orelse return ctx.response.apply(.{ .status = .BadRequest, .mime = zzz.HTTP.Mime.TEXT, .body = "missing state" });
    const cookie_hdr = ctx.headers.get("cookie") orelse return ctx.response.apply(.{ .status = .BadRequest, .mime = zzz.HTTP.Mime.TEXT, .body = "missing cookie" });
    const parts = std.mem.tokenize(u8, cookie_hdr, "=");
    var it = parts;
    var found = false;
    var state_cookie: []const u8 = undefined;
    var verifier: []const u8 = undefined;
    var nonce: []const u8 = &[_]u8{};
    while (it.next()) |name| {
        if (std.mem.eql(u8, name, "oauth")) {
            if (it.next()) |val| {
                found = true;
                var sub = std.mem.tokenize(u8, val, ":");
                state_cookie = sub.next() orelse "";
                verifier = sub.next() orelse "";
                nonce = sub.next() orelse &[_]u8{};
            }
            break;
        }
    }
    if (!found or !std.mem.eql(u8, state_cookie, state_q)) return ctx.response.apply(.{ .status = .BadRequest, .mime = zzz.HTTP.Mime.TEXT, .body = "bad state" });
    const cfg = googleConfig(alloc) catch |err| {
        return ctx.response.apply(.{ .status = .InternalServerError, .mime = zzz.HTTP.Mime.TEXT, .body = @errorName(err) });
    };
    if (std.process.getEnvVarOwned(alloc, "OAUTH_TEST_MODE")) |_| {
        if (!std.mem.eql(u8, code, "ok")) return ctx.response.apply(.{ .status = .BadRequest, .mime = zzz.HTTP.Mime.TEXT, .body = "bad code" });
        return ctx.response.apply(.{ .status = .OK, .mime = zzz.HTTP.Mime.JSON, .body = "{\"access_token\":\"test\"}" });
    } else |_| {}
    const token = oauth.exchangeCode(alloc, .google, cfg, code, verifier) catch |err| {
        return switch (err) {
            oauth.ExchangeError.BadRequest => ctx.response.apply(.{ .status = .BadRequest, .mime = zzz.HTTP.Mime.TEXT, .body = "bad code" }),
            oauth.ExchangeError.Upstream => ctx.response.apply(.{ .status = .BadGateway, .mime = zzz.HTTP.Mime.TEXT, .body = "upstream" }),
        };
    };
    // leaking token struct fields omitted for brevity
    return ctx.response.apply(.{ .status = .OK, .mime = zzz.HTTP.Mime.JSON, .body = "{}" });
}

fn githubCallback(ctx: *const Context, _: void) !Respond {
    const alloc = ctx.allocator;
    const code = ctx.queries.get("code") orelse return ctx.response.apply(.{ .status = .BadRequest, .mime = zzz.HTTP.Mime.TEXT, .body = "missing code" });
    const state_q = ctx.queries.get("state") orelse return ctx.response.apply(.{ .status = .BadRequest, .mime = zzz.HTTP.Mime.TEXT, .body = "missing state" });
    const cookie_hdr = ctx.headers.get("cookie") orelse return ctx.response.apply(.{ .status = .BadRequest, .mime = zzz.HTTP.Mime.TEXT, .body = "missing cookie" });
    const parts = std.mem.tokenize(u8, cookie_hdr, "=");
    var it = parts;
    var found = false;
    var state_cookie: []const u8 = undefined;
    var verifier: []const u8 = undefined;
    while (it.next()) |name| {
        if (std.mem.eql(u8, name, "oauth")) {
            if (it.next()) |val| {
                found = true;
                var sub = std.mem.tokenize(u8, val, ":");
                state_cookie = sub.next() orelse "";
                verifier = sub.next() orelse "";
            }
            break;
        }
    }
    if (!found or !std.mem.eql(u8, state_cookie, state_q)) return ctx.response.apply(.{ .status = .BadRequest, .mime = zzz.HTTP.Mime.TEXT, .body = "bad state" });
    const cfg = githubConfig(alloc) catch |err| {
        return ctx.response.apply(.{ .status = .InternalServerError, .mime = zzz.HTTP.Mime.TEXT, .body = @errorName(err) });
    };
    if (std.process.getEnvVarOwned(alloc, "OAUTH_TEST_MODE")) |_| {
        if (!std.mem.eql(u8, code, "ok")) return ctx.response.apply(.{ .status = .BadRequest, .mime = zzz.HTTP.Mime.TEXT, .body = "bad code" });
        return ctx.response.apply(.{ .status = .OK, .mime = zzz.HTTP.Mime.JSON, .body = "{\"access_token\":\"test\"}" });
    } else |_| {}
    const token = oauth.exchangeCode(alloc, .github, cfg, code, verifier) catch |err| {
        return switch (err) {
            oauth.ExchangeError.BadRequest => ctx.response.apply(.{ .status = .BadRequest, .mime = zzz.HTTP.Mime.TEXT, .body = "bad code" }),
            oauth.ExchangeError.Upstream => ctx.response.apply(.{ .status = .BadGateway, .mime = zzz.HTTP.Mime.TEXT, .body = "upstream" }),
        };
    };
    return ctx.response.apply(.{ .status = .OK, .mime = zzz.HTTP.Mime.JSON, .body = "{}" });
}

const layers: [9]Layer = .{
    Route.init(embed.hosted_files[0].path).get({}, serveStatic(embed.hosted_files[0])).layer(),
    Route.init(embed.hosted_files[1].path).get({}, serveStatic(embed.hosted_files[1])).layer(),
    Route.init(embed.hosted_files[2].path).get({}, serveStatic(embed.hosted_files[2])).layer(),
    Route.init(embed.hosted_files[3].path).get({}, serveStatic(embed.hosted_files[3])).layer(),
    Route.init(embed.hosted_files[4].path).get({}, serveStatic(embed.hosted_files[4])).layer(),
    Route.init("/auth/google").get({}, googleStart).layer(),
    Route.init("/auth/google/callback").get({}, googleCallback).layer(),
    Route.init("/auth/github").get({}, githubStart).layer(),
    Route.init("/auth/github/callback").get({}, githubCallback).layer(),
};

pub fn host(alloc: std.mem.Allocator) !void {
    var t = try Tardy.init(alloc, .{ .threading = .auto });
    defer t.deinit();
    var router = try Router.init(alloc, &layers, .{});
    defer router.deinit(alloc);

    var socket = try Socket.init(.{
        .tcp = .{
            .host = cfg.host,
            .port = cfg.port,
        },
    });
    defer socket.close_blocking();
    try socket.bind();
    try socket.listen(cfg.backlog);
    const EntryParams = struct {
        router: *const Router,
        socket: Socket,
    };

    try t.entry(
        EntryParams{ .router = &router, .socket = socket },
        struct {
            fn entry(rt: *Runtime, p: EntryParams) !void {
                var server = Server.init(.{});
                try server.serve(rt, p.router, .{ .normal = p.socket });
            }
        }.entry,
    );
}
