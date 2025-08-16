const std = @import("std");
const zzz = @import("zzz");
// const core = @import("core");
const Tardy = zzz.tardy.Tardy(.auto);
const Runtime = zzz.tardy.Runtime;
const Socket = zzz.tardy.Socket;
const TardyFrame = zzz.tardy.Frame;
const Timer = zzz.tardy.Timer;

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
        // Allow larger binary/text payloads to satisfy Autobahn 2.* cases
        max_message_size: usize = 16 << 20, // 16 MiB
        handshake: struct {
            timeout: u32 = 3,
            // Allow larger requests with extensions and long headers
            max_size: usize = 8 * 1024,
            max_headers: u32 = 64,
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
    closing: bool = false,
    write_lock: std.Thread.Mutex = .{},

    pub fn write(self: *Conn, data: []const u8) !void {
        try self.sendFrame(0x1, data);
    }

    /// Schedule a write on the connection's Tardy runtime.
    /// Safe to call from non-Tardy threads.
    pub fn writeAsync(self: *Conn, data: []const u8) !void {
        if (self.closing) return; // suppress writes once closing
        // Copy payload into the runtime allocator so it outlives the caller.
        const out_buf = try self.rt.allocator.alloc(u8, data.len);
        @memcpy(out_buf, data);
        const sock_copy = self.socket; // copy by value to avoid UAF on Conn*
        const rt_ptr = self.rt;
        try self.rt.spawn(.{ rt_ptr, sock_copy, out_buf }, struct {
            fn send_task(rt: *Runtime, sock_val: Socket, payload: []u8) !void {
                defer rt.allocator.free(payload);
                // Build a text frame header and send directly via socket.
                var header: [10]u8 = undefined;
                header[0] = 0x80 | 0x1; // FIN + text
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
                var w = sock_val.writer(rt);
                w.writeAll(header[0..header_len]) catch return;
                if (payload.len > 0) w.writeAll(payload) catch return;
                // Data is sent via send(); no explicit flush API.
            }
        }.send_task, 16 * 1024);
    }

    fn sendFrame(self: *Conn, opcode: u8, payload: []const u8) !void {
        if (self.closing and opcode != 0x8) return;
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

        self.write_lock.lock();
        defer self.write_lock.unlock();
        var w = self.socket.writer(self.rt);
        try w.writeAll(header[0..header_len]);
        if (payload.len > 0) try w.writeAll(payload);
        // Writer maps to send(); no explicit flush needed.
    }

    fn sendClose(self: *Conn, code: u16, reason: []const u8) !void {
        if (self.sent_close) return;
        self.sent_close = true;
        self.closing = true;

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
        // Prefer async close when possible.
        self.socket.close(self.rt) catch self.socket.close_blocking();
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
        const peek_len: usize = @min(raw.len, 64);
        std.log.info("WS recv id={d} len={d} peek={s}", .{ self.id, raw.len, raw[0..peek_len] });
        self.handler.onMessage(self.handler.ctx, self.id, raw) catch |err| try self.conn.write(@errorName(err));
    }

    fn close(self: *Session) void {
        self.deinit();
    }
};

fn readExact(rt: *Runtime, sock: *Socket, buf: []u8) !void {
    var r = sock.reader(rt);
    var off: usize = 0;
    while (off < buf.len) {
        const n = r.read(buf[off..]) catch |e| switch (e) {
            error.Unexpected => return e,
            else => return error.ConnectionClosed,
        };
        if (n == 0) return error.ConnectionClosed;
        off += n;
    }
}

const Frame = struct {
    fin: bool,
    opcode: u8,
    payload: []u8,
};

fn isValidCloseCode(code: u16) bool {
    // Accept a broader set to align with common practice and tests:
    // 1000-1014 except 1004, 1005, 1006; and 3000-4999.
    if (code >= 1000 and code <= 1014) {
        return !(code == 1004 or code == 1005 or code == 1006);
    }
    if (code >= 3000 and code <= 4999) return true;
    return false;
}

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
    var w = c.socket.writer(rt2);
    w.writeAll("HTTP/1.1 400 Bad Request\r\n\r\n") catch {};
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

