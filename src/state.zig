const std = @import("std");
const core = @import("core");
const sys = @import("sys");
const net = @import("net");

const Channel = core.Channel(core.sig.Signal, std.math.pow(usize, 2, 10));

pub const State = struct {
    alloc: std.mem.Allocator,

    now: core.Seconds,

    conns: std.AutoArrayHashMap(usize, *net.Conn),
    // Protects concurrent access to `conns` between the main tick thread
    // and Tardy runtime threads invoking WS callbacks.
    conns_mutex: std.Thread.Mutex = .{},
    channel: Channel,

    pub fn init(alloc: std.mem.Allocator) !State {
        try sys.move.init(alloc);
        sys.act.init(alloc);
        return .{
            .alloc = alloc,
            .now = 0,
            .conns = std.AutoArrayHashMap(usize, *net.Conn).init(alloc),
            .channel = Channel{},
        };
    }

    pub fn deinit(self: *State) void {
        self.conns.deinit();
    }

    pub fn step(self: *State, dt: core.Seconds) !void {
        self.now += dt;
        var arena_allocator = std.heap.ArenaAllocator.init(self.alloc);
        defer arena_allocator.deinit();
        const arena = arena_allocator.allocator();
        // Pull messages off the queue.
        for (self.channel.flip()) |sig| {
            core.bus.enqueue(sig) catch continue;
        }

        // Handle actions.
        sys.act.step(self.now);

        // Handle moves.
        sys.move.step();

        sys.sight.step();

        try sys.emit.step(arena);

        // Send all pending packets to clients.
        var it = try sys.outbox.flush(arena);
        while (it.next()) |pkt| {
            // Lookup under lock; do not perform async I/O while holding it.
            self.conns_mutex.lock();
            const conn = self.conns.get(pkt.recipient) orelse {
                self.conns_mutex.unlock();
                continue;
            };
            const c = conn;
            self.conns_mutex.unlock();
            const peek_len: usize = @min(pkt.body.len, 120);
            std.log.info("WS send id={d} len={d} peek={s}", .{ pkt.recipient, pkt.body.len, pkt.body[0..peek_len] });
            // Schedule write on the connection's runtime to avoid calling
            // Tardy I/O from a non-runtime thread.
            try c.writeAsync(pkt.body);
        }
    }

    pub fn onMessage(self: *State, user: usize, msg: []const u8) !void {
        const sig = sys.parser.parse(.{ .user = user, .text = msg }) catch return;
        if (!self.channel.push(sig)) return error.ServerBacklogged;
    }

    pub fn onConnect(self: *State, id: usize, c: *net.Conn) !void {
        // Add to connection map first.
        self.conns_mutex.lock();
        try self.conns.put(id, c);
        self.conns_mutex.unlock();
    }

    pub fn onDisconnect(self: *State, id: usize) void {
        self.conns_mutex.lock();
        defer self.conns_mutex.unlock();
        if (self.conns.swapRemove(id)) std.log.debug("{d} disconnected.", .{id});
    }

    pub fn broadcast(self: *State, text: []const u8) !void {
        self.conns_mutex.lock();
        var it = self.conns.iterator();
        // Collect snapshot to avoid holding lock during I/O
        var tmp = std.ArrayList(*net.Conn).init(self.alloc);
        defer tmp.deinit();
        while (it.next()) |kv| {
            // Best-effort; skip on OOM
            tmp.append(kv.value_ptr.*) catch {};
        }
        self.conns_mutex.unlock();

        for (tmp.items) |conn| {
            conn.writeAsync(text) catch |err| std.log.err("ws writeAsync: {s}", .{@errorName(err)});
        }
    }
};
