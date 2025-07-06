const std = @import("std");
const AnyCaseStringMap = @import("core").AnyCaseStringMap;
pub const Name = []const u8;
pub const Player = struct {
    id: u16,
    name: Name,
};
