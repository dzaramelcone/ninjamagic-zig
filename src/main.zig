const std = @import("std");

const pg = @import("pg");

const log = std.log.scoped(.@"examples/basic");
const ws = @import("websocket");

const zzz = @import("zzz");
const http = zzz.HTTP;

const tardy = zzz.tardy;
const Tardy = tardy.Tardy(.auto);
const Runtime = tardy.Runtime;
const Socket = tardy.Socket;

const Server = http.Server;
const Router = http.Router;
const Context = http.Context;
const Route = http.Route;
const Respond = http.Respond;

const host: []const u8 = "0.0.0.0";
const port: u16 = 9862;

const Users = @import("models/queries.sql.zig").PoolQuerier;

const html_content =
    \\ <!DOCTYPE html>
    \\ <html>
    \\ <head>
    \\   <meta charset="utf-8">
    \\   <title>MUD Terminal</title>
    \\   <link rel="stylesheet" href="https://unpkg.com/xterm/css/xterm.css">
    \\   <script src="https://unpkg.com/xterm/lib/xterm.js"></script>
    \\ </head>
    \\ <body style="margin:0; height:100vh;">
    \\   <div id="terminal" style="width:100%; height:100%;"></div>
    \\   <script>
    \\     const term = new Terminal();
    \\     term.open(document.getElementById('terminal'));
    \\     const ws = new WebSocket(`ws://${location.hostname}:9224/`);
    \\     ws.onmessage = e => term.write(e.data);
    \\     term.onData(data => ws.send(data));
    \\   </script>
    \\ </body>
    \\ </html>
;

fn base_handler(ctx: *const Context, _: void) !Respond {
    return ctx.response.apply(.{
        .status = .OK,
        .mime = http.Mime.HTML,
        .body = html_content,
    });
}

const App = struct {};
const WsHandler = struct {
    app: *App,
    conn: *ws.Conn,
    pub fn init(_: *const ws.Handshake, conn: *ws.Conn, app: *App) !WsHandler {
        return .{
            .app = app,
            .conn = conn,
        };
    }

    pub fn clientMessage(self: *WsHandler, data: []const u8) !void {
        try self.conn.write(data); // echo the message back
    }
};
fn runWsServer(alloc: std.mem.Allocator) !void {
    // start the ws_server. TODO: move this into tardy if possible
    var ws_server = try ws.Server(WsHandler).init(alloc, .{
        .port = 9224,
        .address = host,
        .handshake = .{
            .timeout = 3,
            .max_size = 1024,
            // since we aren't using handshake.headers
            // we can set this to 0 to save a few bytes.
            .max_headers = 0,
        },
    });
    var app = App{};
    try ws_server.listen(&app);
}

pub fn main() !void {
    var gpa = std.heap.DebugAllocator(.{ .thread_safe = true }){};
    const alloc = gpa.allocator();
    defer _ = gpa.deinit();

    try do_queries(alloc);

    var ws_thread = try std.Thread.spawn(.{}, runWsServer, .{alloc});
    defer ws_thread.join();

    // make Tardy for zzz
    var t = try Tardy.init(alloc, .{ .threading = .auto });
    defer t.deinit();
    var router = try Router.init(alloc, &.{
        Route.init("/").get({}, base_handler).layer(),
    }, .{});
    defer router.deinit(alloc);

    var socket = try Socket.init(.{ .tcp = .{ .host = host, .port = port } });
    defer socket.close_blocking();
    try socket.bind();
    try socket.listen(4096);
    const EntryParams = struct {
        router: *const Router,
        socket: Socket,
    };

    try t.entry(
        EntryParams{ .router = &router, .socket = socket },
        struct {
            fn entry(rt: *Runtime, p: EntryParams) !void {
                var server = Server.init(.{
                    .stack_size = 4 * 1024 * 1024,
                    .socket_buffer_bytes = 2 * 1024,
                    .keepalive_count_max = null,
                    .connection_count_max = 1024,
                });
                try server.serve(rt, p.router, .{ .normal = p.socket });
            }
        }.entry,
    );
}
fn dbCatch(err: anyerror, pool: *pg.Pool) !void {
    if (err == error.PG) {
        std.log.err("Postgres says: {s}", .{pool.err.?});
    }
    return err;
}
pub fn do_queries(alloc: std.mem.Allocator) !void {
    var pool = try pg.Pool.init(alloc, .{ .size = 1, .connect = .{
        .port = 5432,
        .host = "127.0.0.1",
    }, .auth = .{
        .username = "ziguser",
        .password = "zigpass",
        .database = "zigdb",
        .timeout = 10_000,
    } });
    defer pool.deinit();

    const querier = Users.init(alloc, pool);

    try querier.createUser(.{
        .name = "admin",
        .email = "admin@example.com",
        .password = "password",
        .role = .admin,
        .ip_address = "192.168.1.1",
        .salary = 1000.50,
    });

    try querier.createUser(.{
        .name = "user",
        .email = "user@example.com",
        .password = "password",
        .role = .user,
        .ip_address = "192.168.1.1",
        .salary = 1000.50,
    });

    const by_id = try querier.getUser(1);
    defer by_id.deinit();
    std.debug.print("{d}: {s}\n", .{ by_id.id, by_id.email });

    const by_email = try querier.getUserByEmail("admin@example.com");
    defer by_email.deinit();
    std.debug.print("{d}: {s}\n", .{ by_email.id, by_email.email });

    const by_role = try querier.getUsersByRole(.admin);
    defer {
        if (by_role.len > 0) {
            for (by_role) |user| {
                user.deinit();
            }
            alloc.free(by_role);
        }
    }
    for (by_role) |user| {
        std.debug.print("{d}: {s}\n", .{ user.id, user.email });
    }
}
