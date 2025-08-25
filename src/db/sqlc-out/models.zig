// Generated with sqlc v1.29.0
 
const std = @import("std");
const Allocator = std.mem.Allocator;


pub const User = struct {
    __allocator: Allocator,

    id: i64,
    name: []const u8,
    secret: []const u8,

    pub fn deinit(self: *const User) void {
        self.__allocator.free(self.name);
        self.__allocator.free(self.secret);
    }
};
