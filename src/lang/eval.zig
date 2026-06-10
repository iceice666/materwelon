// Tree-walk evaluator with TCO trampolining — see SPEC.md §11
const std   = @import("std");
const ast   = @import("ast.zig");
const value = @import("value.zig");
const env   = @import("env.zig");

const Node  = ast.Node;
const Value = value.Value;
const Frame = env.Frame;

pub const EvalError = error{
    UnboundName,
    TypeError,
    DivisionByZero,
    OutOfMemory,
};

// ─── Context ──────────────────────────────────────────────────────────────────

pub const Command = struct {
    name: []const u8,
    func: *const fn (alloc: std.mem.Allocator, args: []const Value) EvalError!Value,
};

pub const Ctx = struct {
    alloc:     std.mem.Allocator,
    commands:  []const Command,
    env_store: *env.EnvStore,
};

// ─── Trampoline ───────────────────────────────────────────────────────────────

const TailCall = struct {
    closure: *const Value.Closure,
    arg:     Value,
};

const Step = union(enum) {
    val:  Value,
    tail: TailCall,
};

// ─── Public entry ─────────────────────────────────────────────────────────────

pub fn eval(ctx: Ctx, node: Node, frame: *const Frame) EvalError!Value {
    var cur_node  = node;
    var cur_frame = frame;
    while (true) {
        switch (try step(ctx, cur_node, cur_frame)) {
            .val  => |v| return v,
            .tail => |t| {
                cur_frame = try t.closure.frame.extend(ctx.alloc, t.closure.param, t.arg);
                cur_node  = t.closure.body;
            },
        }
    }
}

// ─── Single step ──────────────────────────────────────────────────────────────

fn step(ctx: Ctx, node: Node, frame: *const Frame) EvalError!Step {
    switch (node) {
        .int_lit    => |n| return .{ .val = .{ .int      = n   } },
        .float_lit  => |f| return .{ .val = .{ .float    = f   } },
        .number_lit =>     return .{ .val = .number             },
        .string_lit => |s| return .{ .val = .{ .string   = s   } },
        .bool_lit   => |b| return .{ .val = .{ .bool_val = b   } },
        .null_lit   =>     return .{ .val = .null_val            },

        .list_lit => |items| {
            const out = try ctx.alloc.alloc(Value, items.len);
            for (items, 0..) |item, i| out[i] = try eval(ctx, item, frame);
            return .{ .val = .{ .list = out } };
        },

        .record_lit => |fields| {
            const out = try ctx.alloc.alloc(Value.Field, fields.len);
            for (fields, 0..) |f, i| {
                out[i] = .{ .key = f.key, .val = try eval(ctx, f.val, frame) };
            }
            return .{ .val = .{ .record = out } };
        },

        .ident => |name| {
            // Special: "env" refers to the mutable store, accessed via `:`.
            if (std.mem.eql(u8, name, "env")) return .{ .val = .{ .builtin = "env" } };
            if (frame.lookup(name)) |v| return .{ .val = v };
            // All stdlib/operator names live in the builtin table.
            if (isBuiltin(name)) return .{ .val = .{ .builtin = name } };
            // Command table lookup.
            for (ctx.commands) |cmd| {
                if (std.mem.eql(u8, cmd.name, name)) return .{ .val = .{ .builtin = name } };
            }
            return error.UnboundName;
        },

        .fn_lit => |f| {
            const c = try ctx.alloc.create(Value.Closure);
            c.* = .{ .param = f.param, .body = f.body, .frame = frame };
            return .{ .val = .{ .closure = c } };
        },

        .def => |d| {
            // Evaluates the value; the REPL is responsible for installing the
            // binding into the top-level frame.  Returns the value.
            const v = try eval(ctx, d.val, frame);
            _ = d.name;
            return .{ .val = v };
        },

        .let => |l| {
            const v         = try eval(ctx, l.val, frame);
            const new_frame = try frame.extend(ctx.alloc, l.name, v);
            return step(ctx, l.body, new_frame);   // tail
        },

        .if_expr => |x| {
            const cond   = try eval(ctx, x.cond, frame);
            const branch = if (cond.isTruthy()) x.then else x.else_;
            return step(ctx, branch, frame);        // tail
        },

        .do_block => |stmts| {
            if (stmts.len == 0) return .{ .val = .null_val };
            var cur = frame;
            for (stmts[0 .. stmts.len - 1]) |stmt| {
                switch (stmt) {
                    .bind => |b| {
                        const v = try eval(ctx, b.expr, cur);
                        cur = try cur.extend(ctx.alloc, b.name, v);
                    },
                    .expr => |e| _ = try eval(ctx, e, cur),
                }
            }
            const last = stmts[stmts.len - 1];
            return switch (last) {
                .bind => |b| blk: {
                    const v = try eval(ctx, b.expr, cur);
                    cur = try cur.extend(ctx.alloc, b.name, v);
                    break :blk .{ .val = .null_val };
                },
                .expr => |e| step(ctx, e, cur),     // tail
            };
        },

        .and_expr => |ops| {
            if (ops.len == 0) return .{ .val = .{ .bool_val = true } };
            for (ops[0 .. ops.len - 1]) |op| {
                const v = try eval(ctx, op, frame);
                if (!v.isTruthy()) return .{ .val = v };
            }
            return step(ctx, ops[ops.len - 1], frame); // tail
        },

        .or_expr => |ops| {
            if (ops.len == 0) return .{ .val = .{ .bool_val = false } };
            for (ops[0 .. ops.len - 1]) |op| {
                const v = try eval(ctx, op, frame);
                if (v.isTruthy()) return .{ .val = v };
            }
            return step(ctx, ops[ops.len - 1], frame); // tail
        },

        .app => |a| {
            const func_v = try eval(ctx, a.func, frame);
            const arg_v  = try eval(ctx, a.arg,  frame);
            return applyStep(ctx, func_v, arg_v);
        },
    }
}

