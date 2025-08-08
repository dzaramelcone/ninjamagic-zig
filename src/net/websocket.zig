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
    opcode: u8,
    payload: []u8,
};

fn readFrame(rt: *Runtime, alloc: std.mem.Allocator, conn: *Conn) !Frame {
    var header: [2]u8 = undefined;
    try readExact(rt, &conn.socket, header[0..2]);
    const opcode = header[0] & 0x0F;
    var len: usize = header[1] & 0x7F;
    const masked = (header[1] & 0x80) != 0;
    if (len == 126) {
        var ext: [2]u8 = undefined;
        try readExact(rt, &conn.socket, ext[0..2]);
        len = std.mem.readIntBig(u16, ext[0..2]);
    } else if (len == 127) {
        var ext8: [8]u8 = undefined;
        try readExact(rt, &conn.socket, ext8[0..8]);
        len = @intCast(usize, std.mem.readIntBig(u64, ext8[0..8]));
    }
    var mask: [4]u8 = undefined;
    if (masked) try readExact(rt, &conn.socket, mask[0..4]);
    var payload = try alloc.alloc(u8, len);
    errdefer alloc.free(payload);
    if (len > 0) {
        try readExact(rt, &conn.socket, payload);
        if (masked) {
            var i: usize = 0;
            while (i < payload.len) : (i += 1) {
                payload[i] ^= mask[i % 4];
            }
        }
    }
    return Frame{ .opcode = opcode, .payload = payload };
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
    const key_off = std.mem.indexOf(u8, request, "Sec-WebSocket-Key: ") orelse return error.BadHandshake;
    const key_start = key_off + "Sec-WebSocket-Key: ".len;
    const key_end_rel = std.mem.indexOfScalar(u8, request[key_start..], '\r') orelse return error.BadHandshake;
    const key = request[key_start .. key_start + key_end_rel];
    var sha1 = std.crypto.hash.sha1.Sha1.init(.{});
    sha1.update(key);
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
    const hs = try performHandshake(rt, conn_ptr);
    var handler = try Handler(T).init(&hs, conn_ptr, ctx.impl);
    defer handler.close();
    while (true) {
        var frame = readFrame(rt, rt.allocator, conn_ptr) catch break;
        defer rt.allocator.free(frame.payload);
        switch (frame.opcode) {
            0x1, 0x2 => handler.clientMessage(frame.payload) catch {},
            0x8 => break,
            0x9 => try conn_ptr.sendFrame(0xA, frame.payload),
            0xA => {},
            else => {},
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