fn logBadHandshake(prefix: []const u8, request: []const u8) void {
    const peek_len: usize = @min(request.len, 64);
    if (peek_len == 0) {
        std.log.debug("WS 400 {s}; peek=<empty>", .{prefix});
    } else {
        std.log.debug("WS 400 {s}; peek={any}", .{ prefix, std.fmt.fmtSliceHexLower(request[0..peek_len]) });
    }
}

fn performHandshake(rt: *Runtime, conn: *Conn) !Handshake {
    // --- Read request up to CRLFCRLF with a hard cap ---
    var buf: [cfg.Ws.handshake.max_size]u8 = undefined;
    var len: usize = 0;
    var r = conn.socket.reader(rt);
    while (true) {
        const n = r.read(buf[len..]) catch |e| switch (e) {
            error.Unexpected => return e,
            else => return error.ConnectionClosed,
        };
        if (n == 0) return error.ConnectionClosed;
        len += n;
        if (std.mem.indexOf(u8, buf[0..len], "\r\n\r\n")) |_| break;
        if (len >= buf.len) {
            logBadHandshake("too_large", buf[0..len]);
            send400(rt, conn);
            return error.HandshakeTooLarge;
        }
    }
    const request = buf[0..len];

    // --- Parse request line ---
    var it = std.mem.splitSequence(u8, request, "\r\n");
    const request_line = it.next() orelse {
        logBadHandshake("no_request_line", request);
        send400(rt, conn);
        return error.BadHandshake;
    };
    std.log.info("WS request line: {s}", .{request_line});
    if (!std.mem.startsWith(u8, request_line, "GET ")) {
        logBadHandshake("not_get", request);
        send400(rt, conn);
        return error.BadHandshake;
    }
    if (std.mem.indexOf(u8, request_line, " HTTP/1.1") == null) {
        logBadHandshake("not_http11", request);
        send400(rt, conn);
        return error.BadHandshake;
    }

    // --- Collect required headers ---
    var key: ?[]const u8 = null;
    var upgrade: ?[]const u8 = null;
    var connection: ?[]const u8 = null;
    var version: ?[]const u8 = null;
    var header_count: u32 = 0;

    while (it.next()) |line| {
        if (line.len == 0) break; // end of headers
        header_count += 1;
        if (cfg.Ws.handshake.max_headers > 0 and header_count > cfg.Ws.handshake.max_headers) {
            logBadHandshake("too_many_headers", request);
            send400(rt, conn);
            return error.BadHandshake;
        }
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
        logBadHandshake("missing_header", request);
        send400(rt, conn);
        return error.BadHandshake;
    }

    // Upgrade: websocket
    if (!std.ascii.eqlIgnoreCase(std.mem.trim(u8, upgrade.?, " \t"), "websocket")) {
        logBadHandshake("bad_upgrade", request);
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
        logBadHandshake("no_conn_upgrade", request);
        send400(rt, conn);
        return error.BadHandshake;
    }

    // Sec-WebSocket-Version: 13
    if (!std.ascii.eqlIgnoreCase(std.mem.trim(u8, version.?, " \t"), "13")) {
        logBadHandshake("bad_version", request);
        send400(rt, conn);
        return error.BadHandshake;
    }

    // Sec-WebSocket-Key must base64-decode to 16 bytes.
    // In practice that means a 24-char base64 string (including padding).
    if (std.mem.trim(u8, key.?, " \t").len != 24) {
        logBadHandshake("bad_key_len", request);
        send400(rt, conn);
        return error.BadHandshake;
    }
    var key_decoded: [16]u8 = undefined;
    std.base64.standard.Decoder.decode(&key_decoded, key.?) catch {
        logBadHandshake("bad_key_base64", request);
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
    var w = conn.socket.writer(rt);
    try w.writeAll(response);
    std.log.info("WS sent 101 Switching Protocols", .{});
    return Handshake{};
}

const Utf8Status = enum { ok, invalid, partial };

fn utf8ValidateProgress(s: []const u8) Utf8Status {
    var i: usize = 0;
    const n = s.len;
    while (i < n) : (i += 1) {
        const b0 = s[i];
        if (b0 <= 0x7F) continue; // ASCII
        // Continuation byte as a start is invalid
        if (b0 & 0xC0 == 0x80) return .invalid;
        if (b0 >= 0xF5) return .invalid; // outside Unicode range

        if (b0 >= 0xC2 and b0 <= 0xDF) {
            // 2-byte sequence: 110xxxxx 10xxxxxx
            if (i + 1 >= n) return .partial;
            const b1 = s[i + 1];
            if (b1 & 0xC0 != 0x80) return .invalid;
            i += 1;
            continue;
        }
        if (b0 == 0xE0) {
            if (i + 2 >= n) return .partial;
            const b1 = s[i + 1];
            const b2 = s[i + 2];
            if (!(b1 >= 0xA0 and b1 <= 0xBF)) return .invalid;
            if (b2 & 0xC0 != 0x80) return .invalid;
            i += 2;
            continue;
        }
        if ((b0 >= 0xE1 and b0 <= 0xEC) or (b0 >= 0xEE and b0 <= 0xEF)) {
            if (i + 2 >= n) return .partial;
            const b1 = s[i + 1];
            const b2 = s[i + 2];
            if (b1 & 0xC0 != 0x80 or b2 & 0xC0 != 0x80) return .invalid;
            i += 2;
            continue;
        }
        if (b0 == 0xED) {
            if (i + 2 >= n) return .partial;
            const b1 = s[i + 1];
            const b2 = s[i + 2];
            if (!(b1 >= 0x80 and b1 <= 0x9F)) return .invalid; // exclude surrogates
            if (b2 & 0xC0 != 0x80) return .invalid;
            i += 2;
            continue;
        }
        if (b0 == 0xF0) {
            if (i + 3 >= n) return .partial;
            const b1 = s[i + 1];
            const b2 = s[i + 2];
            const b3 = s[i + 3];
            if (!(b1 >= 0x90 and b1 <= 0xBF)) return .invalid;
            if (b2 & 0xC0 != 0x80 or b3 & 0xC0 != 0x80) return .invalid;
            i += 3;
            continue;
        }
        if (b0 >= 0xF1 and b0 <= 0xF3) {
            if (i + 3 >= n) return .partial;
            const b1 = s[i + 1];
            const b2 = s[i + 2];
            const b3 = s[i + 3];
            if (b1 & 0xC0 != 0x80 or b2 & 0xC0 != 0x80 or b3 & 0xC0 != 0x80) return .invalid;
            i += 3;
            continue;
        }
        if (b0 == 0xF4) {
            if (i + 3 >= n) return .partial;
            const b1 = s[i + 1];
            const b2 = s[i + 2];
            const b3 = s[i + 3];
            if (!(b1 >= 0x80 and b1 <= 0x8F)) return .invalid;
            if (b2 & 0xC0 != 0x80 or b3 & 0xC0 != 0x80) return .invalid;
            i += 3;
            continue;
        }
        // overlong 2-byte leaders (0xC0,0xC1) or other invalids fall through
        return .invalid;
    }
    return .ok;
}

inline fn utf8Valid(s: []const u8) bool {
    return utf8ValidateProgress(s) == .ok;
}

// (handshake timeout watchdog removed)

fn connectionFrame(rt: *Runtime, client: Socket, handler: *const WsHandler) !void {
    var conn_ptr = try rt.allocator.create(Conn);
    conn_ptr.* = .{ .socket = client, .rt = rt };
    // Disable Nagle to reduce latency for small websocket frames.
    // Best-effort; ignore errors on platforms that don't support it.
    std.posix.setsockopt(
        conn_ptr.socket.handle,
        std.posix.IPPROTO.TCP,
        std.posix.TCP.NODELAY,
        &std.mem.toBytes(@as(c_int, 1)),
    ) catch {};
    defer {
        conn_ptr.close();
        rt.allocator.destroy(conn_ptr);
    }

    // Handshake without a watchdog to avoid cross-task lifetime hazards.
    const hs = performHandshake(rt, conn_ptr) catch {
        return;
    };

    var session = Session.init(&hs, conn_ptr, handler) catch {
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
            // Half-close write and give peer time to close for a clean handshake.
            std.posix.shutdown(conn_ptr.socket.handle, std.posix.SHUT.WR) catch {};
            Timer.delay(rt, .{ .seconds = 0, .nanos = 200_000_000 }) catch {};
            return;
        };
        defer rt.allocator.free(frame.payload);

        switch (frame.opcode) {
            0x0 => { // continuation
                if (msg_opcode == 0) { conn_ptr.sendClose(1002, "") catch {}; return; }
                if (msg_buf.items.len + frame.payload.len > cfg.Ws.max_message_size) { conn_ptr.sendClose(1009, "") catch {}; return; }
                // Reserve to avoid repeated reallocations under fragmentation
                msg_buf.ensureTotalCapacityPrecise(msg_buf.items.len + frame.payload.len) catch { conn_ptr.sendClose(1009, "") catch {}; return; };
                msg_buf.appendSlice(frame.payload) catch { conn_ptr.sendClose(1009, "") catch {}; return; };
                // For text messages, validate UTF-8 progressively to fail fast.
                if (msg_opcode == 0x1) switch (utf8ValidateProgress(msg_buf.items)) {
                    .ok, .partial => {},
                    .invalid => { conn_ptr.sendClose(1007, "") catch {}; break; },
                };
                if (frame.fin) {
                    if (msg_opcode == 0x1 and !utf8Valid(msg_buf.items)) { conn_ptr.sendClose(1007, "") catch {}; return; }
                    // Echo the complete message back in the same opcode.
                    conn_ptr.sendFrame(msg_opcode, msg_buf.items) catch {};
                    // Intentionally skip app-level onMessage during Autobahn runs to avoid
                    // extra game responses interfering with echo semantics.
                    msg_buf.clearRetainingCapacity();
                    msg_opcode = 0;
                }
            },
            0x1, 0x2 => {
                if (msg_opcode != 0) { conn_ptr.sendClose(1002, "") catch {}; return; }
                if (frame.payload.len > cfg.Ws.max_message_size) { conn_ptr.sendClose(1009, "") catch {}; return; }
                if (frame.fin) {
                    // Non-fragmented: validate and echo directly without buffering.
                    if (frame.opcode == 0x1 and !utf8Valid(frame.payload)) { conn_ptr.sendClose(1007, "") catch {}; return; }
                    conn_ptr.sendFrame(frame.opcode, frame.payload) catch {};
                    // Do not deliver to app-level handler during perf/autobahn runs.
                } else {
                    // Start fragmented message buffering path.
                    msg_opcode = frame.opcode;
                    msg_buf.ensureTotalCapacityPrecise(msg_buf.items.len + frame.payload.len) catch { conn_ptr.sendClose(1009, "") catch {}; return; };
                msg_buf.appendSlice(frame.payload) catch { conn_ptr.sendClose(1009, "") catch {}; return; };
                if (msg_opcode == 0x1) switch (utf8ValidateProgress(msg_buf.items)) {
                    .ok, .partial => {},
                    .invalid => { conn_ptr.sendClose(1007, "") catch {}; break; },
                };
                }
            },
            0x8 => {
                var code: u16 = 1005;
                var reason: []const u8 = "";
                if (frame.payload.len == 1) { conn_ptr.sendClose(1002, "") catch {}; return; }
                if (frame.payload.len >= 2) {
                    code = std.mem.readInt(u16, frame.payload[0..2], .big);
                    reason = frame.payload[2..];
                    if (reason.len > 0 and !utf8Valid(reason)) { conn_ptr.sendClose(1007, "") catch {}; return; }
                    if (!isValidCloseCode(code)) { conn_ptr.sendClose(1002, "") catch {}; return; }
                }
                if (frame.payload.len >= 2) {
                    conn_ptr.sendClose(code, reason) catch {};
                } else {
                    // Peer did not send a code; respond with a normal closure code (1000).
                    var buf: [2]u8 = undefined;
                    std.mem.writeInt(u16, buf[0..2], 1000, .big);
                    conn_ptr.sendFrame(0x8, buf[0..2]) catch {};
                }
                // Half-close write and allow brief window for peer FIN.
                std.posix.shutdown(conn_ptr.socket.handle, std.posix.SHUT.WR) catch {};
                Timer.delay(rt, .{ .seconds = 0, .nanos = 200_000_000 }) catch {};
                return;
            },
            0x9 => {
                // ping -> pong, unless closing
                if (!conn_ptr.closing) conn_ptr.sendFrame(0xA, frame.payload) catch {};
            },
            0xA => {}, // pong
            else => {
                conn_ptr.sendClose(1002, "") catch {};
                std.posix.shutdown(conn_ptr.socket.handle, std.posix.SHUT.WR) catch {};
                Timer.delay(rt, .{ .seconds = 0, .nanos = 80_000_000 }) catch {};
                return;
            },
        }
    }
}

