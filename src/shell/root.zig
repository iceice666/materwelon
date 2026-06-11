//! Shell layer root — the platform-agnostic REPL, driven through the Io
//! function-pointer interface that each platform (rp2350, host) implements.
pub const repl = @import("repl.zig");
pub const Io = repl.Io;

// Pull submodule tests into the shell test binary.
test {
    _ = repl;
}
