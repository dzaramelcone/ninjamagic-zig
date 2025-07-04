const std = @import("std");
const zzz = @import("zzz");
const cfg = @import("config.zig").Config;
const assets = @import("assets.zig");

const Tardy = zzz.tardy.Tardy(.auto);
const Runtime = zzz.tardy.Runtime;
const Socket = zzz.tardy.Socket;

const Server = zzz.HTTP.Server;
const Router = zzz.HTTP.Router;
const Layer = zzz.HTTP.Layer;
const Context = zzz.HTTP.Context;
const Route = zzz.HTTP.Route;
const Respond = zzz.HTTP.Respond;

fn baseHandler(ctx: *const Context, _: void) !Respond {
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
    return ctx.response.apply(.{
        .status = .OK,
        .mime = zzz.HTTP.Mime.HTML,
        .body = html_content,
    });
}
fn serveStatic(comptime entry: assets.Entry) *const fn (*const Context, void) anyerror!Respond {
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
    const out: [1 + assets.files.len]Layer = undefined;
    out[0] = Route.init("/").get({}, baseHandler).layer();
    inline for (assets.files, 0..) |file, i| {
        out[i + 1] = zzz.HTTP.Route
            .init(file.path)
            .get({}, serveStatic(file))
            .layer();
    }
    return out;
}
const layers_list = layers();

pub fn host(alloc: std.mem.Allocator) !void {

    // make Tardy for zzz
    var t = try Tardy.init(alloc, .{ .threading = .auto });
    defer t.deinit();
    var router = try Router.init(alloc, &layers_list, .{});
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
