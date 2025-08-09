Using Tardy in This Project
===========================

This guide captures the patterns and pitfalls we use with the vendored Tardy runtime in the MUD server.

Key Rules
- Do async I/O inside a Runtime task. From non‑runtime threads, schedule a task on the connection’s runtime.
- Synchronize shared state accessed by both the main thread and Tardy runtimes (e.g., protect connection maps with a mutex).
- Prefer short tasks that yield on I/O to keep the runtime responsive.

Patterns

1) Accept + Session per Connection
- Where: `src/net/websocket.zig`
- Pattern: In `host_ws`, spawn an `acceptLoop` on each runtime. On `accept`, spawn a `connectionFrame` task to handshake and run the WebSocket session.

2) Safe Cross‑Thread Writes (from main tick)
- Where: `src/state.zig` and `src/net/websocket.zig`
- Problem: main game loop is not inside a Tardy task; writing directly will panic at `io_await`.
- Solution: schedule a small write task on the connection’s runtime using `Conn.writeAsync`:

```zig
// src/net/websocket.zig
pub fn writeAsync(self: *Conn, data: []const u8) !void {
    const out_buf = try self.rt.allocator.alloc(u8, data.len);
    @memcpy(out_buf, data);
    const rt_ptr = self.rt;
    const sock_copy = self.socket; // move Socket by value
    try rt_ptr.spawn(.{ rt_ptr, sock_copy, out_buf }, struct {
        fn send_task(rt: *Runtime, sock: Socket, payload: []u8) !void {
            defer rt.allocator.free(payload);
            var header: [2]u8 = .{ 0x81, @intCast(payload.len) }; // small text frames
            var w = sock.writer(rt);
            w.writeAll(&header) catch return;
            if (payload.len > 0) _ = w.write(payload) catch return;
        }
    }.send_task, 16 * 1024);
}
```

3) Outbox Flush Without Races
- Where: `src/state.zig`
- Pattern: flush queued packets, look up the connection under `conns_mutex`, then call `writeAsync` without holding the lock.

```zig
var it = try sys.outbox.flush(arena);
while (it.next()) |pkt| {
    self.conns_mutex.lock();
    const conn = self.conns.get(pkt.recipient) orelse { self.conns_mutex.unlock(); continue; };
    self.conns_mutex.unlock();
    try conn.writeAsync(pkt.body);
}
```

4) Synchronizing Connection Map
- Where: `src/state.zig`
- Rule: hold `conns_mutex` when mutating or iterating the map; avoid doing I/O while holding the lock.

5) Logging
- Where: `src/net/websocket.zig` (receive), `src/state.zig` (send)
- Pattern: per‑message logs to aid debugging and tests: `WS recv id=…`, `WS send id=…`.

6) Test Expectations
- Pytests in `pytest/test_ws_chat.py` expect compact JSON arrays from `sys.outbox`.

Common Pitfalls
- Panic: `attempt to use null value` in `scheduler.io_await` → calling I/O off‑runtime. Use `writeAsync`/spawn.
- Data races (segfaults) when `onDisconnect` mutates the connection map while the main loop iterates → protect with a mutex and don’t hold it during I/O.

Operational Notes
- Build/run locally: `zig build run -Doptimize=Debug`
- Tests: `zig build test` (Zig unit tests). Python tests require a running server; use `pytest/` from a venv or `dcr test` in Docker.

