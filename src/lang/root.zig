pub const lexer = @import("lexer.zig");
pub const ast = @import("ast.zig");
pub const parser = @import("parser.zig");
pub const value = @import("value.zig");
pub const env = @import("env.zig");
pub const eval = @import("eval.zig");
pub const stdlib = @import("stdlib.zig");

// Pull all submodule tests into the lang test binary.
test {
    _ = lexer;
    _ = parser;
    _ = value;
    _ = env;
    _ = eval;
    _ = stdlib;
}
