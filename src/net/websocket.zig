const std = @import("std");
const zzz = @import("zzz");
// const core = @import("core");
const Tardy = zzz.tardy.Tardy(.auto);
const Runtime = zzz.tardy.Runtime;
const Socket = zzz.tardy.Socket;
const TardyFrame = zzz.tardy.Frame;
const Timer = zzz.tardy.Timer;

var next_id: std.atomic.Value(usize) = .{ .raw = 1 };

pub const Config = struct {
    pub const Ws: struct {
        address: []const u8 = "0.0.0.0",
        port: u16 = 9862,
        max_message_size: usize = 16 << 20, // 16 MiB
        handshake: struct {
            timeout: u32 = 3,
            max_size: usize = 8 * 1024,
            max_headers: u32 = 64,
        } = .{},
    } = .{};
};

const Opcode = enum(u8) {
    Continuation = 0b0000_0000,
    Text = 0b0000_0001,
    Binary = 0b0000_0010,
    Close = 0b0000_1000,
    Ping = 0b0000_1001,
    Pong = 0b0000_1010,

    pub fn isControl(self: Opcode) bool {
        return @intFromEnum(self) & 0b0000_1000 != 0;
    }

    pub fn from_u8(val: u8) !Opcode {
        return std.meta.intToEnum(@This(), val) catch return error.InvalidOpCode;
    }
};

const CloseCode = enum(u16) {
    Fulfilled = 1000,
    ServerGoingAway = 1001,
    ProtocolError = 1002,
    UnacceptedDataType = 1003,
    NoStatusPresent = 1005,
    ClosedAbnormally = 1006,
    DataInconsistentWithMessage = 1007,
    PolicyViolation = 1008,
    MessageTooBigToProcess = 1009,
    UnsupportedExtensionClientTerminated = 1010,
    InternalError = 1011,
    TLSHandshakeFailed = 1015,
    Undefined,

    pub fn from_u16(val: u16) !CloseCode {
        return switch (val) {
            1000, 1002, 1003, 1005, 1007, 1009, 1010, 1011 => @enumFromInt(val),
            3000...4999 => .Undefined,
            else => error.InvalidCloseCode,
        };
    }

    pub fn from_error(err: WsError) CloseCode {
        return switch (err) {
            WsError.InvalidOpcode,
            WsError.UnexpectedContinuation,
            WsError.FragmentInProgress,
            WsError.ControlFrameFragmented,
            WsError.ControlFrameTooBig,
            WsError.BadReservedBits,
            WsError.UnmaskedFrame,
            WsError.CloseLenOne,
            WsError.CloseCodeInvalid,
            => CloseCode.ProtocolError,

            WsError.MessageTooBig => CloseCode.MessageTooBigToProcess,

            WsError.InvalidUtf8Partial,
            WsError.InvalidUtf8Final,
            WsError.CloseReasonInvalidUtf8,
            => CloseCode.DataInconsistentWithMessage,

            else => CloseCode.ProtocolError,
        };
    }
};

const HandshakeError = error{
    NotHttp11,
    NotGet,
    NoRequestLine,
    TooLarge,
    TooManyHeaders,
    MissingHeaders,
    BadUpgrade,
    NoConnectionUpgrade,
    BadVersion,
    BadKeyLength,
    BadKeyBase64,
};

const WsError = HandshakeError || error{
    ConnectionClosed,
    HandshakeTooLarge,
    BadHandshake,

    // framing / protocol
    InvalidOpcode,
    UnexpectedContinuation,
    FragmentInProgress,
    ControlFrameFragmented,
    ControlFrameTooBig,
    BadReservedBits,
    UnmaskedFrame,
    MessageTooBig,

    // text validity
    InvalidUtf8Partial,
    InvalidUtf8Final,

    // close validation
    CloseLenOne,
    CloseCodeInvalid,
    CloseReasonInvalidUtf8,

    // io / generic
    IoFailure,
};

