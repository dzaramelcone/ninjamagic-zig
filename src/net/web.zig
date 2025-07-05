const std = @import("std");
const zzz = @import("zzz");
const embed = @import("embed");
const cfg = @import("core").Config.Zzz;

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
                .headers = .{
                    .cache_control = "max-age=31536000, immutable",
                },
            });
        }
    }.handler;
}

fn layers() []const Layer {
    var out: [1 + embed.hosted_files.len]Layer = undefined;
    out[0] = Route.init("/").get({}, baseHandler).layer();
    for (embed.hosted_files, 0..) |page, i| {
        out[1 + i] = zzz.HTTP.Route
            .init(page.path)
            .get({}, serveStatic(page))
            .layer();
    }
    return out;
}

pub fn host(alloc: std.mem.Allocator) !void {
    var t = try Tardy.init(alloc, .{ .threading = .auto });
    defer t.deinit();
    var router = try Router.init(alloc, layers(), .{});
    defer router.deinit(alloc);

    var socket = try Socket.init(cfg.Zzz.addr);
    defer socket.close_blocking();
    try socket.bind();
    try socket.listen(cfg.Zzz.backlog);
    const EntryParams = struct {
        router: *const Router,
        socket: Socket,
    };

    try t.entry(
        EntryParams{ .router = &router, .socket = socket },
        struct {
            fn entry(rt: *Runtime, p: EntryParams) !void {
                var server = Server.init(cfg.Zzz.init);
                try server.serve(rt, p.router, .{ .normal = p.socket });
            }
        }.entry,
    );
}