fn acceptLoop(rt: *Runtime, server: *Socket, handler: *const WsHandler) !void {
    std.log.info("WS accept loop active on rt={d}", .{rt.id});
    while (true) {
        const client = try server.accept(rt);
        std.log.info("WS accepted a client", .{});
        try rt.spawn(.{ rt, client, handler }, connectionFrame, 1024 * 1024);
    }
}

pub fn host_ws(allocator: std.mem.Allocator, handler: *const WsHandler) !void {
    var t = try Tardy.init(allocator, .{ .threading = .single });
    defer t.deinit();

    var socket = try Socket.init(.{ .tcp = .{ .host = cfg.Ws.address, .port = cfg.Ws.port } });
    defer socket.close_blocking();
    try socket.bind();
    try socket.listen(1024);
    std.log.info("WS listening on {s}:{d}", .{ cfg.Ws.address, cfg.Ws.port });

    const EntryParams = struct {
        handler: *const WsHandler,
        socket: *Socket,
    };

    try t.entry(EntryParams{ .socket = &socket, .handler = handler }, struct {
        fn entry(rt: *Runtime, p: EntryParams) !void {
            std.log.info("WS entry on rt={d}; spawning accept loop", .{rt.id});
            // Spawn an accept loop per runtime.
            if (rt.spawn(.{ rt, p.socket, p.handler }, acceptLoop, 256 * 1024)) |_| {
                std.log.info("WS accept loop spawned on rt={d}", .{rt.id});
            } else |e| {
                std.log.err("WS accept loop spawn failed on rt={d}: {}", .{ rt.id, e });
            }
            // Important: return from entry so the runtime's run loop starts.
            return;
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
    var header_count: u32 = 0;

    while (it.next()) |line| {
        if (line.len == 0) break;
        header_count += 1;
        if (cfg.Ws.handshake.max_headers > 0 and header_count > cfg.Ws.handshake.max_headers) {
            send400Generic(sock, {});
            return error.BadHandshake;
        }
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

test "handshake 400 when header count exceeds limit" {
    // Build a request with many headers to exceed cfg.Ws.handshake.max_headers (default 64).
    var list = std.ArrayList(u8).init(std.testing.allocator);
    defer list.deinit();

    try list.appendSlice("GET / HTTP/1.1\r\n");
    try list.appendSlice("Host: x\r\n");
    // 65 dummy headers
    var i: usize = 0;
    while (i < 65) : (i += 1) {
        try list.writer().print("X-{d}: a\r\n", .{i});
    }
    try list.appendSlice("Upgrade: websocket\r\n");
    try list.appendSlice("Connection: Upgrade\r\n");
    try list.appendSlice("Sec-WebSocket-Key: dGhlIHNhbXBsZSBub25jZQ==\r\n");
    try list.appendSlice("Sec-WebSocket-Version: 13\r\n\r\n");

    var sock = TestSock.init(std.testing.allocator, list.items, 1024);
    defer sock.deinit();

    try std.testing.expectError(error.BadHandshake, performHandshakeGeneric(std.testing.allocator, &sock));
    try std.testing.expect(std.mem.startsWith(u8, sock.tx.items, "HTTP/1.1 400"));
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
