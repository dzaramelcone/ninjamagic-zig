const std = @import("std");

// Aggregate tests from all modules so `zig build test`
// executes the entire project's suite from one entry.
test {
    const core = @import("core/module.zig");
    const sys = @import("sys/module.zig");
    const net = @import("net/module.zig");

    std.testing.refAllDecls(core);
    std.testing.refAllDecls(sys);
    std.testing.refAllDecls(net);

    // DB tests (direct file import).
    std.testing.refAllDecls(@import("db.zig"));
}