// ─── Application ──────────────────────────────────────────────────────────────

fn applyStep(ctx: Ctx, func: Value, arg: Value) EvalError!Step {
    return switch (func) {
        .closure => |c| {
            if (arg.isErr()) return .{ .val = arg }; // pipe short-circuit
            return .{ .tail = .{ .closure = c, .arg = arg } };
        },
        .builtin => |name| .{ .val = try applyBuiltin(ctx, name, arg) },
        .partial => |p|    .{ .val = try applyPartial(ctx, p, arg)    },
        else => error.TypeError,
    };
}

// ─── Built-in first application → produces Partial ───────────────────────────

fn applyBuiltin(ctx: Ctx, name: []const u8, arg: Value) EvalError!Value {
    // `:` — first arg is field name (string_lit from desugaring `a:b`).
    // Returns a partial getter.
    if (std.mem.eql(u8, name, ":")) {
        if (std.meta.activeTag(arg) != .string) return error.TypeError;
        const p = try ctx.alloc.create(Value.Partial);
        p.* = .{ .op = ":", .arg = arg };
        return Value{ .partial = p };
    }

    // `neg` / `not` — unary, no partial
    if (std.mem.eql(u8, name, "neg")) return applyNeg(arg);
    if (std.mem.eql(u8, name, "not")) return Value{ .bool_val = !arg.isTruthy() };

    // Binary operators (data-last): first arg = modifier (right operand).
    // Return a partial waiting for the data (left operand).
    if (isBinaryOp(name)) {
        const p = try ctx.alloc.create(Value.Partial);
        p.* = .{ .op = name, .arg = arg };
        return Value{ .partial = p };
    }

    // `env` builtin — should only appear as the receiver of `:`, handled in applyPartial.
    if (std.mem.eql(u8, name, "env")) return error.TypeError;

    // Command dispatch (single-arg commands)
    for (ctx.commands) |cmd| {
        if (std.mem.eql(u8, cmd.name, name)) {
            return cmd.func(ctx.alloc, &[_]Value{arg});
        }
    }

    return error.UnboundName;
}

// ─── Partial second application → produces Value ──────────────────────────────

fn applyPartial(ctx: Ctx, p: *const Value.Partial, data: Value) EvalError!Value {
    // Pipe short-circuit: if data is an error result, propagate without executing.
    if (data.isErr()) return data;

    const op  = p.op;
    const mod = p.arg; // modifier = first arg (right operand in `data op mod`)

    // Field getter: `:.FIELD` applied to a record or the `env` builtin.
    if (std.mem.eql(u8, op, ":")) {
        const field = mod.string; // guaranteed by applyBuiltin `:` check
        switch (data) {
            .record  => |fields| {
                for (fields) |f| if (std.mem.eql(u8, f.key, field)) return f.val;
                return .null_val;
            },
            .builtin => |name| {
                if (std.mem.eql(u8, name, "env")) {
                    return ctx.env_store.get(field) orelse .null_val;
                }
                return error.TypeError;
            },
            else => return .null_val,
        }
    }

    // Arithmetic / comparison operators.
    return applyBinaryOp(ctx, op, data, mod);
}

