Tardy Runtime (vendored)
========================

This document explains the vendored Tardy runtime under `embed/vendor/tardy/src`, file by file. It outlines each module’s purpose, key types and APIs, important invariants, concurrency rules, and usage patterns relevant to this project.

Conventions
- “Runtime” refers to `runtime/lib.zig`. One Runtime exists per OS thread.
- “Frame” is a stackful coroutine (heap stack + context) in `frame/lib.zig`.
- “Task” is the scheduler entry for a Frame.
- All async I/O must run from inside a Runtime task (with `rt.current_task` set).
- From non‑Runtime threads, reschedule work onto a Runtime with `rt.spawn`.

Top‑Level: src/lib.zig
- Re‑exports core pieces: `Runtime`, `Task`, `Timer`, `Socket`, `Stream`, FS, channels, and result types from aio.
- `Tardy(comptime selected_aio_type: AsyncType)` returns a concrete Tardy type bound to an async backend.
  - `TardyOptions`:
    - `threading`: `.single | .multi(N) | .all | .auto` (auto = ~half CPUs − 1).
    - `pooling`: `.grow | .static` pools for tasks and AIO.
    - `size_tasks_initial`, `size_aio_reap_max`.
  - `init(allocator, options)` → instance holding allocator, options, a list of per‑thread AIO runners.
  - `spawn_runtime(id, AsyncOptions)` → creates a `Runtime` bound to one AIO instance.
  - `entry(entry_params, entry_func)` → spawns 1..N runtimes and calls `entry_func(*Runtime, entry_params)` on each; then runs their event loops.

Inline API References
- `src/lib.zig`
  - `pub const Runtime = @import("runtime/lib.zig").Runtime;`
  - `pub fn Tardy(comptime selected_aio_type: AsyncType) type { ... }`
  - `fn spawn_runtime(self: *Self, id: usize, options: AsyncOptions) !Runtime`
  - `pub fn entry(self: *Self, entry_params: anytype, comptime entry_func: *const fn(*Runtime, @TypeOf(entry_params)) anyerror!void) !void`

Runtime: src/runtime/lib.zig
- `Runtime` fields: `allocator`, `storage`, `scheduler`, `aio`, `id`, `running`, `current_task`.
- Lifecycle:
  - `init(allocator, aio, options)`; `deinit()` frees scheduler, storage, AIO buffers.
  - `run()` event loop:
    - Drives runnable tasks, transitions tasks waiting for triggers/I/O, submits AIO, reaps completions, and continues until no runnable tasks or `stop()`.
  - `spawn(frame_ctx, frame_fn, stack_size)` → create new Frame task.
  - `wake()`, `trigger(index)` are cross‑thread safe; they notify the runtime and mark tasks runnable.
  - `stop()` ends the loop (cross‑thread safe).
- Invariants: All async I/O must occur with `current_task` set by the scheduler; otherwise methods like `io_await` will panic on null.

Inline API References
- `src/runtime/lib.zig`
  - `pub fn init(allocator: std.mem.Allocator, aio: Async, options: RuntimeOptions) !Runtime`
  - `pub fn run(self: *Runtime) !void`
  - `pub fn spawn(self: *Runtime, frame_ctx: anytype, comptime frame_fn: anytype, stack_size: usize) !void`
  - `pub fn wake(self: *Runtime) !void`
  - `pub fn trigger(self: *Runtime, index: usize) !void`
  - `pub fn stop(self: *Runtime) void`

Scheduler: src/runtime/scheduler.zig
- Holds a `Pool(Task)` and bookkeeping:
  - `set_runnable(index)`, `release(index)`, `iterator()`.
  - `io_await(job)`: marks `current_task` as `wait_for_io`, enqueues a job on the AIO runner, yields.
  - `trigger(index)`: sets a trigger bit; later the loop transitions it to runnable.
  - `spawn(frame_ctx, frame_fn, stack_size)`: allocates a Frame and places a runnable Task in the pool.
- Task states: `.runnable | .wait_for_io | .wait_for_trigger | .dead`.

Inline API References
- `src/runtime/scheduler.zig`
  - `pub fn init(allocator: std.mem.Allocator, size: usize, pooling: PoolKind) !Scheduler`
  - `pub fn set_runnable(self: *Scheduler, index: usize) !void`
  - `pub fn trigger_await(self: *Scheduler) !void`
  - `pub fn trigger(self: *Scheduler, index: usize) !void`
  - `pub fn io_await(self: *Scheduler, job: AsyncSubmission) !void`
  - `pub fn spawn(self: *Scheduler, frame_ctx: anytype, comptime frame_fn: anytype, stack_size: usize) !void`
  - `pub fn release(self: *Scheduler, index: usize) !void`

Task: src/runtime/task.zig
- `Task` = `{ state, result, index, frame }`.
- `result` is a tagged union for AIO completions (`aio/completion.zig`).

