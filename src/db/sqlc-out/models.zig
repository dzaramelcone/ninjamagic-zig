// Generated with sqlc v1.29.0
 
const std = @import("std");
const Allocator = std.mem.Allocator;


pub const User = struct {
    __allocator: Allocator,

    id: i64,
    email: []const u8,
    email_verified: i64,
    name: ?[]const u8,
    role: []const u8,
    notes: ?[]const u8,
    ip_address: ?[]const u8,
    last_login_at: ?i64,
    last_login_ip: ?[]const u8,
    created_at: i64,
    updated_at: i64,
    archived_at: ?i64,

    pub fn deinit(self: *const User) void {
        self.__allocator.free(self.email);
        if (self.name) |field| {
            self.__allocator.free(field);
        }
        self.__allocator.free(self.role);
        if (self.notes) |field| {
            self.__allocator.free(field);
        }
        if (self.ip_address) |field| {
            self.__allocator.free(field);
        }
        if (self.last_login_ip) |field| {
            self.__allocator.free(field);
        }
    }
};

pub const UserIdentity = struct {
    __allocator: Allocator,

    id: i64,
    user_id: i64,
    provider: []const u8,
    provider_user_id: []const u8,

    pub fn deinit(self: *const UserIdentity) void {
        self.__allocator.free(self.provider);
        self.__allocator.free(self.provider_user_id);
    }
};
