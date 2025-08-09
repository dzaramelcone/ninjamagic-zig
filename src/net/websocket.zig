const std = @import("std");
const zzz = @import("zzz");
// const core = @import("core");
const Tardy = zzz.tardy.Tardy(.auto);
const Runtime = zzz.tardy.Runtime;
const Socket = zzz.tardy.Socket;

var next_id: std.atomic.Value(usize) = .{ .raw = 1 };

// This is what env vars look like:
// const log = std.io.getStdOut().writer();
// const env_map = try alloc.create(std.process.EnvMap);
// env_map.* = try std.process.getEnvMap(alloc);
// defer env_map.deinit();
// const name = env_map.get("HELLO") orelse "world";
// try log.print("Hello {s}\n", .{name});

pub const Config = struct {
    pub const tps: f64 = 200;
    pub const Ws: struct {
        address: []const u8 = "0.0.0.0",
        port: u16 = 9862,
        max_message_size: usize = 1 << 20,
        handshake: struct {
            timeout: u32 = 3,
            max_size: usize = 1024,
            max_headers: u32 = 0,
        } = .{},
    } = .{};

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
const cfg = Config;
pub const WsHandler = struct {
    ctx: *anyopaque,
    onConnect: *const fn (ctx: *anyopaque, id: usize, conn: *Conn) anyerror!void,
    onDisconnect: *const fn (ctx: *anyopaque, id: usize) void,
    onMessage: *const fn (ctx: *anyopaque, id: usize, msg: []const u8) anyerror!void,
};

pub const Conn = struct {
    socket: Socket,
    rt: *Runtime,
    sent_close: bool = false,

    pub fn write(self: *Conn, data: []const u8) !void {
        try self.sendFrame(0x1, data);
    }

    fn sendFrame(self: *Conn, opcode: u8, payload: []const u8) !void {
        var header: [10]u8 = undefined;
        header[0] = 0x80 | opcode;
        var header_len: usize = 2;

        if (payload.len < 126) {
            header[1] = @intCast(payload.len);
        } else if (payload.len <= 0xFFFF) {
            header[1] = 126;
            std.mem.writeInt(u16, header[2..4], @intCast(payload.len), .big);
            header_len = 4;
        } else {
            header[1] = 127;
            std.mem.writeInt(u64, header[2..10], @intCast(payload.len), .big);
            header_len = 10;
        }

        _ = try self.socket.send_all(self.rt, header[0..header_len]);
        if (payload.len > 0) _ = try self.socket.send_all(self.rt, payload);
    }

    fn sendClose(self: *Conn, code: u16, reason: []const u8) !void {
        if (self.sent_close) return;
        self.sent_close = true;

        var buf: [125]u8 = undefined;
        std.mem.writeInt(u16, buf[0..2], code, .big);
        var len: usize = 2;

        if (reason.len > 0) {
            const copy_len = @min(reason.len, buf.len - 2);
            std.mem.copyForwards(u8, buf[2 .. 2 + copy_len], reason[0..copy_len]);
            len += copy_len;
        }

        try self.sendFrame(0x8, buf[0..len]);
    }

    pub fn close(self: *Conn) void {
        self.socket.close_blocking();
    }
};

pub const Handshake = struct {};

const Session = struct {
    handler: *const WsHandler,
    conn: *Conn,
    id: usize,

    fn init(h: *const Handshake, conn: *Conn, handler: *const WsHandler) !Session {
        _ = h;
        const id = next_id.fetchAdd(1, .monotonic);
        try handler.onConnect(handler.ctx, id, conn);
        return .{ .handler = handler, .conn = conn, .id = id };
    }

    fn deinit(self: *Session) void {
        self.handler.onDisconnect(self.handler.ctx, self.id);
    }

    fn clientMessage(self: *Session, raw: []const u8) !void {
        self.handler.onMessage(self.handler.ctx, self.id, raw) catch |err| try self.conn.write(@errorName(err));
    }

    fn close(self: *Session) void {
        self.deinit();
    }
};

fn readExact(rt: *Runtime, sock: *Socket, buf: []u8) !void {
    var off: usize = 0;
    while (off < buf.len) {
        const n = try sock.recv(rt, buf[off..]);
        if (n == 0) return error.ConnectionClosed;
        off += n;
    }
}

const Frame = struct {
    fin: bool,
    opcode: u8,
    payload: []u8,
};

fn readFrame(rt: *Runtime, alloc: std.mem.Allocator, conn: *Conn) !Frame {
    var header: [2]u8 = undefined;
    try readExact(rt, &conn.socket, header[0..2]);

    const fin = (header[0] & 0x80) != 0;
    const rsv = header[0] & 0x70;
    const opcode = header[0] & 0x0F;

    if (rsv != 0) return error.BadRsv;
    if (opcode > 0xA or (opcode >= 0x3 and opcode <= 0x7)) return error.InvalidOpcode;

    var len: usize = header[1] & 0x7F;
    const masked = (header[1] & 0x80) != 0;
    if (!masked) return error.UnmaskedFrame;

    if (len == 126) {
        var ext: [2]u8 = undefined;
        try readExact(rt, &conn.socket, ext[0..2]);
        len = @intCast(std.mem.readInt(u16, ext[0..2], .big));
    } else if (len == 127) {
        var ext8: [8]u8 = undefined;
        try readExact(rt, &conn.socket, ext8[0..8]);
        len = @intCast(std.mem.readInt(u64, ext8[0..8], .big));
    }

    if (len > cfg.Ws.max_message_size) return error.MessageTooBig;

    if ((opcode & 0x8) != 0) {
        if (!fin) return error.ControlFrameFragmented;
        if (len > 125) return error.ControlFrameTooBig;
    }

    var mask: [4]u8 = undefined;
    try readExact(rt, &conn.socket, mask[0..4]);

    var payload = try alloc.alloc(u8, len);
    errdefer alloc.free(payload);

    if (len > 0) {
        try readExact(rt, &conn.socket, payload);
        var i: usize = 0;
        while (i < payload.len) : (i += 1) {
            payload[i] ^= mask[i % 4];
        }
    }

    return Frame{ .fin = fin, .opcode = opcode, .payload = payload };
}

fn send400(rt2: *Runtime, c: *Conn) void {
    _ = c.socket.send_all(rt2, "HTTP/1.1 400 Bad Request\r\n\r\n") catch {};
}

fn hashLowerAscii(s: []const u8) u64 {
    var h: u64 = 1469598103934665603; // FNV-1a 64
    for (s) |c| {
        var b = c;
        if (b >= 'A' and b <= 'Z') b = b + 32;
        h ^= @as(u64, b);
        h *%= 1099511628211;
    }
    return h;
}

fn performHandshake(rt: *Runtime, conn: *Conn) !Handshake {
    // --- Read request up to CRLFCRLF with a hard cap ---
    var buf: [cfg.Ws.handshake.max_size]u8 = undefined;
    var len: usize = 0;
    while (true) {
        const n = try conn.socket.recv(rt, buf[len..]);
        if (n == 0) return error.ConnectionClosed;
        len += n;
        if (std.mem.indexOf(u8, buf[0..len], "\r\n\r\n")) |_| break;
        if (len >= buf.len) {
            send400(rt, conn);
            return error.HandshakeTooLarge;
        }
    }
    const request = buf[0..len];

    // --- Parse request line ---
    var it = std.mem.splitSequence(u8, request, "\r\n");
    const request_line = it.next() orelse {
        send400(rt, conn);
        return error.BadHandshake;
    };
    std.log.info("WS request line: {s}", .{request_line});
    if (!std.mem.startsWith(u8, request_line, "GET ")) {
        send400(rt, conn);
        return error.BadHandshake;
    }
    if (std.mem.indexOf(u8, request_line, " HTTP/1.1") == null) {
        send400(rt, conn);
        return error.BadHandshake;
    }

    // --- Collect required headers ---
    var key: ?[]const u8 = null;
    var upgrade: ?[]const u8 = null;
    var connection: ?[]const u8 = null;
    var version: ?[]const u8 = null;

    while (it.next()) |line| {
        if (line.len == 0) break; // end of headers
        const colon = std.mem.indexOfScalar(u8, line, ':') orelse continue;

        const name_raw = std.mem.trim(u8, line[0..colon], " \t");
        const value_raw = std.mem.trim(u8, line[colon + 1 ..], " \t");

        switch (hashLowerAscii(name_raw)) {
            hashLowerAscii("sec-websocket-key") => {
                if (std.ascii.eqlIgnoreCase(name_raw, "sec-websocket-key")) key = value_raw;
            },
            hashLowerAscii("upgrade") => {
                if (std.ascii.eqlIgnoreCase(name_raw, "upgrade")) upgrade = value_raw;
            },
            hashLowerAscii("connection") => {
                if (std.ascii.eqlIgnoreCase(name_raw, "connection")) connection = value_raw;
            },
            hashLowerAscii("sec-websocket-version") => {
                if (std.ascii.eqlIgnoreCase(name_raw, "sec-websocket-version")) version = value_raw;
            },
            else => {},
        }
    }

    // --- Validate presence ---
    if (key == null or upgrade == null or connection == null or version == null) {
        send400(rt, conn);
        return error.BadHandshake;
    }

    // Upgrade: websocket
    if (!std.ascii.eqlIgnoreCase(std.mem.trim(u8, upgrade.?, " \t"), "websocket")) {
        send400(rt, conn);
        return error.BadHandshake;
    }

    // Connection: ... upgrade ...  (tokens, case-insensitive)
    var has_upgrade = false;
    var conn_it = std.mem.splitScalar(u8, connection.?, ',');
    while (conn_it.next()) |tok| {
        if (std.ascii.eqlIgnoreCase(std.mem.trim(u8, tok, " \t"), "upgrade")) {
            has_upgrade = true;
            break;
        }
    }
    if (!has_upgrade) {
        send400(rt, conn);
        return error.BadHandshake;
    }

    // Sec-WebSocket-Version: 13
    if (!std.ascii.eqlIgnoreCase(std.mem.trim(u8, version.?, " \t"), "13")) {
        send400(rt, conn);
        return error.BadHandshake;
    }

    // Sec-WebSocket-Key must base64-decode to 16 bytes.
    // In practice that means a 24-char base64 string (including padding).
    if (std.mem.trim(u8, key.?, " \t").len != 24) {
        send400(rt, conn);
        return error.BadHandshake;
    }
    var key_decoded: [16]u8 = undefined;
    std.base64.standard.Decoder.decode(&key_decoded, key.?) catch {
        send400(rt, conn);
        return error.BadHandshake;
    };

    // --- Build Sec-WebSocket-Accept ---
    var sha1 = std.crypto.hash.Sha1.init(.{});
    sha1.update(key.?);
    sha1.update("258EAFA5-E914-47DA-95CA-C5AB0DC85B11");
    var digest: [20]u8 = undefined;
    sha1.final(&digest);

    var accept: [28]u8 = undefined;
    _ = std.base64.standard.Encoder.encode(&accept, &digest);

    // --- Send 101 Switching Protocols ---
    var resp_buf: [256]u8 = undefined;
    const response = try std.fmt.bufPrint(
        &resp_buf,
        "HTTP/1.1 101 Switching Protocols\r\n" ++
            "Upgrade: websocket\r\n" ++
            "Connection: Upgrade\r\n" ++
            "Sec-WebSocket-Accept: {s}\r\n\r\n",
        .{accept},
    );
    try conn.socket.writer(rt).writeAll(response);
    std.log.info("WS sent 101 Switching Protocols", .{});
    return Handshake{};
}

inline fn utf8Valid(s: []const u8) bool {
    if (std.unicode.Utf8View.init(s)) |_| {
        return true;
    } else |_| {
        return false;
    }
}

fn connectionFrame(rt: *Runtime, client: Socket, handler: *const WsHandler) !void {
    var conn_ptr = try rt.allocator.create(Conn);
    conn_ptr.* = .{ .socket = client, .rt = rt };
    defer {
        conn_ptr.close();
        rt.allocator.destroy(conn_ptr);
    }

    const hs = performHandshake(rt, conn_ptr) catch {
        conn_ptr.close();
        return;
    };

    var session = Session.init(&hs, conn_ptr, handler) catch {
        conn_ptr.close();
        return;
    };
    defer session.close();

    var msg_buf = std.ArrayList(u8).init(rt.allocator);
    defer msg_buf.deinit();
    var msg_opcode: u8 = 0;

    while (true) {
        var frame = readFrame(rt, rt.allocator, conn_ptr) catch |err| {
            const code: u16 = switch (err) {
                error.UnmaskedFrame,
                error.BadRsv,
                error.ControlFrameFragmented,
                error.ControlFrameTooBig,
                error.InvalidOpcode,
                => 1002,
                error.MessageTooBig => 1009,
                else => 1002,
            };
            conn_ptr.sendClose(code, "") catch {};
            break;
        };
        defer rt.allocator.free(frame.payload);

        switch (frame.opcode) {
            0x0 => { // continuation
                if (msg_opcode == 0) {
                    conn_ptr.sendClose(1002, "") catch {};
                    break;
                }
                if (msg_buf.items.len + frame.payload.len > cfg.Ws.max_message_size) {
                    conn_ptr.sendClose(1009, "") catch {};
                    break;
                }
                msg_buf.appendSlice(frame.payload) catch {
                    conn_ptr.sendClose(1009, "") catch {};
                    break;
                };
                if (frame.fin) {
                    if (msg_opcode == 0x1 and !utf8Valid(msg_buf.items)) {
                        conn_ptr.sendClose(1007, "") catch {};
                        break;
                    }
                    session.clientMessage(msg_buf.items) catch {};
                    msg_buf.clearRetainingCapacity();
                    msg_opcode = 0;
                }
            },
            0x1, 0x2 => {
                if (msg_opcode != 0) {
                    conn_ptr.sendClose(1002, "") catch {};
                    break;
                }
                msg_opcode = frame.opcode;
                if (frame.payload.len > cfg.Ws.max_message_size) {
                    conn_ptr.sendClose(1009, "") catch {};
                    break;
                }
                msg_buf.appendSlice(frame.payload) catch {
                    conn_ptr.sendClose(1009, "") catch {};
                    break;
                };
                if (frame.fin) {
                    if (msg_opcode == 0x1 and !utf8Valid(msg_buf.items)) {
                        conn_ptr.sendClose(1007, "") catch {};
                        break;
                    }
                    session.clientMessage(msg_buf.items) catch {};
                    msg_buf.clearRetainingCapacity();
                    msg_opcode = 0;
                }
            },
            0x8 => {
                var code: u16 = 1005;
                var reason: []const u8 = "";
                if (frame.payload.len == 1) {
                    conn_ptr.sendClose(1002, "") catch {};
                    break;
                }
                if (frame.payload.len >= 2) {
                    code = std.mem.readInt(u16, frame.payload[0..2], .big);
                    reason = frame.payload[2..];
                    if (reason.len > 0 and !utf8Valid(reason)) {
                        conn_ptr.sendClose(1007, "") catch {};
                        break;
                    }
                }
                conn_ptr.sendClose(code, reason) catch {};
                break;
            },
            0x9 => {
                // ping -> pong
                conn_ptr.sendFrame(0xA, frame.payload) catch {};
            },
            0xA => {}, // pong
            else => {
                conn_ptr.sendClose(1002, "") catch {};
                break;
            },
        }
    }
}
var accept_once: std.atomic.Value(u8) = .{ .raw = 0 };

fn acceptLoop(rt: *Runtime, server: *Socket, handler: *const WsHandler) !void { // pointer
    while (true) {
        const client = try server.accept(rt);
        std.log.info("WS accepted a client", .{});
        try rt.spawn(.{ rt, client, handler }, connectionFrame, 1024 * 1024);
    }
}

pub fn host_ws(allocator: std.mem.Allocator, handler: *const WsHandler) !void {
    var t = try Tardy.init(allocator, .{ .threading = .auto });
    defer t.deinit();

    var socket = try Socket.init(.{ .tcp = .{ .host = cfg.Ws.address, .port = cfg.Ws.port } });
    defer socket.close_blocking();
    try socket.bind();
    try socket.listen(1024);
    std.log.info("WS listening on {s}:{d}", .{ cfg.Ws.address, cfg.Ws.port });

    const EntryParams = struct {
        handler: *const WsHandler,
        socket: *Socket, // was: Socket
    };

    try t.entry(EntryParams{ .socket = &socket, .handler = handler }, struct {
        fn entry(rt: *Runtime, p: EntryParams) !void {
            if (accept_once.swap(1, .acq_rel) == 0) {
                try rt.spawn(.{ rt, p.socket, p.handler }, acceptLoop, 256 * 1024);
            }
            while (true) std.time.sleep(1_000_000_000);
        }
    }.entry);
}
const TestSock = struct {
    rx: []const u8, // bytes the "peer" will send us
    rx_i: usize = 0,
    tx: std.ArrayList(u8), // what we send to the peer
    chunk: usize, // max bytes per recv() to simulate fragmentation

    pub fn init(alloc: std.mem.Allocator, rx: []const u8, chunk: usize) TestSock {
        return .{ .rx = rx, .tx = std.ArrayList(u8).init(alloc), .chunk = chunk };
    }
    pub fn deinit(self: *TestSock) void {
        self.tx.deinit();
    }

    pub fn recv(self: *TestSock, _: anytype, buf: []u8) !usize {
        if (self.rx_i >= self.rx.len) return 0; // peer closed
        const n = @min(@min(self.chunk, buf.len), self.rx.len - self.rx_i);
        @memcpy(buf[0..n], self.rx[self.rx_i .. self.rx_i + n]);
        self.rx_i += n;
        return n;
    }
    pub fn send_all(self: *TestSock, _: anytype, buf: []const u8) !usize {
        try self.tx.appendSlice(buf);
        return buf.len;
    }
};

fn send400Generic(sock: *TestSock, rt: anytype) void {
    _ = sock.send_all(rt, "HTTP/1.1 400 Bad Request\r\n\r\n") catch {};
}

fn performHandshakeGeneric(alloc: std.mem.Allocator, sock: *TestSock) !void {
    // Read until CRLFCRLF with cap
    var buf: [cfg.Ws.handshake.max_size]u8 = undefined;
    var len: usize = 0;
    while (true) {
        const n = try sock.recv({}, buf[len..]);
        if (n == 0) return error.ConnectionClosed;
        len += n;
        if (std.mem.indexOf(u8, buf[0..len], "\r\n\r\n")) |_| break;
        if (len >= buf.len) {
            send400Generic(sock, {});
            return error.HandshakeTooLarge;
        }
    }
    const request = buf[0..len];

    var it = std.mem.splitSequence(u8, request, "\r\n");
    const request_line = it.next() orelse {
        send400Generic(sock, {});
        return error.BadHandshake;
    };
    if (!std.mem.startsWith(u8, request_line, "GET ")) {
        send400Generic(sock, {});
        return error.BadHandshake;
    }
    if (std.mem.indexOf(u8, request_line, " HTTP/1.1") == null) {
        send400Generic(sock, {});
        return error.BadHandshake;
    }

    var key: ?[]const u8 = null;
    var upgrade: ?[]const u8 = null;
    var connection: ?[]const u8 = null;
    var version: ?[]const u8 = null;

    while (it.next()) |line| {
        if (line.len == 0) break;
        const colon = std.mem.indexOfScalar(u8, line, ':') orelse continue;
        const name_raw = std.mem.trim(u8, line[0..colon], " \t");
        const value_raw = std.mem.trim(u8, line[colon + 1 ..], " \t");

        switch (hashLowerAscii(name_raw)) {
            hashLowerAscii("sec-websocket-key") => {
                if (std.ascii.eqlIgnoreCase(name_raw, "sec-websocket-key")) key = value_raw;
            },
            hashLowerAscii("upgrade") => {
                if (std.ascii.eqlIgnoreCase(name_raw, "upgrade")) upgrade = value_raw;
            },
            hashLowerAscii("connection") => {
                if (std.ascii.eqlIgnoreCase(name_raw, "connection")) connection = value_raw;
            },
            hashLowerAscii("sec-websocket-version") => {
                if (std.ascii.eqlIgnoreCase(name_raw, "sec-websocket-version")) version = value_raw;
            },
            else => {},
        }
    }

    if (key == null or upgrade == null or connection == null or version == null) {
        send400Generic(sock, {});
        return error.BadHandshake;
    }
    if (!std.ascii.eqlIgnoreCase(std.mem.trim(u8, upgrade.?, " \t"), "websocket")) {
        send400Generic(sock, {});
        return error.BadHandshake;
    }

    var has_upgrade = false;
    var conn_it = std.mem.splitScalar(u8, connection.?, ',');
    while (conn_it.next()) |tok| {
        if (std.ascii.eqlIgnoreCase(std.mem.trim(u8, tok, " \t"), "upgrade")) {
            has_upgrade = true;
            break;
        }
    }
    if (!has_upgrade) {
        send400Generic(sock, {});
        return error.BadHandshake;
    }

    if (!std.ascii.eqlIgnoreCase(std.mem.trim(u8, version.?, " \t"), "13")) {
        send400Generic(sock, {});
        return error.BadHandshake;
    }

    // Validate/Decode key
    if (std.mem.trim(u8, key.?, " \t").len != 24) {
        send400Generic(sock, {});
        return error.BadHandshake;
    }
    var key_decoded: [16]u8 = undefined;
    std.base64.standard.Decoder.decode(&key_decoded, key.?) catch {
        send400Generic(sock, {});
        return error.BadHandshake;
    };

    // Build accept
    var sha1 = std.crypto.hash.Sha1.init(.{});
    sha1.update(key.?);
    sha1.update("258EAFA5-E914-47DA-95CA-C5AB0DC85B11");
    var digest: [20]u8 = undefined;
    sha1.final(&digest);

    var accept: [28]u8 = undefined;
    _ = std.base64.standard.Encoder.encode(&accept, &digest);

    // Respond
    var resp_buf: [256]u8 = undefined;
    const response = try std.fmt.bufPrint(
        &resp_buf,
        "HTTP/1.1 101 Switching Protocols\r\n" ++
            "Upgrade: websocket\r\n" ++
            "Connection: Upgrade\r\n" ++
            "Sec-WebSocket-Accept: {s}\r\n\r\n",
        .{accept},
    );
    _ = try sock.send_all({}, response);
    _ = alloc; // silence if not used further
}

test "handshake success (fragmented input) produces 101 + correct Accept" {
    const req =
        "GET /chat HTTP/1.1\r\n" ++
        "Host: x\r\n" ++
        "Upgrade: websocket\r\n" ++
        "Connection: keep-alive, Upgrade\r\n" ++
        "Sec-WebSocket-Key: dGhlIHNhbXBsZSBub25jZQ==\r\n" ++
        "Sec-WebSocket-Version: 13\r\n" ++
        "\r\n";

    var sock = TestSock.init(std.testing.allocator, req, 5); // tiny chunks
    defer sock.deinit();

    try performHandshakeGeneric(std.testing.allocator, &sock);

    const out = sock.tx.items;
    try std.testing.expect(std.mem.startsWith(u8, out, "HTTP/1.1 101"));
    try std.testing.expect(std.mem.indexOf(u8, out, "Upgrade: websocket\r\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "Connection: Upgrade\r\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "Sec-WebSocket-Accept: s3pPLMBiTxaQ9kYGzzhZRbK+xOo=") != null);
}

test "sec-websocket-accept" {
    const accept = blk: {
        var sha1 = std.crypto.hash.Sha1.init(.{});
        sha1.update("dGhlIHNhbXBsZSBub25jZQ==");
        sha1.update("258EAFA5-E914-47DA-95CA-C5AB0DC85B11");
        var digest: [20]u8 = undefined;
        sha1.final(&digest);
        var accept_buf: [28]u8 = undefined;
        _ = std.base64.standard.Encoder.encode(&accept_buf, &digest);
        break :blk accept_buf;
    };
    try std.testing.expectEqualStrings(
        "s3pPLMBiTxaQ9kYGzzhZRbK+xOo=",
        accept[0..], // or: (&accept)[0..]
    );
}

test "handshake 400 when missing Upgrade header" {
    const req =
        "GET / HTTP/1.1\r\n" ++
        "Host: x\r\n" ++
        "Connection: Upgrade\r\n" ++
        "Sec-WebSocket-Key: dGhlIHNhbXBsZSBub25jZQ==\r\n" ++
        "Sec-WebSocket-Version: 13\r\n" ++
        "\r\n";

    var sock = TestSock.init(std.testing.allocator, req, 1024);
    defer sock.deinit();

    try std.testing.expectError(error.BadHandshake, performHandshakeGeneric(std.testing.allocator, &sock));
    try std.testing.expect(std.mem.startsWith(u8, sock.tx.items, "HTTP/1.1 400"));
}

test "handshake 400 when Connection header lacks token 'upgrade' (case-insensitive tokenization)" {
    const req =
        "GET / HTTP/1.1\r\n" ++
        "Host: x\r\n" ++
        "Upgrade: WebSocket\r\n" ++
        "Connection: keep-alive\r\n" ++
        "Sec-WebSocket-Key: dGhlIHNhbXBsZSBub25jZQ==\r\n" ++
        "Sec-WebSocket-Version: 13\r\n" ++
        "\r\n";

    var sock = TestSock.init(std.testing.allocator, req, 1024);
    defer sock.deinit();

    try std.testing.expectError(error.BadHandshake, performHandshakeGeneric(std.testing.allocator, &sock));
    try std.testing.expect(std.mem.startsWith(u8, sock.tx.items, "HTTP/1.1 400"));
}

test "handshake 400 on bad Sec-WebSocket-Key (wrong length/base64)" {
    const req =
        "GET / HTTP/1.1\r\n" ++
        "Host: x\r\n" ++
        "Upgrade: websocket\r\n" ++
        "Connection: Upgrade\r\n" ++
        "Sec-WebSocket-Key: not_base64_here\r\n" ++
        "Sec-WebSocket-Version: 13\r\n" ++
        "\r\n";

    var sock = TestSock.init(std.testing.allocator, req, 1024);
    defer sock.deinit();

    try std.testing.expectError(error.BadHandshake, performHandshakeGeneric(std.testing.allocator, &sock));
    try std.testing.expect(std.mem.startsWith(u8, sock.tx.items, "HTTP/1.1 400"));
}