// ─── Binary operator dispatch ─────────────────────────────────────────────────
// Convention: `data op mod` — data is left operand, mod is right operand.

fn applyBinaryOp(ctx: Ctx, op: []const u8, data: Value, mod: Value) EvalError!Value {
    // `++` — concat strings or lists
    if (std.mem.eql(u8, op, "++")) return applyConcat(ctx, data, mod);

    // Numeric ops require matching types (or int+float promotion)
    if (std.mem.eql(u8, op, "+"))  return applyAdd(data, mod);
    if (std.mem.eql(u8, op, "-"))  return applySub(data, mod);
    if (std.mem.eql(u8, op, "*"))  return applyMul(data, mod);
    if (std.mem.eql(u8, op, "/"))  return applyDiv(data, mod);
    if (std.mem.eql(u8, op, "mod")) return applyMod(data, mod);

    // Comparisons — return bool
    if (std.mem.eql(u8, op, "="))   return applyCmp(data, mod, .eq);
    if (std.mem.eql(u8, op, "!="))  return applyCmp(data, mod, .ne);
    if (std.mem.eql(u8, op, "<"))   return applyCmp(data, mod, .lt);
    if (std.mem.eql(u8, op, ">"))   return applyCmp(data, mod, .gt);
    if (std.mem.eql(u8, op, "<="))  return applyCmp(data, mod, .le);
    if (std.mem.eql(u8, op, ">="))  return applyCmp(data, mod, .ge);

    return error.TypeError;
}

const CmpOp = enum { eq, ne, lt, gt, le, ge };

fn applyCmp(data: Value, mod: Value, op: CmpOp) EvalError!Value {
    const result: bool = switch (data) {
        .int => |d| switch (mod) {
            .int   => |m| cmpInts(d, m, op),
            .float => |m| cmpFloats(@as(f64, @floatFromInt(d)), m, op),
            else   => return error.TypeError,
        },
        .float => |d| switch (mod) {
            .int   => |m| cmpFloats(d, @as(f64, @floatFromInt(m)), op),
            .float => |m| cmpFloats(d, m, op),
            else   => return error.TypeError,
        },
        .string => |d| switch (mod) {
            .string => |m| blk: {
                const c = std.mem.order(u8, d, m);
                break :blk switch (op) {
                    .eq => c == .eq,
                    .ne => c != .eq,
                    .lt => c == .lt,
                    .gt => c == .gt,
                    .le => c != .gt,
                    .ge => c != .lt,
                };
            },
            else => return error.TypeError,
        },
        .bool_val => |d| switch (mod) {
            .bool_val => |m| switch (op) {
                .eq => d == m,
                .ne => d != m,
                else => return error.TypeError,
            },
            else => return error.TypeError,
        },
        .null_val => switch (mod) {
            .null_val => op == .eq,
            else      => op == .ne,
        },
        else => return error.TypeError,
    };
    return Value{ .bool_val = result };
}

fn cmpInts(a: i64, b: i64, op: CmpOp) bool {
    return switch (op) {
        .eq => a == b, .ne => a != b,
        .lt => a < b,  .gt => a > b,
        .le => a <= b, .ge => a >= b,
    };
}

fn cmpFloats(a: f64, b: f64, op: CmpOp) bool {
    return switch (op) {
        .eq => a == b, .ne => a != b,
        .lt => a < b,  .gt => a > b,
        .le => a <= b, .ge => a >= b,
    };
}

fn applyAdd(a: Value, b: Value) EvalError!Value {
    return switch (a) {
        .int   => |x| switch (b) {
            .int   => |y| .{ .int   = x + y },
            .float => |y| .{ .float = @as(f64, @floatFromInt(x)) + y },
            else   => error.TypeError,
        },
        .float => |x| switch (b) {
            .int   => |y| .{ .float = x + @as(f64, @floatFromInt(y)) },
            .float => |y| .{ .float = x + y },
            else   => error.TypeError,
        },
        else => error.TypeError,
    };
}

