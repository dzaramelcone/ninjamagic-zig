const std = @import("std");
const zzz = @import("zzz");
const cfg = @import("core").Config;

const Tardy = zzz.tardy.Tardy(.auto);
const Runtime = zzz.tardy.Runtime;
const Socket = zzz.tardy.Socket;

var next_id: std.atomic.Value(usize) = .{ .raw = 1 };

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
            header[1] = @as(u8, payload.len);
        } else if (payload.len <= 0xFFFF) {
            header[1] = 126;
            std.mem.writeIntBig(u16, header[2..4], @as(u16, payload.len));
            header_len = 4;
        } else {
            header[1] = 127;
            std.mem.writeIntBig(u64, header[2..10], @as(u64, payload.len));
            header_len = 10;
        }
        try self.socket.send_all(self.rt, header[0..header_len]);
        if (payload.len > 0) try self.socket.send_all(self.rt, payload);
    }

    fn sendClose(self: *Conn, code: u16, reason: []const u8) !void {
        if (self.sent_close) return;
        self.sent_close = true;
        var buf: [125]u8 = undefined;
        std.mem.writeIntBig(u16, buf[0..2], code);
        var len: usize = 2;
        if (reason.len > 0) {
            const copy_len = @min(reason.len, buf.len - 2);
            std.mem.copy(u8, buf[2..2 + copy_len], reason[0..copy_len]);
            len += copy_len;
        }
        try self.sendFrame(0x8, buf[0..len]);
    }

    pub fn close(self: *Conn) void {
        self.socket.close_blocking();
    }
};

pub const Handshake = struct {};

