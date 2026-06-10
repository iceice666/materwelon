// AST node types — see SPEC.md §3, Appendix A
const std = @import("std");

pub const Node = union(enum) {
    // Literals
    int_lit:    i64,
    float_lit:  f64,
    number_lit: []const u8,  // raw digit string (no N suffix), slice into source
    string_lit: []const u8,  // heap-allocated copy
    bool_lit:   bool,
    null_lit,

    // Compound literals
    list_lit:   []const Node,
    record_lit: []const RecordField,

    // Name lookup
    ident: []const u8,

    // Application — always binary; (f a b c) folds to App(App(App(f,a),b),c) at parse time
    app: *const App,

    // Special forms
    def:      *const Def,
    fn_lit:   *const FnNode,   // always single-param; multi-param desugared at parse time
    let:      *const Let,
    if_expr:  *const If,
    do_block: []const DoStmt,
    and_expr: []const Node,    // 2+ args, left-to-right short-circuit
    or_expr:  []const Node,

    pub const RecordField = struct {
        key: []const u8,
        val: Node,
    };

    pub const App = struct {
        func: Node,
        arg:  Node,
    };

    pub const Def = struct {
        name: []const u8,
        val:  Node,
    };

    // Single-parameter lambda. Multi-param desugared at parse time.
    pub const FnNode = struct {
        param: []const u8,
        body:  Node,
    };

    pub const Let = struct {
        name: []const u8,
        val:  Node,
        body: Node,
    };

    pub const If = struct {
        cond:  Node,
        then:  Node,
        else_: Node,
    };

    pub const DoStmt = union(enum) {
        bind: struct { name: []const u8, expr: Node },
        expr: Node,
    };
};
