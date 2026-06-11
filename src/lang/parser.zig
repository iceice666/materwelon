//! Parser: token stream → AST — see SPEC.md §3 and Appendix A.
//! Pratt-style precedence climbing for the infix operators (§3.4); all
//! desugaring (multi-param fn, do-block `<-`, infix data-last) happens here,
//! so eval.zig only ever sees the core forms.
const std = @import("std");
const ast = @import("ast.zig");
const lexer = @import("lexer.zig");
const errors = @import("errors.zig");

const Node    = ast.Node;
const Token   = lexer.Token;
const Tag     = std.meta.Tag(Token);

pub const ParseError = errors.ParseError;

// ─── Parser state ─────────────────────────────────────────────────────────────

const Parser = struct {
    alloc:  std.mem.Allocator,
    tokens: []const Token,
    pos:    usize,

    fn peek(p: *Parser) Token {
        return p.tokens[p.pos];
    }

    fn peekTag(p: *Parser) Tag {
        return std.meta.activeTag(p.tokens[p.pos]);
    }

    fn advance(p: *Parser) Token {
        const t = p.tokens[p.pos];
        if (p.pos + 1 < p.tokens.len) p.pos += 1;
        return t;
    }

    fn eat(p: *Parser, comptime tag: Tag) ParseError!void {
        if (p.peekTag() == tag) {
            _ = p.advance();
        } else {
            return error.UnexpectedToken;
        }
    }

    fn atEnd(p: *Parser) bool {
        return p.peekTag() == .Eof;
    }

    // True if the next token has the given tag.
    fn is(p: *Parser, comptime tag: Tag) bool {
        return p.peekTag() == tag;
    }
};

// ─── Public entry point ───────────────────────────────────────────────────────

/// Parse a single top-level expression from the token stream.
pub fn parse(alloc: std.mem.Allocator, tokens: []const lexer.Token) ParseError!Node {
    var p = Parser{ .alloc = alloc, .tokens = tokens, .pos = 0 };
    return parseExpr(&p, 0);
}

// ─── Pratt infix table ────────────────────────────────────────────────────────

const BP = struct { left: u8, right: u8 };

fn infixBP(tag: Tag) ?BP {
    return switch (tag) {
        .Pipe_Fwd   => .{ .left = 2,  .right = 2  },
        .KW_OR      => .{ .left = 4,  .right = 4  },
        .KW_AND     => .{ .left = 6,  .right = 6  },
        .Eq,
        .Not_Eq,
        .L_Angle,
        .R_Angle,
        .Less_Eq,
        .Greater_Eq => .{ .left = 8,  .right = 9  },  // non-assoc
        .Concat     => .{ .left = 10, .right = 10 },
        .Plus,
        .Minus      => .{ .left = 12, .right = 12 },
        .Multiply,
        .Divide,
        .KW_MOD     => .{ .left = 14, .right = 14 },
        .Colon      => .{ .left = 18, .right = 18 },  // highest
        else        => null,
    };
}

// ─── Expression parser (Pratt) ────────────────────────────────────────────────

fn parseExpr(p: *Parser, min_bp: u8) ParseError!Node {
    var lhs = try parsePrimary(p);

    while (true) {
        const tag = p.peekTag();
        const bp  = infixBP(tag) orelse break;
        if (bp.left <= min_bp) break;
        _ = p.advance();

        // `:` — field access; right operand is a bare ident.
        // a:b  →  App(App(ident(":"), string_lit(b)), a)
        if (tag == .Colon) {
            const field_name = try expectIdent(p);
            const inner = try p.alloc.create(Node.App);
            inner.* = .{ .func = Node{ .ident = ":" }, .arg = Node{ .string_lit = field_name } };
            const outer = try p.alloc.create(Node.App);
            outer.* = .{ .func = Node{ .app = inner }, .arg = lhs };
            lhs = Node{ .app = outer };
            continue;
        }

        // `|>` — pipe; `a |> f x y` → App(App(App(f,x),y), a).
        if (tag == .Pipe_Fwd) {
            var rhs = try parsePrimary(p);
            // Consume any argument primaries bound to the pipe's RHS function.
            while (true) {
                const next = p.peekTag();
                if (infixBP(next) != null) break;
                if (next == .Eof or next == .R_Paren or next == .R_Bracket or
                    next == .R_Brace) break;
                const arg = try parsePrimary(p);
                const app_node = try p.alloc.create(Node.App);
                app_node.* = .{ .func = rhs, .arg = arg };
                rhs = Node{ .app = app_node };
            }
            const app_node = try p.alloc.create(Node.App);
            app_node.* = .{ .func = rhs, .arg = lhs };
            lhs = Node{ .app = app_node };
            continue;
        }

        // `and` / `or` infix — collect consecutive same-op into flat list.
        if (tag == .KW_AND or tag == .KW_OR) {
            var operands: std.ArrayList(Node) = .empty;
            try operands.append(p.alloc, lhs);
            try operands.append(p.alloc, try parseExpr(p, bp.right));
            while (p.peekTag() == tag) {
                _ = p.advance();
                try operands.append(p.alloc, try parseExpr(p, bp.right));
            }
            const slice = try operands.toOwnedSlice(p.alloc);
            lhs = if (tag == .KW_AND)
                Node{ .and_expr = slice }
            else
                Node{ .or_expr = slice };
            continue;
        }

        // All other binary operators: data-last `a op b` → App(App(op, b), a).
        const rhs = try parseExpr(p, bp.right);
        const op_name = tagOpName(tag);
        const inner = try p.alloc.create(Node.App);
        inner.* = .{ .func = Node{ .ident = op_name }, .arg = rhs };
        const outer = try p.alloc.create(Node.App);
        outer.* = .{ .func = Node{ .app = inner }, .arg = lhs };
        lhs = Node{ .app = outer };
    }

    return lhs;
}