pub const Handshake = struct {};

const SessionState = enum {
    Handshake,
    ReadingFrame,
    ReadingFragmentedPayload,
    Closing,
};

pub const Session = struct {
    socket: Socket,
    rt: *Runtime,
    id: usize,
    state: SessionState = .Handshake,

    // Fields for fragmented messages
    fragmented_opcode: ?Opcode = null,
    msg_buf: std.ArrayList(u8),
    alloc: std.mem.Allocator,

    pub fn init(alloc: std.mem.Allocator, socket: Socket, rt: *Runtime) !Session {
        const id = next_id.fetchAdd(1, .monotonic);
        return .{
            .socket = socket,
            .rt = rt,
            .id = id,
            .alloc = alloc,
            .msg_buf = std.ArrayList(u8).init(alloc),
        };
    }

    fn deinit(self: *Session) void {
        _ = self;
        // TODO add disconnect event to event loop queue
        // self.handler.onDisconnect(self.handler.ctx, self.id);
    }

    fn clientMessage(self: *Session, raw: []const u8) !void {
        const peek_len: usize = @min(raw.len, 64);
        std.log.info("WS recv id={d} len={d} peek={s}", .{ self.id, raw.len, raw[0..peek_len] });
        // self.handler.onMessage(self.handler.ctx, self.id, raw) catch |err| try self.conn.write(@errorName(err));
    }

    fn close(self: *Session, close_code: CloseCode) void {
        // TODO
        _ = close_code;
        self.deinit();
    }

    pub fn send400(self: *Session) void {
        var w = self.socket.writer(self.rt);
        w.writeAll("HTTP/1.1 400 Bad Request\r\n\r\n") catch {};
    }

    pub fn closeWithError(self: *Session, err: WsError) void {
        if (self.state != .Closing) {
            self.state = .Closing;
            self.close(CloseCode.from_error(err));
        }
    }

    pub fn performHandshake(self: *Session) WsError!Handshake {
        // read request up to min of buf len or CRLFCRLF
        var buf: [Config.Ws.handshake.max_size]u8 = undefined;
        var len: usize = 0;
        var r = self.socket.reader(self.rt);
        while (true) {
            const n = r.read(buf[len..]) catch return WsError.IoFailure;
            if (n == 0) return WsError.ConnectionClosed;
            len += n;
            if (std.mem.indexOf(u8, buf[0..len], "\r\n\r\n")) |_| break;
            if (len >= buf.len) {
                return WsError.HandshakeTooLarge;
            }
        }
        const request = buf[0..len];

        var it = std.mem.splitSequence(u8, request, "\r\n");
        const request_line = it.next() orelse return HandshakeError.NoRequestLine;
        if (!std.mem.startsWith(u8, request_line, "GET ")) return HandshakeError.NotGet;
        if (std.mem.indexOf(u8, request_line, " HTTP/1.1") == null) return HandshakeError.NotHttp11;

        const max_headers = Config.Ws.handshake.max_headers;
        var header_count: u32 = 0;
        // get required headers
        var key: ?[]const u8 = null;
        var upgrade: ?[]const u8 = null;
        var connection: ?[]const u8 = null;
        var version: ?[]const u8 = null;

        while (it.next()) |line| {
            if (line.len == 0) break;
            header_count += 1;
            if (max_headers > 0 and header_count > max_headers) return HandshakeError.TooManyHeaders;

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

        if (key == null or upgrade == null or connection == null or version == null) return HandshakeError.MissingHeaders;
        if (!std.ascii.eqlIgnoreCase(std.mem.trim(u8, upgrade.?, " \t"), "websocket")) return HandshakeError.BadUpgrade;
        var has_upgrade = false;
        var conn_it = std.mem.splitScalar(u8, connection.?, ',');
        while (conn_it.next()) |tok| {
            if (std.ascii.eqlIgnoreCase(std.mem.trim(u8, tok, " \t"), "upgrade")) {
                has_upgrade = true;
                break;
            }
        }
        if (!has_upgrade) return HandshakeError.NoConnectionUpgrade;
        // Sec-WebSocket-Version: 13
        if (!std.ascii.eqlIgnoreCase(std.mem.trim(u8, version.?, " \t"), "13")) return HandshakeError.BadVersion;
        // Sec-WebSocket-Key must base64-decode to 16 bytes. becomes a 24-char base64 string (including padding).
        if (std.mem.trim(u8, key.?, " \t").len != 24) return HandshakeError.BadKeyLength;
        var key_decoded: [16]u8 = undefined;
        std.base64.standard.Decoder.decode(&key_decoded, key.?) catch return HandshakeError.BadKeyBase64;

        // build Sec-WebSocket-Accept
        var sha1 = std.crypto.hash.Sha1.init(.{});
        sha1.update(key.?);
        sha1.update("258EAFA5-E914-47DA-95CA-C5AB0DC85B11");
        var digest: [20]u8 = undefined;
        sha1.final(&digest);

        var accept: [28]u8 = undefined;
        _ = std.base64.standard.Encoder.encode(&accept, &digest);

        var resp_buf: [256]u8 = undefined;
        const response = std.fmt.bufPrint(
            &resp_buf,
            "HTTP/1.1 101 Switching Protocols\r\n" ++
                "Upgrade: websocket\r\n" ++
                "Connection: Upgrade\r\n" ++
                "Sec-WebSocket-Accept: {s}\r\n\r\n",
            .{accept},
        ) catch unreachable; // TODO fix
        var w = self.socket.writer(self.rt);
        w.writeAll(response) catch return WsError.IoFailure;
        std.log.info("WS sent 101 Switching Protocols", .{});
        return Handshake{};
    }

    pub fn handleFrame(self: *Session, frame: WsFrame) !void {
        const is_control = frame.opcode.isControl();

        // Check for fragmented control frames, which are a protocol violation
        if (is_control and !frame.fin) {
            return self.closeWithError(WsError.ControlFrameFragmented);
        }

        // Handle control frames immediately
        if (is_control) {
            switch (frame.opcode) {
                .Close => {
                    self.handleCloseFrame(frame.payload);
                    self.state = .Closing;
                    return;
                },
                .Ping => {
                    if (self.state != .Closing) {
                        // try self.sendFrame(.Pong, frame.payload);
                    }
                },
                .Pong => {
                    // acknowledge receipt of a Pong, no action needed
                },
                .Text, .Binary, .Continuation => {
                    // should not happen, but handle defensively
                    return self.closeWithError(WsError.InvalidOpcode);
                },
            }
        } else {
            if (frame.opcode == .Continuation) {
                if (self.fragmented_opcode == null) return self.closeWithError(WsError.UnexpectedContinuation);
            } else { // New message
                if (self.fragmented_opcode) |_| return self.closeWithError(WsError.FragmentInProgress);
                self.fragmented_opcode = frame.opcode;
            }

            try self.msg_buf.appendSlice(frame.payload);

            if (frame.fin) {
                try self.handleCompleteMessage(self.msg_buf.items, self.fragmented_opcode.?);
                self.msg_buf.clearAndFree();
                self.fragmented_opcode = null;
            } else {
                self.state = .ReadingFragmentedPayload;
            }
        }
    }

    fn handleCloseFrame(self: *Session, payload: []const u8) void {
        if (payload.len == 1) return self.closeWithError(WsError.CloseLenOne);

        var close_code = CloseCode.NoStatusPresent;
        if (payload.len >= 2) {
            const code_val = std.mem.readInt(u16, payload[0..2], .big);
            close_code = CloseCode.from_u16(code_val) catch |e| switch (e) {
                error.InvalidCloseCode => CloseCode.Undefined,
            };
        }

        const reason = if (payload.len > 2) payload[2..] else &[_]u8{};
        if (!std.unicode.utf8ValidateSlice(reason)) return self.closeWithError(WsError.CloseReasonInvalidUtf8);

        std.log.info("WS received close frame. Code={d}, reason={s}", .{ @intFromEnum(close_code), reason });
        self.close(CloseCode.Fulfilled);
    }

    fn handleCompleteMessage(self: *Session, payload: []const u8, opcode: Opcode) !void {
        if (opcode == .Text and !std.unicode.utf8ValidateSlice(payload)) return self.closeWithError(WsError.InvalidUtf8Final);
        try self.clientMessage(payload);
    }
};

fn readExact(rt: *Runtime, socket: *Socket, buffer: []u8) WsError!void {
    var total_read: usize = 0;
    while (total_read < buffer.len) {
        const n = socket.reader(rt).read(buffer[total_read..]) catch |e| switch (e) {
            error.EndOfStream => return WsError.ConnectionClosed,
            else => return WsError.IoFailure,
        };
        if (n == 0) return WsError.ConnectionClosed;
        total_read += n;
    }
}

const WsFrame = struct {
    fin: bool,
    opcode: Opcode,
    payload: []u8,
};

fn readFrame(rt: *Runtime, alloc: std.mem.Allocator, session: *Session) WsError!WsFrame {
    var header: [2]u8 = undefined;
    try readExact(rt, &session.socket, header[0..2]);

    const fin = (header[0] & 0x80) != 0;
    const rsv = header[0] & 0x70;
    const op_byte = header[0] & 0x0F;

    if (rsv != 0) return WsError.BadReservedBits;
    const opcode = Opcode.from_u8(op_byte) catch return WsError.InvalidOpcode;

    var len: usize = header[1] & 0x7F;
    const masked = (header[1] & 0x80) != 0;
    if (!masked) return WsError.UnmaskedFrame;

    if (len == 126) {
        var ext: [2]u8 = undefined;
        try readExact(rt, &session.socket, ext[0..2]);
        len = @intCast(std.mem.readInt(u16, ext[0..2], .big));
    } else if (len == 127) {
        var ext8: [8]u8 = undefined;
        try readExact(rt, &session.socket, ext8[0..8]);
        len = @intCast(std.mem.readInt(u64, ext8[0..8], .big));
    }

    if (len > Config.Ws.max_message_size) return WsError.MessageTooBig;

    if ((op_byte & 0b1000) != 0) { // check for control frame
        if (!fin) return WsError.ControlFrameFragmented;
        if (len > 125) return WsError.ControlFrameTooBig;
    }

    var mask: [4]u8 = undefined;
    try readExact(rt, &session.socket, mask[0..4]);
    var payload = alloc.alloc(u8, len) catch @panic("OOM");
    errdefer alloc.free(payload);

    if (len > 0) {
        try readExact(rt, &session.socket, payload);
        var i: usize = 0;
        while (i < payload.len) : (i += 1) {
            payload[i] ^= mask[i % 4];
        }
    }

    return WsFrame{ .fin = fin, .opcode = opcode, .payload = payload };
}

inline fn hashLowerAscii(s: []const u8) u64 {
    var h: u64 = 1469598103934665603; // FNV-1a 64
    for (s) |c| {
        var b = c;
        if (b >= 'A' and b <= 'Z') b = b + 32;
        h ^= @as(u64, b);
        h *%= 1099511628211;
    }
    return h;
}

fn connectionFrame(rt: *Runtime, client: Socket) !void {
    var session = try Session.init(rt.allocator, client, rt);
    defer session.deinit();

    while (true) {
        switch (session.state) {
            .Handshake => {
                _ = session.performHandshake() catch |e| {
                    std.log.debug("WsError on Handshake {s} for {any}", .{ @errorName(e), client.addr.in });
                    session.closeWithError(e);
                };
                session.state = .ReadingFrame;
                std.log.info("WS handshake complete, transitioning to reading frames.", .{});
            },
            .ReadingFrame, .ReadingFragmentedPayload => {
                const frame = try readFrame(rt, rt.allocator, &session);
                defer rt.allocator.free(frame.payload);
                try session.handleFrame(frame);
            },
            .Closing => {
                try Timer.delay(session.rt, .{ .seconds = 1 });
            },
        }
    }
}

const Utf8Status = enum { ok, invalid, partial };

inline fn utf8Valid(s: []const u8) bool {
    return utf8ValidateProgress(s) == .ok;
}

fn utf8ValidateProgress(s: []const u8) Utf8Status {
    var i: usize = 0;
    const n = s.len;
    while (i < n) : (i += 1) {
        const b0 = s[i];
        if (b0 <= 0x7F) continue; // ASCII
        // continuation byte as a start is invalid
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

fn acceptLoop(rt: *Runtime, server: *Socket) !void {
    std.log.info("WS accept loop active on rt={d}", .{rt.id});
    while (true) {
        const client = try server.accept(rt);
        std.log.info("WS accepted a client", .{});
        try rt.spawn(.{ rt, client }, connectionFrame, 1024 * 1024);
    }
}

pub fn host_ws(allocator: std.mem.Allocator) !void {
    var t = try Tardy.init(allocator, .{ .threading = .single });
    defer t.deinit();

    var socket = try Socket.init(.{ .tcp = .{ .host = Config.Ws.address, .port = Config.Ws.port } });
    defer socket.close_blocking();
    try socket.bind();
    try socket.listen(1024);
    std.log.info("WS listening on {s}:{d}", .{ Config.Ws.address, Config.Ws.port });

    const EntryParams = struct {
        socket: *Socket,
    };

    try t.entry(EntryParams{ .socket = &socket }, struct {
        fn entry(rt: *Runtime, p: EntryParams) !void {
            std.log.info("WS entry on rt={d}; spawning accept loop", .{rt.id});
            // Spawn an accept loop per runtime.
            if (rt.spawn(.{ rt, p.socket }, acceptLoop, 256 * 1024)) |_| {
                std.log.info("WS accept loop spawned on rt={d}", .{rt.id});
            } else |e| {
                std.log.err("WS accept loop spawn failed on rt={d}: {}", .{ rt.id, e });
            }
        }
    }.entry);
}

// test "handshake success (fragmented input) produces 101 + correct Accept" {
//     const req =
//         "GET /chat HTTP/1.1\r\n" ++
//         "Host: x\r\n" ++
//         "Upgrade: websocket\r\n" ++
//         "Connection: keep-alive, Upgrade\r\n" ++
//         "Sec-WebSocket-Key: dGhlIHNhbXBsZSBub25jZQ==\r\n" ++
//         "Sec-WebSocket-Version: 13\r\n" ++
//         "\r\n";

//     var sesh = try Session.init(std.testing.allocator, req, 5); // tiny chunks
//     defer sesh.deinit();

//     try sesh.performHandshake();
//     // try std.testing.expect(std.mem.startsWith(u8, out, "HTTP/1.1 101"));
//     // try std.testing.expect(std.mem.indexOf(u8, out, "Upgrade: websocket\r\n") != null);
//     // try std.testing.expect(std.mem.indexOf(u8, out, "Connection: Upgrade\r\n") != null);
//     // try std.testing.expect(std.mem.indexOf(u8, out, "Sec-WebSocket-Accept: s3pPLMBiTxaQ9kYGzzhZRbK+xOo=") != null);
// }

// test "handshake 400 when header count exceeds limit" {
//     // Build a request with many headers to exceed Config.Ws.handshake.max_headers (default 64).
//     var list = std.ArrayList(u8).init(std.testing.allocator);
//     defer list.deinit();

//     try list.appendSlice("GET / HTTP/1.1\r\n");
//     try list.appendSlice("Host: x\r\n");
//     // 65 dummy headers
//     var i: usize = 0;
//     while (i < 65) : (i += 1) {
//         try list.writer().print("X-{d}: a\r\n", .{i});
//     }
//     try list.appendSlice("Upgrade: websocket\r\n");
//     try list.appendSlice("Connection: Upgrade\r\n");
//     try list.appendSlice("Sec-WebSocket-Key: dGhlIHNhbXBsZSBub25jZQ==\r\n");
//     try list.appendSlice("Sec-WebSocket-Version: 13\r\n\r\n");

//     var sock = TestSock.init(std.testing.allocator, list.items, 1024);
//     defer sock.deinit();

//     try std.testing.expectError(error.BadHandshake, performHandshakeGeneric(std.testing.allocator, &sock));
//     try std.testing.expect(std.mem.startsWith(u8, sock.tx.items, "HTTP/1.1 400"));
// }

// test "sec-websocket-accept" {
//     const accept = blk: {
//         var sha1 = std.crypto.hash.Sha1.init(.{});
//         sha1.update("dGhlIHNhbXBsZSBub25jZQ==");
//         sha1.update("258EAFA5-E914-47DA-95CA-C5AB0DC85B11");
//         var digest: [20]u8 = undefined;
//         sha1.final(&digest);
//         var accept_buf: [28]u8 = undefined;
//         _ = std.base64.standard.Encoder.encode(&accept_buf, &digest);
//         break :blk accept_buf;
//     };
//     try std.testing.expectEqualStrings(
//         "s3pPLMBiTxaQ9kYGzzhZRbK+xOo=",
//         accept[0..], // or: (&accept)[0..]
//     );
// }

// test "handshake 400 when missing Upgrade header" {
//     const req =
//         "GET / HTTP/1.1\r\n" ++
//         "Host: x\r\n" ++
//         "Connection: Upgrade\r\n" ++
//         "Sec-WebSocket-Key: dGhlIHNhbXBsZSBub25jZQ==\r\n" ++
//         "Sec-WebSocket-Version: 13\r\n" ++
//         "\r\n";

//     var sock = TestSock.init(std.testing.allocator, req, 1024);
//     defer sock.deinit();

//     try std.testing.expectError(error.BadHandshake, performHandshakeGeneric(std.testing.allocator, &sock));
//     try std.testing.expect(std.mem.startsWith(u8, sock.tx.items, "HTTP/1.1 400"));
// }

// test "handshake 400 when Connection header lacks token 'upgrade' (case-insensitive tokenization)" {
//     const req =
//         "GET / HTTP/1.1\r\n" ++
//         "Host: x\r\n" ++
//         "Upgrade: WebSocket\r\n" ++
//         "Connection: keep-alive\r\n" ++
//         "Sec-WebSocket-Key: dGhlIHNhbXBsZSBub25jZQ==\r\n" ++
//         "Sec-WebSocket-Version: 13\r\n" ++
//         "\r\n";

//     var sock = TestSock.init(std.testing.allocator, req, 1024);
//     defer sock.deinit();

//     try std.testing.expectError(error.BadHandshake, performHandshakeGeneric(std.testing.allocator, &sock));
//     try std.testing.expect(std.mem.startsWith(u8, sock.tx.items, "HTTP/1.1 400"));
// }

// test "handshake 400 on bad Sec-WebSocket-Key (wrong length/base64)" {
//     const req =
//         "GET / HTTP/1.1\r\n" ++
//         "Host: x\r\n" ++
//         "Upgrade: websocket\r\n" ++
//         "Connection: Upgrade\r\n" ++
//         "Sec-WebSocket-Key: not_base64_here\r\n" ++
//         "Sec-WebSocket-Version: 13\r\n" ++
//         "\r\n";

//     var sock = TestSock.init(std.testing.allocator, req, 1024);
//     defer sock.deinit();

//     try std.testing.expectError(error.BadHandshake, performHandshakeGeneric(std.testing.allocator, &sock));
//     try std.testing.expect(std.mem.startsWith(u8, sock.tx.items, "HTTP/1.1 400"));
// }
