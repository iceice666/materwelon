pub const repl = @import("repl.zig");
pub const Io = repl.Io;

// Pull submodule tests into the shell test binary.
test {
    _ = repl;
}
