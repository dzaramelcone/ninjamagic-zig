const pg = @import("pg");
const websocket = @import("websocket");
const zzz = @import("zzz");

// This is what env vars look like:
// const log = std.io.getStdOut().writer();
// const env_map = try alloc.create(std.process.EnvMap);
// env_map.* = try std.process.getEnvMap(alloc);
// defer env_map.deinit();
// const name = env_map.get("HELLO") orelse "world";
// try log.print("Hello {s}\n", .{name});
pub const Config = struct {
    pub const Pg: pg.Pool.Opts = .{
        .size = 1,
        .connect = .{
            .port = 5432,
            .host = "db",
        },
        .auth = .{
            .username = "ziguser",
            .password = "zigpass",
            .database = "zigdb",
            .timeout = 10_000,
        },
    };

    pub const Ws: websocket.server.Config = .{
        .address = "0.0.0.0",
        .port = 9224,
        .handshake = .{
            .timeout = 3,
            .max_size = 1024,
            .max_headers = 0,
        },
    };

    pub const Zzz: struct {
        addr: zzz.tardy.Socket.InitKind = .{
            .tcp = .{
                .host = "0.0.0.0",
                .port = 9224,
            },
        },
        backlog: u16 = 4_096,
        init: zzz.HTTP.ServerConfig = .{},
    } = {};
};