Timer: src/runtime/timer.zig
- `Timer.delay(rt, timespec)` submits a timer job via `rt.scheduler.io_await`.

Storage: src/runtime/storage.zig
- Small per‑runtime arena + `StringHashMapUnmanaged(*anyopaque)` for named values.
- `store_ptr`, `store_alloc`, `store_alloc_ret`, `get`, `get_ptr`, `get_const_ptr`.
- Deleteless/clobberless by design.

Frames (Coroutines): src/frame/lib.zig
- Platform shims for context switching:
  - x86_64 SysV, x86_64 Windows, aarch64 (general).
- `Frame.init(allocator, stack_size, args, func)` → allocates a heap stack, lays out frame metadata and arguments, and sets entry point.
- `proceed()` swaps to Frame; `yield()` swaps back to caller.
- `deinit()` frees the stack.
- Invariants:
  - Cooperatively scheduled: code must yield (usually by AIO) to let other tasks run.
  - Choose stack sizes based on call depth; too small → `error.StackTooSmall`.

Async I/O Model: src/aio/lib.zig
- `AsyncKind` / `AsyncType`: `.io_uring | .epoll | .kqueue | .poll | .custom | .auto` (auto matches OS).
- `AsyncOptions`: inherits pooling sizes from parent, sets completion capacity.
- `AsyncFeatures`: backend capability bitmask (send/recv/accept/…).
- `AsyncSubmission`: union of all possible operations (timer, open, recv, send, etc.).
- `Async` façade wraps a backend runner with vtable:
  - `attach(completions)`, `queue_job(task, job)`, `wake()`, `reap(wait)`, `submit()`.
- AIO Backends: src/aio/apis
  - `epoll.zig`, `kqueue.zig`, `poll.zig` (and `io_uring.zig` if Linux 5.1+).
  - Map posix errors to typed error enums; implement queue/reap/submit for each op.

Completions & Errors: src/aio/completion.zig
- `Resulted(T,E)` = tagged union with `.actual` or `.err`; `unwrap()` returns `E!T`.
- Error enums for Accept/Connect/Recv/Send/Open/Read/Write/Stat/Mkdir/Delete…
- `Completion { task: usize, result: Result }` where `Result` covers all operation result kinds.

Networking: src/net/socket.zig, src/net/lib.zig
- `Socket` wraps a non‑blocking fd and address; supports `.tcp | .udp | .unix`.
- `init(kind)`, `init_with_address(kind, addr)`: set CLOEXEC/NONBLOCK and REUSE{PORT,ADDR}.
- `bind()`, `listen(backlog)`, `close(rt)`, `close_blocking()`.
- I/O:
  - `accept(rt)` returns a new `Socket` (uses AIO if capable; otherwise falls back to non‑blocking loop with `Frame.yield()`).
  - `connect(rt)`, `recv(rt, buf)`, `recv_all(rt, buf)`, `send(rt, buf)`, `send_all(rt, buf)`.
  - `writer(rt)` / `reader(rt)`: std.io adapters that call `send/recv` under the hood.
- Concurrency rules:
  - All calls that may await must be invoked inside a Runtime task. Using them from a plain thread will panic at `io_await` (null `current_task`).

