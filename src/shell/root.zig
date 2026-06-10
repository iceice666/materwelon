pub const repl = @import("repl.zig");

/// Platform-agnostic I/O interface — filled in by the platform layer.
pub const Io = struct {
    read_byte: *const fn () ?u8,
    write_bytes: *const fn ([]const u8) void,
    flush: *const fn () void,
};