fn applySub(a: Value, b: Value) EvalError!Value {
    return switch (a) {
        .int   => |x| switch (b) {
            .int   => |y| .{ .int   = x - y },
            .float => |y| .{ .float = @as(f64, @floatFromInt(x)) - y },
            else   => error.TypeError,
        },
        .float => |x| switch (b) {
            .int   => |y| .{ .float = x - @as(f64, @floatFromInt(y)) },
            .float => |y| .{ .float = x - y },
            else   => error.TypeError,
        },
        else => error.TypeError,
    };
}

fn applyMul(a: Value, b: Value) EvalError!Value {
    return switch (a) {
        .int   => |x| switch (b) {
            .int   => |y| .{ .int   = x * y },
            .float => |y| .{ .float = @as(f64, @floatFromInt(x)) * y },
            else   => error.TypeError,
        },
        .float => |x| switch (b) {
            .int   => |y| .{ .float = x * @as(f64, @floatFromInt(y)) },
            .float => |y| .{ .float = x * y },
            else   => error.TypeError,
        },
        else => error.TypeError,
    };
}

fn applyDiv(a: Value, b: Value) EvalError!Value {
    return switch (a) {
        .int   => |x| switch (b) {
            .int   => |y| blk: {
                if (y == 0) return error.DivisionByZero;
                break :blk .{ .int = @divTrunc(x, y) };
            },
            .float => |y| .{ .float = @as(f64, @floatFromInt(x)) / y },
            else   => error.TypeError,
        },
        .float => |x| switch (b) {
            .int   => |y| .{ .float = x / @as(f64, @floatFromInt(y)) },
            .float => |y| .{ .float = x / y },
            else   => error.TypeError,
        },
        else => error.TypeError,
    };
}

fn applyMod(a: Value, b: Value) EvalError!Value {
    return switch (a) {
        .int => |x| switch (b) {
            .int => |y| blk: {
                if (y == 0) return error.DivisionByZero;
                break :blk .{ .int = @mod(x, y) };
            },
            else => error.TypeError,
        },
        else => error.TypeError,
    };
}

fn applyNeg(arg: Value) EvalError!Value {
    return switch (arg) {
        .int   => |n| .{ .int   = -n },
        .float => |f| .{ .float = -f },
        else   => error.TypeError,
    };
}

fn applyConcat(ctx: Ctx, a: Value, b: Value) EvalError!Value {
    return switch (a) {
        .string => |s| switch (b) {
            .string => |t| blk: {
                const out = try ctx.alloc.alloc(u8, s.len + t.len);
                @memcpy(out[0..s.len], s);
                @memcpy(out[s.len..], t);
                break :blk Value{ .string = out };
            },
            else => error.TypeError,
        },
        .list => |xs| switch (b) {
            .list => |ys| blk: {
                const out = try ctx.alloc.alloc(Value, xs.len + ys.len);
                @memcpy(out[0..xs.len], xs);
                @memcpy(out[xs.len..], ys);
                break :blk Value{ .list = out };
            },
            else => error.TypeError,
        },
        else => error.TypeError,
    };
}

// ─── Builtin registry ─────────────────────────────────────────────────────────

fn isBinaryOp(name: []const u8) bool {
    const ops = [_][]const u8{
        "+", "-", "*", "/", "mod", "++",
        "=", "!=", "<", ">", "<=", ">=",
    };
    for (ops) |op| if (std.mem.eql(u8, name, op)) return true;
    return false;
}

fn isBuiltin(name: []const u8) bool {
    if (isBinaryOp(name)) return true;
    const others = [_][]const u8{ "neg", "not", ":" };
    for (others) |n| if (std.mem.eql(u8, name, n)) return true;
    return false;
}

// ─── Tests ────────────────────────────────────────────────────────────────────

const testing  = std.testing;
const lexer    = @import("lexer.zig");
const parser   = @import("parser.zig");

var dummy_store: env.EnvStore = .{};

const no_commands: []const Command = &[_]Command{};

fn makeCtx(alloc: std.mem.Allocator) Ctx {
    return .{ .alloc = alloc, .commands = no_commands, .env_store = &dummy_store };
}

