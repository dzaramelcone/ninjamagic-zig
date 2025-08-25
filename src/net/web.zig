const std = @import("std");
const zzz = @import("zzz");
const embed = @import("embed");

const core = @import("../core/module.zig");
const cfg = core.Config.Zzz;

const Tardy = zzz.tardy.Tardy(.auto);
const Runtime = zzz.tardy.Runtime;
const Socket = zzz.tardy.Socket;

const Server = zzz.HTTP.Server;
const Router = zzz.HTTP.Router;
const Layer = zzz.HTTP.Layer;
const Context = zzz.HTTP.Context;
const Route = zzz.HTTP.Route;
const Request = zzz.HTTP.Request;
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

fn login(ctx: *const Context, _: void) anyerror!Respond {
    // const auth_params = &[_][2][]const u8 {
    //     .{ "response_type", "code" },
    //     .{ "redirect_uri", "http://localhost:8001/callback" },
    //     .{ "scope", "openid profile email" },
    //     .{ "state", "a-unique-state-for-csrf-prevention" }
    // };
    // var query_buffer: [256]u8 = undefined;
    // var fbs = std.io.fixedBufferStream(&query_buffer);
    // try quote.quoteParams(fbs.writer(), auth_params);
    // const query_string = fbs.getWritten();

    const redirect_url = "http://localhost:8000/authorize/?response_type=code&client_id=my-client-id&redirect_uri=http://localhost:9224/callback&scope=openid+profile+email&state=a-unique-state-for-csrf-prevention";
    return ctx.response.apply(
        .{
            .status = .@"Temporary Redirect",
            .mime = zzz.HTTP.Mime.TEXT,
            .headers = &.{
                [2][]const u8{ "location", redirect_url },
            },
        },
    );
}
const CallbackQuery = struct {
    code: []const u8,
    state: []const u8,
};

const TokenRequest = struct {
    grant_type: []const u8,
    code: ?[]const u8 = null,
    redirect_uri: ?[]const u8 = null,
    client_id: ?[]const u8 = null,
    client_secret: ?[]const u8 = null,
    refresh_token: ?[]const u8 = null,
    state: ?[]const u8 = null,
};

const TokenRequestForm = core.Form(TokenRequest);

fn callback(ctx: *const Context, _: void) anyerror!Respond {
    const code = ctx.queries.get("code") orelse return error.MissingAuthCode;
    const state = ctx.queries.get("state") orelse return error.MissingState;

    // TODO: validate the 'state' parameter here?
    const token_request = TokenRequest{
        .grant_type = "authorization_code",
        .code = code,
        .state = state,
        .client_id = "my-client-id",
        .client_secret = "my-client-secret",
        .redirect_uri = "http://localhost:9224/callback",
    };

    var body_buffer: [512]u8 = undefined;
    var fbs = std.io.fixedBufferStream(&body_buffer);
    try TokenRequestForm.encode(fbs.writer(), token_request);
    var client = std.http.Client{ .allocator = ctx.allocator };
    const response = try client.fetch(.{
        .method = .POST,
        .location = .{ .url = "http://localhost:8000/token" },
        .headers = .{
            .content_type = .{ .override = "application/x-www-form-urlencoded" },
        },
        .payload = fbs.getWritten(),
    });
    // Send request to oauth /token endpoint with body:
    // form encoded,  grant_type=authorization_code&code=SplxlOBeZQQYbYS6WxSbIA
    // /callback?code=6288a09c46f940d68b40b3acd3c77276&state=a-unique-state-for-csrf-prevention
    return ctx.response.apply(.{
        .status = @enumFromInt(@intFromEnum(response.status)),
        .mime = zzz.HTTP.Mime.TEXT, // The token response is typically JSON
    });
}

const layers = [_]Layer{
    // Route.init("/login").get({}, login).layer(),
    // Route.init("/callback").get({}, callback).layer(),
    Route.init(embed.hosted_files[0].path).get({}, serveStatic(embed.hosted_files[0])).layer(),
    Route.init(embed.hosted_files[1].path).get({}, serveStatic(embed.hosted_files[1])).layer(),
    Route.init(embed.hosted_files[2].path).get({}, serveStatic(embed.hosted_files[2])).layer(),
    Route.init(embed.hosted_files[3].path).get({}, serveStatic(embed.hosted_files[3])).layer(),
    Route.init(embed.hosted_files[4].path).get({}, serveStatic(embed.hosted_files[4])).layer(),
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