fn tagOpName(tag: Tag) []const u8 {
    return switch (tag) {
        .Plus       => "+",
        .Minus      => "-",
        .Multiply   => "*",
        .Divide     => "/",
        .KW_MOD     => "mod",
        .Concat     => "++",
        .Eq         => "=",
        .Not_Eq     => "!=",
        .L_Angle    => "<",
        .R_Angle    => ">",
        .Less_Eq    => "<=",
        .Greater_Eq => ">=",
        else        => unreachable,
    };
}

// ─── Primary parser ───────────────────────────────────────────────────────────

fn parsePrimary(p: *Parser) ParseError!Node {
    switch (p.peek()) {
        .Lit_Int    => |n| { _ = p.advance(); return Node{ .int_lit    = n }; },
        .Lit_Float  => |f| { _ = p.advance(); return Node{ .float_lit  = f }; },
        .Lit_Number => |s| { _ = p.advance(); return Node{ .number_lit = s }; },
        .Lit_String => |s| { _ = p.advance(); return Node{ .string_lit = s }; },
        .Lit_True   => { _ = p.advance(); return Node{ .bool_lit = true  }; },
        .Lit_False  => { _ = p.advance(); return Node{ .bool_lit = false }; },
        .Lit_Null   => { _ = p.advance(); return .null_lit; },

        .Ident      => |s| { _ = p.advance(); return Node{ .ident = s }; },

        // Unary `-expr` → App(ident("neg"), expr)
        .Minus => {
            _ = p.advance();
            const operand = try parsePrimary(p);
            const app = try p.alloc.create(Node.App);
            app.* = .{ .func = Node{ .ident = "neg" }, .arg = operand };
            return Node{ .app = app };
        },
        // Unary `not expr` → App(ident("not"), expr)
        .KW_NOT => {
            _ = p.advance();
            const operand = try parsePrimary(p);
            const app = try p.alloc.create(Node.App);
            app.* = .{ .func = Node{ .ident = "not" }, .arg = operand };
            return Node{ .app = app };
        },

        // Operator tokens as names in prefix position (SPEC Appendix A).
        // Allows partial application: (* 2), (+ 1), (> 5), etc.
        // Note: Minus is already handled above as unary negation.
        .Plus, .Multiply, .Divide, .KW_MOD,
        .Concat, .Eq, .Not_Eq, .L_Angle, .R_Angle,
        .Less_Eq, .Greater_Eq, .Colon => {
            const name = tagOpName(p.peekTag());
            _ = p.advance();
            return Node{ .ident = name };
        },

        .L_Bracket => return parseListLit(p),
        .L_Brace   => return parseRecordLit(p),
        .L_Paren   => return parseParenForm(p),

        .Eof  => return error.UnexpectedEof,
        else  => return error.UnexpectedToken,
    }
}

fn parseListLit(p: *Parser) ParseError!Node {
    _ = p.advance(); // [
    var items: std.ArrayList(Node) = .empty;
    while (!p.is(.R_Bracket)) {
        if (p.atEnd()) return error.UnexpectedEof;
        try items.append(p.alloc, try parseExpr(p, 0));
    }
    _ = p.advance(); // ]
    return Node{ .list_lit = try items.toOwnedSlice(p.alloc) };
}

