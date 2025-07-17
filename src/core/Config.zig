const websocket = @import("websocket");
const pg = @import("pg");
const zzz = @import("zzz");

// This is what env vars look like:
// const log = std.io.getStdOut().writer();
// const env_map = try alloc.create(std.process.EnvMap);
// env_map.* = try std.process.getEnvMap(alloc);
// defer env_map.deinit();
// const name = env_map.get("HELLO") orelse "world";
// try log.print("Hello {s}\n", .{name});

pub const Config = struct {
    pub const tps: f64 = 200;
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
        .port = 9862,
        .handshake = .{
            .timeout = 3,
            .max_size = 1024,
            .max_headers = 0,
        },
    };

    pub const Zzz: struct {
        host: []const u8 = "0.0.0.0",
        port: u16 = 9224,
        backlog: u16 = 4_096,
    } = .{};

    pub const Combat: struct {
        pub const fight_timer: f64 = 120.0;
        pub const attack_duration: f64 = 2.0;
        pub const block_duration: f64 = 2.0;
        pub const block_active_after: f64 = 1.2;
        pub const block_lag: f64 = 3.5;
        pub const stun_duration: f64 = 3.0;
        pub const stun_odds: f64 = 0.1;
    } = .{};
};