Filesystem: src/fs/*
- `fs/lib.zig` re‑exports `File`, `Dir`, `Path`, `Stat`.
- `file.zig` / `dir.zig`: open/read/write/stat/mkdir/delete using AIO; map errors to typed enums.

Inline API References
- `src/fs/file.zig`
  - `pub fn open(rt: *Runtime, path: Path, flags: AsyncOpenFlags) !File` (via AIO)
  - `pub fn reader(self: File, rt: *Runtime) Reader`
  - `pub fn writer(self: File, rt: *Runtime) Writer`
- `src/fs/dir.zig`
  - Directory create/delete helpers backed by AIO

Streams: src/stream.zig
- `Stream` is a virtual read/write trait (vtable) that wraps any type implementing `read(rt, []u8)` and `write(rt, []const u8)`.
- `Stream.copy(rt, from, to, buf)` shuttles data until EOF/Closed.

Inline API References
- `src/stream.zig`
  - `pub const Stream = struct { pub fn read(...), pub fn write(...), pub fn copy(...) }`

Channels: src/channel/spsc.zig
- Single‑producer/single‑consumer ring (lockless) for passing data between two parties.
- Useful inside a single Runtime or where external synchronization ensures correctness.

Inline API References
- `src/channel/spsc.zig`
  - `pub fn Spsc(comptime T: type) type`
    - `Producer.send(message: T) !void`
    - `Producer.close() void`
    - `Consumer.recv() !T`
    - `Consumer.close() void`
    - `init(allocator, size) !Self`, `deinit()`, `producer(rt)`, `consumer(rt)`

Cross: src/cross/*
- Thin platform helpers (FD, sockets) used by AIO backends; normalize OS differences.

Core Utilities: src/core/*
- `pool.zig`: dense pool with bitset tracking; `.static` or `.grow`; iterator over set bits.
- `queue.zig` / `ring.zig` / `atomic_ring.zig`: queues/rings for schedulers/backends.
- `atomic_bitset.zig`: bitset for triggers and bookkeeping.
- `zero_copy.zig`: helpers for minimal copies in pipelines.

Testing Artifacts: src/tests.zig
- Pulls in unit tests for components (pool behavior, outbox expectations, etc.).

Integration Patterns (Project‑Specific)
- Accept loops per runtime:
  - Bind/listen once; in `entry(rt, params)`, spawn `acceptLoop` per runtime to scale.
- Per‑connection session frame:
  - On `accept`, spawn a `connectionFrame` that handshakes, reads WebSocket frames, and dispatches messages.
- Cross‑thread packet sends (safe):
  - From a non‑Runtime thread (e.g., main tick), don’t call `Socket.writer(rt).writeAll()` directly.
  - Instead, spawn a small task on the connection’s runtime that writes (copy the payload into the runtime allocator to outlive the caller). Example pattern:

```zig
// Given: conn: *Conn { socket: Socket, rt: *Runtime }
pub fn writeAsync(conn: *Conn, data: []const u8) !void {
    const payload = try conn.rt.allocator.alloc(u8, data.len);
    @memcpy(payload, data);
    const sock = conn.socket; // copy by value
Inline API References
- `src/frame/lib.zig`
  - `pub fn init(allocator: std.mem.Allocator, stack_size: usize, args: anytype, comptime func: anytype) !*Frame`
  - `pub fn proceed(frame: *Frame) void`
  - `pub fn yield() void`

Inline API References
- `src/aio/lib.zig`
  - `pub fn auto_async_match() AsyncType`
  - `pub fn async_to_type(comptime aio: AsyncType) type`
  - `pub const AsyncFeatures` with `pub fn has_capability(self: AsyncFeatures, op: AsyncOp) bool`
  - `pub const AsyncSubmission = union(AsyncOp) { ... }`
  - `pub const Async`
    - `pub fn attach(self: *Async, completions: []Completion) void`
    - `pub fn queue_job(self: *Async, task: usize, job: AsyncSubmission) !void`
    - `pub fn wake(self: *Async) !void`
    - `pub fn reap(self: *Async, wait: bool) ![]Completion`
    - `pub fn submit(self: *Async) !void`
- `src/aio/completion.zig`
  - `pub fn Resulted(T,E) type` with `unwrap()`
  - `pub const Completion = struct { task: usize, result: Result }`

Inline API References
- `src/net/socket.zig`
  - `pub const InitKind = union(Kind) { tcp, udp, unix }`
  - `pub fn init(kind: InitKind) !Socket`
  - `pub fn init_with_address(kind: Kind, addr: std.net.Address) !Socket`
  - `pub fn bind(self: Socket) !void`
  - `pub fn listen(self: Socket, backlog: usize) !void`
  - `pub fn accept(self: Socket, rt: *Runtime) !Socket`
  - `pub fn connect(self: Socket, rt: *Runtime) !void`
  - `pub fn recv(self: Socket, rt: *Runtime, buffer: []u8) !usize`
  - `pub fn send(self: Socket, rt: *Runtime, buffer: []const u8) !usize`
  - `pub fn reader(self: Socket, rt: *Runtime) Reader`
  - `pub fn writer(self: Socket, rt: *Runtime) Writer`
  - `pub fn close(self: Socket, rt: *Runtime) !void`
  - `pub fn close_blocking(self: Socket) void`
    const rt_ptr = conn.rt;
    try rt_ptr.spawn(.{ rt_ptr, sock, payload }, struct {
        fn task(rt: *Runtime, sock: Socket, payload: []u8) !void {
            defer rt.allocator.free(payload);
            var w = sock.writer(rt);
            _ = w.write(payload) catch {};
        }
    }.task, 16 * 1024);
}
```

Key Trade‑Offs
- Stackful coroutines (Frames): direct‑style code; memory per task; tiny ASM shims.
- Cooperative scheduling: very low overhead; user responsible for fairness; no preemption.
- Per‑thread runtimes: simple and low contention; no work‑stealing (possible imbalance).
- Minimal abstractions: fast to reason about; you own synchronization and thread affinity.

Common Pitfalls
- Panic at `io_await` due to `rt.current_task` = null: Don’t perform async I/O from non‑runtime threads. Schedule a task on the connection’s runtime.
- Data races on user state (e.g., connection maps): Guard with a mutex or funnel changes onto a single thread.
- Oversized/undersized frame stacks: choose stack sizes based on real call depth.