pub fn Handler(comptime T: type) type {
    return struct {
        impl: *T,
        conn: *Conn,
        id: usize,

        pub fn init(h: *const Handshake, conn: *Conn, impl: *T) !@This() {
            _ = h;
            const id = next_id.fetchAdd(1, .monotonic);
            try impl.onConnect(id, conn);
            return .{ .impl = impl, .conn = conn, .id = id };
        }

        pub fn deinit(self: *@This()) void {
            self.impl.onDisconnect(self.id);
        }

        pub fn clientMessage(self: *@This(), raw: []const u8) !void {
            self.impl.onMessage(self.id, raw) catch |err| try self.conn.write(@errorName(err));
        }

        pub fn close(self: *@This()) void {
            self.deinit();
        }
    };
}

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
        len = std.mem.readIntBig(u16, ext[0..2]);
    } else if (len == 127) {
        var ext8: [8]u8 = undefined;
        try readExact(rt, &conn.socket, ext8[0..8]);
        len = @intCast(usize, std.mem.readIntBig(u64, ext8[0..8]));
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

fn performHandshake(rt: *Runtime, conn: *Conn) !Handshake {
    var buf: [cfg.Ws.handshake.max_size]u8 = undefined;
    var len: usize = 0;
    while (true) {
        const n = try conn.socket.recv(rt, buf[len..]);
        if (n == 0) return error.ConnectionClosed;
        len += n;
        if (std.mem.indexOf(u8, buf[0..len], "\r\n\r\n")) |_| break;
        if (len >= buf.len) return error.HandshakeTooLarge;
    }
    const request = buf[0..len];
    var it = std.mem.split(u8, request, "\r\n");
    const request_line = it.next() orelse {
        try conn.socket.send_all(rt, "HTTP/1.1 400 Bad Request\r\n\r\n");
        return error.BadHandshake;
    };
    if (!std.mem.startsWith(u8, request_line, "GET")) {
        try conn.socket.send_all(rt, "HTTP/1.1 400 Bad Request\r\n\r\n");
        return error.BadHandshake;
    }

    var key: ?[]const u8 = null;
    var upgrade: ?[]const u8 = null;
    var connection: ?[]const u8 = null;
    var version: ?[]const u8 = null;

    while (it.next()) |line| {
        if (line.len == 0) break;
        const colon = std.mem.indexOfScalar(u8, line, ':') orelse continue;
        const name = std.mem.trim(u8, line[0..colon], " \t");
        const value = std.mem.trim(u8, line[colon + 1 ..], " \t");
        if (std.ascii.eqlIgnoreCase(name, "sec-websocket-key")) key = value;
        else if (std.ascii.eqlIgnoreCase(name, "upgrade")) upgrade = value;
        else if (std.ascii.eqlIgnoreCase(name, "connection")) connection = value;
        else if (std.ascii.eqlIgnoreCase(name, "sec-websocket-version")) version = value;
    }

    if (key == null or upgrade == null or connection == null or version == null) {
        try conn.socket.send_all(rt, "HTTP/1.1 400 Bad Request\r\n\r\n");
        return error.BadHandshake;
    }
    if (!std.ascii.eqlIgnoreCase(upgrade.?, "websocket")) {
        try conn.socket.send_all(rt, "HTTP/1.1 400 Bad Request\r\n\r\n");
        return error.BadHandshake;
    }
    var conn_it = std.mem.split(u8, connection.?, ",");
    var has_upgrade = false;
    while (conn_it.next()) |tok| {
        if (std.ascii.eqlIgnoreCase(std.mem.trim(u8, tok, " \t"), "upgrade")) {
            has_upgrade = true;
            break;
        }
    }
    if (!has_upgrade or !std.ascii.eqlIgnoreCase(version.?, "13")) {
        try conn.socket.send_all(rt, "HTTP/1.1 400 Bad Request\r\n\r\n");
        return error.BadHandshake;
    }

    var key_decoded: [16]u8 = undefined;
    _ = std.base64.standard.Decoder.decode(&key_decoded, key.?) catch {
        try conn.socket.send_all(rt, "HTTP/1.1 400 Bad Request\r\n\r\n");
        return error.BadHandshake;
    };

    var sha1 = std.crypto.hash.sha1.Sha1.init(.{});
    sha1.update(key.?);
    sha1.update("258EAFA5-E914-47DA-95CA-C5AB0DC85B11");
    var digest: [20]u8 = undefined;
    sha1.final(&digest);
    var accept: [28]u8 = undefined;
    _ = std.base64.standard.Encoder.encode(&accept, &digest);
    var resp_buf: [256]u8 = undefined;
    const response = try std.fmt.bufPrint(
        &resp_buf,
        "HTTP/1.1 101 Switching Protocols\r\nUpgrade: websocket\r\nConnection: Upgrade\r\nSec-WebSocket-Accept: {s}\r\n\r\n",
        .{accept},
    );
    try conn.socket.send_all(rt, response);
    return Handshake{};
}

fn connectionFrame(comptime T: type, rt: *Runtime, ctx: struct { socket: Socket, impl: *T }) !void {
    var conn_ptr = try rt.allocator.create(Conn);
    conn_ptr.* = .{ .socket = ctx.socket, .rt = rt };
    defer {
        conn_ptr.close();
        rt.allocator.destroy(conn_ptr);
    }
    const hs = performHandshake(rt, conn_ptr) catch {
        conn_ptr.close();
        return;
    };
    var handler = Handler(T).init(&hs, conn_ptr, ctx.impl) catch {
        conn_ptr.close();
        return;
    };
    defer handler.close();

    var msg_buf = std.ArrayList(u8).init(rt.allocator);
    defer msg_buf.deinit();
    var msg_opcode: u8 = 0;

    while (true) {
        var frame = readFrame(rt, rt.allocator, conn_ptr) catch |err| {
            const code: u16 = switch (err) {
                error.UnmaskedFrame, error.BadRsv, error.ControlFrameFragmented,
                error.ControlFrameTooBig, error.InvalidOpcode => 1002,
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
                    if (msg_opcode == 0x1 and !std.unicode.utf8Validate(msg_buf.items)) {
                        conn_ptr.sendClose(1007, "") catch {};
                        break;
                    }
                    handler.clientMessage(msg_buf.items) catch {};
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
                    if (msg_opcode == 0x1 and !std.unicode.utf8Validate(msg_buf.items)) {
                        conn_ptr.sendClose(1007, "") catch {};
                        break;
                    }
                    handler.clientMessage(msg_buf.items) catch {};
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
                    code = std.mem.readIntBig(u16, frame.payload[0..2]);
                    reason = frame.payload[2..];
                    if (reason.len > 0 and !std.unicode.utf8Validate(reason)) {
                        conn_ptr.sendClose(1007, "") catch {};
                        break;
                    }
                }
                conn_ptr.sendClose(code, reason) catch {};
                break;
            },
            0x9 => {
                // ping
                conn_ptr.sendFrame(0xA, frame.payload) catch {};
            },
            0xA => {},
            else => {
                conn_ptr.sendClose(1002, "") catch {};
                break;
            },
        }
    }
}

fn acceptLoop(comptime T: type, rt: *Runtime, ctx: struct { socket: Socket, impl: *T }) !void {
    while (true) {
        const client = try ctx.socket.accept(rt);
        try rt.spawn(.{ client, ctx.impl }, connectionFrame(T), 1024 * 1024);
    }
}

pub fn host(comptime T: type, allocator: std.mem.Allocator, impl: *T) !void {
    var t = try Tardy.init(allocator, .{ .threading = .auto });
    defer t.deinit();
    var socket = try Socket.init(.{ .tcp = .{ .host = cfg.Ws.address, .port = cfg.Ws.port } });
    defer socket.close_blocking();
    try socket.bind();
    try socket.listen(1024);
    try t.entry(.{ .socket = socket, .impl = impl }, acceptLoop(T));
}

test "sec-websocket-accept" {
    const accept = blk: {
        var sha1 = std.crypto.hash.sha1.Sha1.init(.{});
        sha1.update("dGhlIHNhbXBsZSBub25jZQ==");
        sha1.update("258EAFA5-E914-47DA-95CA-C5AB0DC85B11");
        var digest: [20]u8 = undefined;
        sha1.final(&digest);
        var accept_buf: [28]u8 = undefined;
        _ = std.base64.standard.Encoder.encode(&accept_buf, &digest);
        break :blk accept_buf;
    };
    try std.testing.expectEqualStrings("s3pPLMBiTxaQ9kYGzzhZRbK+xOo=", accept);
}
