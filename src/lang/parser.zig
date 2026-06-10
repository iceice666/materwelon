// Parser: token stream → AST — see SPEC.md §3, Appendix A
const std = @import("std");
const ast = @import("ast.zig");
const lexer = @import("lexer.zig");

pub fn parse(alloc: std.mem.Allocator, tokens: []const lexer.Token) !ast.Node {
    _ = alloc;
    _ = tokens;
    return error.NotImplemented;
}