fn evalStr(alloc: std.mem.Allocator, src: []const u8) !Value {
    // No freeTokens: alloc is expected to be an arena; all memory is
    // released together when the caller deinits the arena.
    const tokens = try lexer.tokenize(alloc, src);
    const node = try parser.parse(alloc, tokens);
    return eval(makeCtx(alloc), node, &env.empty_frame);
}

test "eval integer" {
    var a = std.heap.ArenaAllocator.init(testing.allocator); defer a.deinit();
    const v = try evalStr(a.allocator(), "42");
    try testing.expectEqual(@as(i64, 42), v.int);
}

test "eval float" {
    var a = std.heap.ArenaAllocator.init(testing.allocator); defer a.deinit();
    const v = try evalStr(a.allocator(), "3.14");
    try testing.expectEqual(@as(f64, 3.14), v.float);
}

test "eval bool and null" {
    var a = std.heap.ArenaAllocator.init(testing.allocator); defer a.deinit();
    try testing.expect((try evalStr(a.allocator(), "true")).bool_val  == true);
    try testing.expect((try evalStr(a.allocator(), "false")).bool_val == false);
    try testing.expectEqual(Value.null_val, try evalStr(a.allocator(), "null"));
}

test "eval string" {
    var a = std.heap.ArenaAllocator.init(testing.allocator); defer a.deinit();
    const v = try evalStr(a.allocator(), "\"hello\"");
    try testing.expectEqualStrings("hello", v.string);
}

test "eval list" {
    var a = std.heap.ArenaAllocator.init(testing.allocator); defer a.deinit();
    const v = try evalStr(a.allocator(), "[1 2 3]");
    try testing.expectEqual(@as(usize, 3), v.list.len);
    try testing.expectEqual(@as(i64, 2),   v.list[1].int);
}

test "eval record field access" {
    var a = std.heap.ArenaAllocator.init(testing.allocator); defer a.deinit();
    const v = try evalStr(a.allocator(), "{x: 42}:x");
    try testing.expectEqual(@as(i64, 42), v.int);
}

test "eval missing field returns null" {
    var a = std.heap.ArenaAllocator.init(testing.allocator); defer a.deinit();
    const v = try evalStr(a.allocator(), "{x: 1}:y");
    try testing.expectEqual(Value.null_val, v);
}

test "eval addition" {
    var a = std.heap.ArenaAllocator.init(testing.allocator); defer a.deinit();
    const v = try evalStr(a.allocator(), "1 + 2");
    try testing.expectEqual(@as(i64, 3), v.int);
}

test "eval subtraction" {
    var a = std.heap.ArenaAllocator.init(testing.allocator); defer a.deinit();
    const v = try evalStr(a.allocator(), "10 - 3");
    try testing.expectEqual(@as(i64, 7), v.int);
}

test "eval multiplication" {
    var a = std.heap.ArenaAllocator.init(testing.allocator); defer a.deinit();
    const v = try evalStr(a.allocator(), "3 * 4");
    try testing.expectEqual(@as(i64, 12), v.int);
}

test "eval division" {
    var a = std.heap.ArenaAllocator.init(testing.allocator); defer a.deinit();
    const v = try evalStr(a.allocator(), "10 / 2");
    try testing.expectEqual(@as(i64, 5), v.int);
}

test "eval mod" {
    var a = std.heap.ArenaAllocator.init(testing.allocator); defer a.deinit();
    const v = try evalStr(a.allocator(), "7 mod 3");
    try testing.expectEqual(@as(i64, 1), v.int);
}

test "eval negation" {
    var a = std.heap.ArenaAllocator.init(testing.allocator); defer a.deinit();
    const v = try evalStr(a.allocator(), "-5");
    try testing.expectEqual(@as(i64, -5), v.int);
}

test "eval comparison" {
    var a = std.heap.ArenaAllocator.init(testing.allocator); defer a.deinit();
    const alloc = a.allocator();
    try testing.expect((try evalStr(alloc, "3 > 2")).bool_val  == true);
    try testing.expect((try evalStr(alloc, "2 > 3")).bool_val  == false);
    try testing.expect((try evalStr(alloc, "2 = 2")).bool_val  == true);
    try testing.expect((try evalStr(alloc, "2 != 3")).bool_val == true);
}

test "eval string concat" {
    var a = std.heap.ArenaAllocator.init(testing.allocator); defer a.deinit();
    const v = try evalStr(a.allocator(), "\"foo\" ++ \"bar\"");
    try testing.expectEqualStrings("foobar", v.string);
}

