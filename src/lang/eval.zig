// Evaluator with TCO trampolining — see SPEC.md §11
const ast = @import("ast.zig");
const value = @import("value.zig");
const env = @import("env.zig");

pub fn eval(node: ast.Node, e: *env.Env) value.Value {
    _ = node;
    _ = e;
    return .null_val;
}