fn parseRecordLit(p: *Parser) ParseError!Node {
    _ = p.advance(); // {
    var fields: std.ArrayList(Node.RecordField) = .empty;
    while (!p.is(.R_Brace)) {
        if (p.atEnd()) return error.UnexpectedEof;
        const key = try expectIdent(p);
        try p.eat(.Colon);
        const val = try parseExpr(p, 0);
        try fields.append(p.alloc, .{ .key = key, .val = val });
    }
    _ = p.advance(); // }
    return Node{ .record_lit = try fields.toOwnedSlice(p.alloc) };
}

fn parseParenForm(p: *Parser) ParseError!Node {
    _ = p.advance(); // (
    const node: Node = switch (p.peekTag()) {
        .KW_DEF => try parseDefForm(p),
        .KW_FN  => try parseFnForm(p),
        .KW_LET => try parseLetForm(p),
        .KW_If  => try parseIfForm(p),
        .KW_DO  => try parseDoForm(p),
        .KW_AND => try parseAndOrForm(p, false),
        .KW_OR  => try parseAndOrForm(p, true),
        else    => try parseAppForm(p),
    };
    try p.eat(.R_Paren);
    return node;
}

fn parseDefForm(p: *Parser) ParseError!Node {
    _ = p.advance(); // def
    const name = try expectIdent(p);
    const val  = try parseExpr(p, 0);
    const def  = try p.alloc.create(Node.Def);
    def.* = .{ .name = name, .val = val };
    return Node{ .def = def };
}

fn parseFnForm(p: *Parser) ParseError!Node {
    _ = p.advance(); // fn
    try p.eat(.L_Bracket);
    var params: std.ArrayList([]const u8) = .empty;
    while (!p.is(.R_Bracket)) {
        if (p.atEnd()) return error.UnexpectedEof;
        try params.append(p.alloc, try expectIdent(p));
    }
    _ = p.advance(); // ]
    if (params.items.len == 0) return error.EmptyFnParams;
    const body = try parseExpr(p, 0);

    // Desugar right-to-left: (fn [x y z] body) → fn[x](fn[y](fn[z] body))
    var result = body;
    var i = params.items.len;
    while (i > 0) {
        i -= 1;
        const fn_node = try p.alloc.create(Node.FnNode);
        fn_node.* = .{ .param = params.items[i], .body = result };
        result = Node{ .fn_lit = fn_node };
    }
    return result;
}

fn parseLetForm(p: *Parser) ParseError!Node {
    _ = p.advance(); // let
    const name = try expectIdent(p);
    const val  = try parseExpr(p, 0);
    const body = try parseExpr(p, 0);
    const n    = try p.alloc.create(Node.Let);
    n.* = .{ .name = name, .val = val, .body = body };
    return Node{ .let = n };
}

fn parseIfForm(p: *Parser) ParseError!Node {
    _ = p.advance(); // if
    const cond  = try parseExpr(p, 0);
    const then  = try parseExpr(p, 0);
    const else_ = try parseExpr(p, 0);
    const n     = try p.alloc.create(Node.If);
    n.* = .{ .cond = cond, .then = then, .else_ = else_ };
    return Node{ .if_expr = n };
}

fn parseDoForm(p: *Parser) ParseError!Node {
    _ = p.advance(); // do
    var stmts: std.ArrayList(Node.DoStmt) = .empty;
    while (!p.is(.R_Paren)) {
        if (p.atEnd()) return error.UnexpectedEof;
        if (isBindingAhead(p)) {
            const name = try expectIdent(p);
            _ = p.advance(); // <-
            const expr = try parseExpr(p, 0);
            try stmts.append(p.alloc, .{ .bind = .{ .name = name, .expr = expr } });
        } else {
            try stmts.append(p.alloc, .{ .expr = try parseExpr(p, 0) });
        }
    }
    return Node{ .do_block = try stmts.toOwnedSlice(p.alloc) };
}

fn isBindingAhead(p: *Parser) bool {
    if (p.pos + 1 >= p.tokens.len) return false;
    return std.meta.activeTag(p.tokens[p.pos])     == .Ident and
           std.meta.activeTag(p.tokens[p.pos + 1]) == .L_Arrow;
}

