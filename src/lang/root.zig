//! Language library root — pure, no platform dependencies, host-testable.
//! Pipeline: lexer → parser → eval, with stdlib/ops as the builtin
//! implementations. SPEC.md is the language contract.
pub const errors = @import("errors.zig");
pub const lexer = @import("lexer.zig");
pub const ast = @import("ast.zig");
pub const parser = @import("parser.zig");
pub const value = @import("value.zig");
pub const env = @import("env.zig");
pub const ops = @import("ops.zig");
pub const eval = @import("eval.zig");
pub const stdlib = @import("stdlib.zig");

// Pull all submodule tests into the lang test binary.
test {
    _ = errors;
    _ = lexer;
    _ = parser;
    _ = value;
    _ = env;
    _ = ops;
    _ = eval;
    _ = stdlib;
    _ = @import("eval_test.zig");
}
