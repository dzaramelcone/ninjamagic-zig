const Bus = @import("core").Channel(Envelope, 1_024);
pub const Envelope = struct {
    player_id: u16,
    input: []const u8,
};