fn parseAndOrForm(p: *Parser, comptime is_or: bool) ParseError!Node {
    _ = p.advance(); // and / or
    var operands: std.ArrayList(Node) = .empty;
    while (!p.is(.R_Paren)) {
        if (p.atEnd()) return error.UnexpectedEof;
        try operands.append(p.alloc, try parseExpr(p, 0));
    }
    const slice = try operands.toOwnedSlice(p.alloc);
    return if (is_or) Node{ .or_expr = slice } else Node{ .and_expr = slice };
}

/// `(f a b c)` — fold left into nested App nodes.
fn parseAppForm(p: *Parser) ParseError!Node {
    var result = try parseExpr(p, 0);
    while (!p.is(.R_Paren)) {
        if (p.atEnd()) return error.UnexpectedEof;
        const arg = try parseExpr(p, 0);
        const app = try p.alloc.create(Node.App);
        app.* = .{ .func = result, .arg = arg };
        result = Node{ .app = app };
    }
    return result;
}

// ─── Helpers ──────────────────────────────────────────────────────────────────

fn expectIdent(p: *Parser) ParseError![]const u8 {
    switch (p.peek()) {
        .Ident => |s| { _ = p.advance(); return s; },
        else   => return error.ExpectedIdent,
    }
}

// ─── Tests ────────────────────────────────────────────────────────────────────

const testing = std.testing;

// Each test uses an ArenaAllocator so all node-tree allocations are freed
// together at the end of the test.  This mirrors real usage: the REPL resets
// its FixedBufferAllocator between evaluations, reclaiming the whole AST.

fn arena() std.heap.ArenaAllocator {
    return std.heap.ArenaAllocator.init(testing.allocator);
}

fn parseStr(alloc: std.mem.Allocator, src: []const u8) !Node {
    const tokens = try lexer.tokenize(alloc, src);
    // freeTokens is a no-op for slices allocated inside an arena, but harmless.
    defer lexer.freeTokens(alloc, tokens);
    return parse(alloc, tokens);
}

test "integer literal" {
    var a = arena(); defer a.deinit();
    const node = try parseStr(a.allocator(), "42");
    try testing.expectEqual(@as(i64, 42), node.int_lit);
}

test "float literal" {
    var a = arena(); defer a.deinit();
    const node = try parseStr(a.allocator(), "3.14");
    try testing.expectEqual(@as(f64, 3.14), node.float_lit);
}

test "bool and null literals" {
    var a = arena(); defer a.deinit();
    const alloc = a.allocator();
    try testing.expect((try parseStr(alloc, "true")).bool_lit  == true);
    try testing.expect((try parseStr(alloc, "false")).bool_lit == false);
    try testing.expectEqual(Node.null_lit, try parseStr(alloc, "null"));
}

test "string literal" {
    var a = arena(); defer a.deinit();
    const tokens = try lexer.tokenize(a.allocator(), "\"hello\"");
    const node = try parse(a.allocator(), tokens);
    try testing.expectEqualStrings("hello", node.string_lit);
}

test "identifier" {
    var a = arena(); defer a.deinit();
    const node = try parseStr(a.allocator(), "foo");
    try testing.expectEqualStrings("foo", node.ident);
}

test "empty list" {
    var a = arena(); defer a.deinit();
    const node = try parseStr(a.allocator(), "[]");
    try testing.expectEqual(@as(usize, 0), node.list_lit.len);
}

test "list with elements" {
    var a = arena(); defer a.deinit();
    const node = try parseStr(a.allocator(), "[1 2 3]");
    try testing.expectEqual(@as(usize, 3), node.list_lit.len);
    try testing.expectEqual(@as(i64, 1),   node.list_lit[0].int_lit);
    try testing.expectEqual(@as(i64, 3),   node.list_lit[2].int_lit);
}

test "empty record" {
    var a = arena(); defer a.deinit();
    const node = try parseStr(a.allocator(), "{}");
    try testing.expectEqual(@as(usize, 0), node.record_lit.len);
}

test "record with fields" {
    var a = arena(); defer a.deinit();
    const tokens = try lexer.tokenize(a.allocator(), "{name: \"alice\" age: 30}");
    const node = try parse(a.allocator(), tokens);
    try testing.expectEqual(@as(usize, 2), node.record_lit.len);
    try testing.expectEqualStrings("name",  node.record_lit[0].key);
    try testing.expectEqual(@as(i64, 30),   node.record_lit[1].val.int_lit);
}

