pub const Seconds = f64;
pub const Point = struct {
    x: u16,
    y: u16,
};
pub const Cardinal = enum {
    north,
    northeast,
    east,
    southeast,
    south,
    southwest,
    west,
    northwest,
};
