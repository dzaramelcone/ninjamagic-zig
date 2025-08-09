const std = @import("std");
const assert = std.debug.assert;

const Task = @import("task.zig").Task;
const Runtime = @import("lib.zig").Runtime;
const Frame = @import("../frame/lib.zig").Frame;

const Pool = @import("../core/pool.zig").Pool;
const PoolKind = @import("../core/pool.zig").PoolKind;
const Queue = @import("../core/queue.zig").Queue;

pub const AsyncSubmission = @import("../aio/lib.zig").AsyncSubmission;

const AtomicDynamicBitSet = @import("../core/atomic_bitset.zig").AtomicDynamicBitSet;

const TaskWithJob = struct {
    task: Task,
    job: ?AsyncSubmission = null,
};

/// Scheduler: cooperatively schedules Tasks (Frames) and brokers async I/O.
///
/// - Tracks runnable vs waiting tasks via a dense pool + bitsets.
/// - `io_await` moves the current task to wait_for_io and yields; completions mark it runnable.
/// - `trigger_await` is a lightweight software wait primitive (not I/O-backed).
///
/// Compared to work-stealing schedulers, this design is simpler, predictable,
/// and per-thread. It avoids cross-thread task migration but requires the user
/// to balance load if needed.
pub const Scheduler = struct {
    allocator: std.mem.Allocator,
    tasks: Pool(Task),
    runnable: usize,
    released: std.ArrayListUnmanaged(usize),
    triggers: AtomicDynamicBitSet,

    pub fn init(allocator: std.mem.Allocator, size: usize, pooling: PoolKind) !Scheduler {
        var tasks = try Pool(Task).init(allocator, size, pooling);
        errdefer tasks.deinit();

        var released = try std.ArrayListUnmanaged(usize).initCapacity(allocator, size);
        errdefer released.deinit(allocator);

        const triggers = try AtomicDynamicBitSet.init(allocator, size, false);
        errdefer triggers.deinit(allocator);

        return .{
            .allocator = allocator,
            .tasks = tasks,
            .runnable = 0,
            .released = released,
            .triggers = triggers,
        };
    }

    pub fn deinit(self: *Scheduler) void {
        self.tasks.deinit();
        self.released.deinit(self.allocator);
        self.triggers.deinit(self.allocator);
    }

    pub fn set_runnable(self: *Scheduler, index: usize) !void {
        const task = self.tasks.get_ptr(index);
        assert(task.state != .runnable);
        task.state = .runnable;
        self.runnable += 1;
    }

    /// Put the current task to sleep waiting for a software trigger.
    /// Use `Runtime.trigger(idx)` from another thread to wake it.
    pub fn trigger_await(self: *Scheduler) !void {
        const rt: *Runtime = @fieldParentPtr("scheduler", self);
        const index = rt.current_task.?;
        const task = self.tasks.get_ptr(index);

        // To waiting...
        task.state = .wait_for_trigger;
        self.runnable -= 1;

        Frame.yield();
    }

    // NOTE: This can spuriously trigger a Task later in the Run Loop.
    /// Safe to call from a different Runtime.
    pub fn trigger(self: *Scheduler, index: usize) !void {
        try self.triggers.set(index);
    }

    /// Await an async I/O `job`: moves the current task to `wait_for_io`,
    /// enqueues the job on the Async runner, and yields.
    /// Only call from the owning Runtime thread; it assumes `current_task` is set.
    pub fn io_await(self: *Scheduler, job: AsyncSubmission) !void {
        const rt: *Runtime = @fieldParentPtr("scheduler", self);
        const index = rt.current_task.?;
        const task = self.tasks.get_ptr(index);

        // To waiting...
        task.state = .wait_for_io;
        self.runnable -= 1;

        // Queue the related I/O job.
        try rt.aio.queue_job(index, job);
        Frame.yield();
    }

    /// Create a new Frame and make it runnable.
    pub fn spawn(self: *Scheduler, frame_ctx: anytype, comptime frame_fn: anytype, stack_size: usize) !void {
        const index = blk: {
            if (self.released.pop()) |index| {
                break :blk self.tasks.borrow_assume_unset(index);
            } else {
                break :blk try self.tasks.borrow();
            }
        };

        const frame = try Frame.init(self.allocator, stack_size, frame_ctx, frame_fn);

        const item: Task = .{ .index = index, .frame = frame, .state = .dead };
        const item_ptr = self.tasks.get_ptr(index);
        item_ptr.* = item;
        try self.set_runnable(index);
    }

    pub fn release(self: *Scheduler, index: usize) !void {
        // must be runnable to set?
        const task = self.tasks.get_ptr(index);
        assert(task.state == .runnable);
        task.state = .dead;
        self.runnable -= 1;

        self.tasks.release(index);
        try self.released.append(self.allocator, index);
    }
};