test "eval list concat" {
    var a = std.heap.ArenaAllocator.init(testing.allocator); defer a.deinit();
    const v = try evalStr(a.allocator(), "[1 2] ++ [3 4]");
    try testing.expectEqual(@as(usize, 4), v.list.len);
    try testing.expectEqual(@as(i64, 3),   v.list[2].int);
}

test "eval let binding" {
    var a = std.heap.ArenaAllocator.init(testing.allocator); defer a.deinit();
    const v = try evalStr(a.allocator(), "(let x 5 (x * 2))");
    try testing.expectEqual(@as(i64, 10), v.int);
}

test "eval if true branch" {
    var a = std.heap.ArenaAllocator.init(testing.allocator); defer a.deinit();
    const v = try evalStr(a.allocator(), "(if true 1 2)");
    try testing.expectEqual(@as(i64, 1), v.int);
}

test "eval if false branch" {
    var a = std.heap.ArenaAllocator.init(testing.allocator); defer a.deinit();
    const v = try evalStr(a.allocator(), "(if false 1 2)");
    try testing.expectEqual(@as(i64, 2), v.int);
}

test "eval lambda and apply" {
    var a = std.heap.ArenaAllocator.init(testing.allocator); defer a.deinit();
    const v = try evalStr(a.allocator(), "((fn [x] (x + 1)) 4)");
    try testing.expectEqual(@as(i64, 5), v.int);
}

test "eval closure captures lexical scope" {
    var a = std.heap.ArenaAllocator.init(testing.allocator); defer a.deinit();
    // (let n 10 ((fn [x] (x + n)) 5))  → 15
    const v = try evalStr(a.allocator(), "(let n 10 ((fn [x] (x + n)) 5))");
    try testing.expectEqual(@as(i64, 15), v.int);
}

test "eval do block" {
    var a = std.heap.ArenaAllocator.init(testing.allocator); defer a.deinit();
    const v = try evalStr(a.allocator(), "(do x <- 3 (x + 4))");
    try testing.expectEqual(@as(i64, 7), v.int);
}

test "eval and short-circuits on false" {
    var a = std.heap.ArenaAllocator.init(testing.allocator); defer a.deinit();
    const alloc = a.allocator();
    try testing.expect((try evalStr(alloc, "(and true true)")).bool_val  == true);
    try testing.expect((try evalStr(alloc, "(and true false)")).bool_val == false);
    try testing.expect((try evalStr(alloc, "(and false true)")).bool_val == false);
}

test "eval or short-circuits on true" {
    var a = std.heap.ArenaAllocator.init(testing.allocator); defer a.deinit();
    const alloc = a.allocator();
    try testing.expect((try evalStr(alloc, "(or false false)")).bool_val == false);
    try testing.expect((try evalStr(alloc, "(or true false)")).bool_val  == true);
}

test "eval pipe |>" {
    var a = std.heap.ArenaAllocator.init(testing.allocator); defer a.deinit();
    // 3 |> (* 2)  →  ((*) 2 3)  →  6
    const v = try evalStr(a.allocator(), "3 |> (* 2)");
    try testing.expectEqual(@as(i64, 6), v.int);
}

test "eval tail-call recursion (TCO)" {
    var a = std.heap.ArenaAllocator.init(testing.allocator); defer a.deinit();
    // Self-passing style (since `let` is not `letrec`).
    // f = fn self -> fn n -> fn acc -> if n=0 then acc else self self (n-1) (acc+n)
    // Call: ((f f 1000) 0)  — should not stack overflow with TCO.
    const src =
        \\(let f
        \\  (fn [self]
        \\    (fn [n]
        \\      (fn [acc]
        \\        (if (n = 0)
        \\          acc
        \\          (((self self) (n - 1)) (acc + n))))))
        \\  (((f f) 1000) 0))
    ;
    const v = try evalStr(a.allocator(), src);
    try testing.expectEqual(@as(i64, 500500), v.int);
}

test "eval error result propagates through pipe" {
    var a = std.heap.ArenaAllocator.init(testing.allocator); defer a.deinit();
    const alloc = a.allocator();
    // {err: "oops"} |> (* 2) — the closure receives an error record, short-circuits
    const v = try evalStr(alloc, "{err: \"oops\"} |> (* 2)");
    try testing.expect(v.isErr());
}