test "application (f a)" {
    var a = arena(); defer a.deinit();
    const node = try parseStr(a.allocator(), "(foo 42)");
    try testing.expectEqualStrings("foo", node.app.func.ident);
    try testing.expectEqual(@as(i64, 42),  node.app.arg.int_lit);
}

test "curried application (f a b) → App(App(f,a),b)" {
    var a = arena(); defer a.deinit();
    const node = try parseStr(a.allocator(), "(foo 1 2)");
    try testing.expectEqual(@as(i64, 2),  node.app.arg.int_lit);
    try testing.expectEqualStrings("foo", node.app.func.app.func.ident);
    try testing.expectEqual(@as(i64, 1),  node.app.func.app.arg.int_lit);
}

test "def form" {
    var a = arena(); defer a.deinit();
    const node = try parseStr(a.allocator(), "(def x 42)");
    try testing.expectEqualStrings("x",   node.def.name);
    try testing.expectEqual(@as(i64, 42), node.def.val.int_lit);
}

test "fn single param" {
    var a = arena(); defer a.deinit();
    const node = try parseStr(a.allocator(), "(fn [x] x)");
    try testing.expectEqualStrings("x", node.fn_lit.param);
    try testing.expectEqualStrings("x", node.fn_lit.body.ident);
}

test "fn multi-param desugars to curried" {
    var a = arena(); defer a.deinit();
    const node = try parseStr(a.allocator(), "(fn [x y] x)");
    try testing.expectEqualStrings("x", node.fn_lit.param);
    try testing.expectEqualStrings("y", node.fn_lit.body.fn_lit.param);
    try testing.expectEqualStrings("x", node.fn_lit.body.fn_lit.body.ident);
}

test "let form" {
    var a = arena(); defer a.deinit();
    const node = try parseStr(a.allocator(), "(let x 1 x)");
    try testing.expectEqualStrings("x",  node.let.name);
    try testing.expectEqual(@as(i64, 1), node.let.val.int_lit);
    try testing.expectEqualStrings("x",  node.let.body.ident);
}

test "if form" {
    var a = arena(); defer a.deinit();
    const node = try parseStr(a.allocator(), "(if true 1 2)");
    try testing.expect(node.if_expr.cond.bool_lit == true);
    try testing.expectEqual(@as(i64, 1), node.if_expr.then.int_lit);
    try testing.expectEqual(@as(i64, 2), node.if_expr.else_.int_lit);
}

test "do block with binding" {
    var a = arena(); defer a.deinit();
    const node = try parseStr(a.allocator(), "(do x <- 1 x)");
    try testing.expectEqual(@as(usize, 2), node.do_block.len);
    try testing.expectEqualStrings("x",    node.do_block[0].bind.name);
    try testing.expectEqual(@as(i64, 1),   node.do_block[0].bind.expr.int_lit);
    try testing.expectEqualStrings("x",    node.do_block[1].expr.ident);
}

test "infix + desugars data-last: 1+2 → App(App(+,2),1)" {
    var a = arena(); defer a.deinit();
    const node = try parseStr(a.allocator(), "1 + 2");
    try testing.expectEqual(@as(i64, 1), node.app.arg.int_lit);
    try testing.expectEqualStrings("+",  node.app.func.app.func.ident);
    try testing.expectEqual(@as(i64, 2), node.app.func.app.arg.int_lit);
}

test "and/or prefix forms" {
    var a = arena(); defer a.deinit();
    const alloc = a.allocator();
    {
        const tokens = try lexer.tokenize(alloc, "(and true false)");
        const node = try parse(alloc, tokens);
        try testing.expectEqual(@as(usize, 2), node.and_expr.len);
    }
    {
        const tokens = try lexer.tokenize(alloc, "(or true false true)");
        const node = try parse(alloc, tokens);
        try testing.expectEqual(@as(usize, 3), node.or_expr.len);
    }
}

test "unary negation -42 → App(neg, 42)" {
    var a = arena(); defer a.deinit();
    const node = try parseStr(a.allocator(), "-42");
    try testing.expectEqualStrings("neg", node.app.func.ident);
    try testing.expectEqual(@as(i64, 42), node.app.arg.int_lit);
}

test "field access a:b → App(App(:, b_str), a)" {
    var a = arena(); defer a.deinit();
    const node = try parseStr(a.allocator(), "rec:field");
    try testing.expectEqualStrings("rec",   node.app.arg.ident);
    try testing.expectEqualStrings(":",     node.app.func.app.func.ident);
    try testing.expectEqualStrings("field", node.app.func.app.arg.string_lit);
}
