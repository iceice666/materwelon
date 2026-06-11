// Tree-walk evaluator with TCO trampolining — see SPEC.md §11
const std   = @import("std");
const ast   = @import("ast.zig");
const value = @import("value.zig");
const env   = @import("env.zig");

const stdlib = @import("stdlib.zig");
const ops    = @import("ops.zig");

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

        .and_expr => |operands| {
            if (operands.len == 0) return .{ .val = .{ .bool_val = true } };
            for (operands[0 .. operands.len - 1]) |op| {
                const v = try eval(ctx, op, frame);
                if (!v.isTruthy()) return .{ .val = v };
            }
            return step(ctx, operands[operands.len - 1], frame); // tail
        },

        .or_expr => |operands| {
            if (operands.len == 0) return .{ .val = .{ .bool_val = false } };
            for (operands[0 .. operands.len - 1]) |op| {
                const v = try eval(ctx, op, frame);
                if (v.isTruthy()) return .{ .val = v };
            }
            return step(ctx, operands[operands.len - 1], frame); // tail
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

// ─── String formatting (f! / format) ─────────────────────────────────────────

fn countPlaceholders(fmt: []const u8) usize {
    var n: usize = 0;
    var i: usize = 0;
    while (i + 1 < fmt.len) : (i += 1) {
        if (fmt[i] == '{' and fmt[i + 1] == '}') { n += 1; i += 1; }
    }
    return n;
}

fn formatBuiltin(alloc: std.mem.Allocator, fmt: []const u8, values: []const Value) EvalError!Value {
    var buf: std.ArrayList(u8) = .empty;
    var vi: usize = 0;
    var i: usize = 0;
    while (i < fmt.len) {
        if (i + 1 < fmt.len and fmt[i] == '{' and fmt[i + 1] == '}') {
            if (vi >= values.len) return error.TypeError;
            const sv = try stdlib.toStr(alloc, values[vi]);
            try buf.appendSlice(alloc, sv.string);
            vi += 1;
            i += 2;
        } else {
            try buf.append(alloc, fmt[i]);
            i += 1;
        }
    }
    return Value{ .string = try buf.toOwnedSlice(alloc) };
}

fn applyFmtFirst(ctx: Ctx, arg: Value) EvalError!Value {
    const fmt_str = switch (arg) { .string => |s| s, else => return error.TypeError };
    if (countPlaceholders(fmt_str) == 0) return arg; // no placeholders: identity
    const args = try ctx.alloc.alloc(Value, 1);
    args[0] = arg;
    const p = try ctx.alloc.create(Value.Partial);
    p.* = .{ .op = "f!/call", .args = args };
    return Value{ .partial = p };
}

fn applyFmtPartial(ctx: Ctx, p: *const Value.Partial, data: Value) EvalError!Value {
    const fmt_str = switch (p.args[0]) { .string => |s| s, else => return error.TypeError };
    const n_needed = countPlaceholders(fmt_str);
    const new_args = try ctx.alloc.alloc(Value, p.args.len + 1);
    @memcpy(new_args[0..p.args.len], p.args);
    new_args[p.args.len] = data;
    // new_args[0] = fmt_str, new_args[1..] = value args collected so far
    if (new_args.len - 1 < n_needed) {
        const new_p = try ctx.alloc.create(Value.Partial);
        new_p.* = .{ .op = "f!/call", .args = new_args };
        return Value{ .partial = new_p };
    }
    return formatBuiltin(ctx.alloc, fmt_str, new_args[1..]);
}

// ─── Built-in first application ───────────────────────────────────────────────

fn applyBuiltin(ctx: Ctx, name: []const u8, arg: Value) EvalError!Value {
    // `env` only valid as receiver of `:`
    if (std.mem.eql(u8, name, "env")) return error.TypeError;

    // f! / format: dynamic arity from placeholder count — intercept before arity table
    if (std.mem.eql(u8, name, "f!") or std.mem.eql(u8, name, "format"))
        return applyFmtFirst(ctx, arg);

    // Commands are single-arg; checked before arity table
    for (ctx.commands) |cmd| {
        if (std.mem.eql(u8, cmd.name, name)) {
            return cmd.func(ctx.alloc, &[_]Value{arg});
        }
    }

    const arity = stdlib.arityOf(name) orelse return error.UnboundName;
    if (arity == 1) {
        return executeBuiltin(ctx, name, &[_]Value{arg});
    } else {
        const args = try ctx.alloc.alloc(Value, 1);
        args[0] = arg;
        const p = try ctx.alloc.create(Value.Partial);
        p.* = .{ .op = name, .args = args };
        return Value{ .partial = p };
    }
}

// ─── Partial application: accumulate args or execute ─────────────────────────

fn applyPartial(ctx: Ctx, p: *const Value.Partial, data: Value) EvalError!Value {
    // Propagate errors — but let error-handling HOFs still see the error value.
    if (data.isErr() and !std.mem.eql(u8, p.op, "on-err")) return data;

    // f!/call: dynamic arity — intercept before arity table
    if (std.mem.eql(u8, p.op, "f!/call")) return applyFmtPartial(ctx, p, data);

    const arity = stdlib.arityOf(p.op) orelse return error.TypeError;
    const total = p.args.len + 1;

    const new_args = try ctx.alloc.alloc(Value, total);
    @memcpy(new_args[0..p.args.len], p.args);
    new_args[p.args.len] = data;

    if (total < arity) {
        const new_p = try ctx.alloc.create(Value.Partial);
        new_p.* = .{ .op = p.op, .args = new_args };
        return Value{ .partial = new_p };
    }
    return executeBuiltin(ctx, p.op, new_args);
}

// ─── Execute a fully-applied builtin ─────────────────────────────────────────

fn executeBuiltin(ctx: Ctx, name: []const u8, args: []const Value) EvalError!Value {
    // Field access — args[0]=field (string), args[1]=target
    if (std.mem.eql(u8, name, ":")) {
        const field = switch (args[0]) { .string => |s| s, else => return error.TypeError };
        return switch (args[1]) {
            .record  => |fields| blk: {
                for (fields) |f| if (std.mem.eql(u8, f.key, field)) break :blk f.val;
                break :blk Value.null_val;
            },
            .builtin => |bname| blk: {
                if (std.mem.eql(u8, bname, "env")) break :blk ctx.env_store.get(field) orelse .null_val;
                break :blk error.TypeError;
            },
            else => Value.null_val,
        };
    }

    // Unary primitives (not delegated to stdlib.applyPure)
    if (std.mem.eql(u8, name, "neg")) return ops.applyNeg(args[0]);
    if (std.mem.eql(u8, name, "not")) return Value{ .bool_val = !args[0].isTruthy() };

    // Binary arithmetic/comparison — args[0]=modifier(right), args[1]=data(left)
    if (ops.isBinaryOp(name)) return ops.applyBinaryOp(ctx.alloc, name, args[1], args[0]);

    // HOFs — need eval context to call closures
    if (std.mem.eql(u8, name, "map"))          return hofMap(ctx, args);
    if (std.mem.eql(u8, name, "filter"))       return hofFilter(ctx, args);
    if (std.mem.eql(u8, name, "fold"))         return hofFold(ctx, args);
    if (std.mem.eql(u8, name, "on-err"))       return hofOnErr(ctx, args);
    if (std.mem.eql(u8, name, "map-ok"))       return hofMapOk(ctx, args);
    if (std.mem.eql(u8, name, "and-then"))     return hofAndThen(ctx, args);
    if (std.mem.eql(u8, name, "compose"))      return hofCompose(ctx, args);
    if (std.mem.eql(u8, name, "pipe"))         return hofPipe(ctx, args);
    if (std.mem.eql(u8, name, "compose/call")) return hofComposecall(ctx, args);
    if (std.mem.eql(u8, name, "pipe/call"))    return hofPipecall(ctx, args);
    if (std.mem.eql(u8, name, "flip"))         return hofFlip(ctx, args);

    return stdlib.applyPure(ctx.alloc, name, args);
}

// ─── Value-level function application (used by HOFs) ─────────────────────────

fn applyVal(ctx: Ctx, func: Value, arg: Value) EvalError!Value {
    return switch (func) {
        .closure => |c| blk: {
            if (arg.isErr()) break :blk arg;
            const frame = try c.frame.extend(ctx.alloc, c.param, arg);
            break :blk eval(ctx, c.body, frame);
        },
        .builtin => |n| applyBuiltin(ctx, n, arg),
        .partial => |p| applyPartial(ctx, p, arg),
        else => error.TypeError,
    };
}

// ─── Higher-order function implementations ────────────────────────────────────

fn hofMap(ctx: Ctx, args: []const Value) EvalError!Value {
    const func = args[0];
    const xs   = switch (args[1]) { .list => |s| s, else => return error.TypeError };
    const out  = try ctx.alloc.alloc(Value, xs.len);
    for (xs, 0..) |x, i| out[i] = try applyVal(ctx, func, x);
    return Value{ .list = out };
}

fn hofFilter(ctx: Ctx, args: []const Value) EvalError!Value {
    const pred = args[0];
    const xs   = switch (args[1]) { .list => |s| s, else => return error.TypeError };
    var out: std.ArrayList(Value) = .empty;
    for (xs) |x| {
        if ((try applyVal(ctx, pred, x)).isTruthy()) try out.append(ctx.alloc, x);
    }
    return Value{ .list = try out.toOwnedSlice(ctx.alloc) };
}

// fold step init xs — step is called as (step elem) acc (elem=modifier, acc=data)
fn hofFold(ctx: Ctx, args: []const Value) EvalError!Value {
    const func = args[0];
    var acc    = args[1];
    const xs   = switch (args[2]) { .list => |s| s, else => return error.TypeError };
    for (xs) |x| {
        const fx = try applyVal(ctx, func, x);
        acc = try applyVal(ctx, fx, acc);
    }
    return acc;
}

// on-err handler result — calls handler with err value if result is an error
fn hofOnErr(ctx: Ctx, args: []const Value) EvalError!Value {
    const handler = args[0];
    const result  = args[1];
    if (!result.isErr()) return result;
    const err_msg = switch (result) {
        .record => |fields| blk: {
            for (fields) |f| if (std.mem.eql(u8, f.key, "err")) break :blk f.val;
            break :blk Value.null_val;
        },
        else => Value.null_val,
    };
    return applyVal(ctx, handler, err_msg);
}

// map-ok f result — applies f to the :ok value; passes errors through
fn hofMapOk(ctx: Ctx, args: []const Value) EvalError!Value {
    const func   = args[0];
    const result = args[1];
    if (result.isErr()) return result;
    const v = switch (result) {
        .record => |fields| blk: {
            for (fields) |f| if (std.mem.eql(u8, f.key, "ok")) break :blk f.val;
            break :blk result;
        },
        else => result,
    };
    const mapped = try applyVal(ctx, func, v);
    return stdlib.makeOk(ctx.alloc, mapped);
}

// and-then f result — applies f to :ok value; f must return a result record
fn hofAndThen(ctx: Ctx, args: []const Value) EvalError!Value {
    const func   = args[0];
    const result = args[1];
    if (result.isErr()) return result;
    const v = switch (result) {
        .record => |fields| blk: {
            for (fields) |f| if (std.mem.eql(u8, f.key, "ok")) break :blk f.val;
            break :blk result;
        },
        else => result,
    };
    return applyVal(ctx, func, v);
}

// compose f g → Partial{compose/call,[f,g]}  →  (compose f g) x = f (g x)
fn hofCompose(ctx: Ctx, args: []const Value) EvalError!Value {
    const captured = try ctx.alloc.alloc(Value, 2);
    captured[0] = args[0]; // f
    captured[1] = args[1]; // g
    const p = try ctx.alloc.create(Value.Partial);
    p.* = .{ .op = "compose/call", .args = captured };
    return Value{ .partial = p };
}

// pipe f g → Partial{pipe/call,[f,g]}  →  (pipe f g) x = g (f x)
fn hofPipe(ctx: Ctx, args: []const Value) EvalError!Value {
    const captured = try ctx.alloc.alloc(Value, 2);
    captured[0] = args[0]; // f
    captured[1] = args[1]; // g
    const p = try ctx.alloc.create(Value.Partial);
    p.* = .{ .op = "pipe/call", .args = captured };
    return Value{ .partial = p };
}

// args=[f, g, x]; execute f(g(x))
fn hofComposecall(ctx: Ctx, args: []const Value) EvalError!Value {
    const gx = try applyVal(ctx, args[1], args[2]);
    return applyVal(ctx, args[0], gx);
}

// args=[f, g, x]; execute g(f(x))
fn hofPipecall(ctx: Ctx, args: []const Value) EvalError!Value {
    const fx = try applyVal(ctx, args[0], args[2]);
    return applyVal(ctx, args[1], fx);
}

// flip f a b = f b a — swap the two args passed to f
// args=[f, a, b]; execute (f b) a
fn hofFlip(ctx: Ctx, args: []const Value) EvalError!Value {
    const fb = try applyVal(ctx, args[0], args[2]);
    return applyVal(ctx, fb, args[1]);
}

// ─── Builtin registry ─────────────────────────────────────────────────────────

fn isBuiltin(name: []const u8) bool {
    return stdlib.isStdlib(name);
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

test "eval stdlib unary: count, first, rest" {
    var a = std.heap.ArenaAllocator.init(testing.allocator); defer a.deinit();
    const al = a.allocator();
    try testing.expectEqual(@as(i64, 3),   (try evalStr(al, "[1 2 3] |> count")).int);
    try testing.expectEqual(@as(i64, 1),   (try evalStr(al, "[1 2 3] |> first")).int);
    try testing.expectEqual(@as(usize, 2), (try evalStr(al, "[1 2 3] |> rest")).list.len);
}

test "eval stdlib binary: nth, append" {
    var a = std.heap.ArenaAllocator.init(testing.allocator); defer a.deinit();
    const al = a.allocator();
    try testing.expectEqual(@as(i64, 20),  (try evalStr(al, "[10 20 30] |> nth 1")).int);
    try testing.expectEqual(@as(usize, 3), (try evalStr(al, "[1 2] |> append 3")).list.len);
}

test "eval map HOF" {
    var a = std.heap.ArenaAllocator.init(testing.allocator); defer a.deinit();
    // map (* 2) [1 2 3] = [2 4 6]
    const v = try evalStr(a.allocator(), "[1 2 3] |> map (* 2)");
    try testing.expectEqual(@as(usize, 3), v.list.len);
    try testing.expectEqual(@as(i64, 4),   v.list[1].int);
}

test "eval filter HOF" {
    var a = std.heap.ArenaAllocator.init(testing.allocator); defer a.deinit();
    // filter (> 2) [1 2 3 4] — keeps elements where elem > 2
    const v = try evalStr(a.allocator(), "[1 2 3 4] |> filter (> 2)");
    try testing.expectEqual(@as(usize, 2), v.list.len);
    try testing.expectEqual(@as(i64, 3),   v.list[0].int);
}

test "eval fold HOF" {
    var a = std.heap.ArenaAllocator.init(testing.allocator); defer a.deinit();
    // Use (+) in parens so the pipe loop captures it (bare + would be seen as infix)
    const v = try evalStr(a.allocator(), "[1 2 3 4 5] |> fold (+) 0");
    try testing.expectEqual(@as(i64, 15), v.int);
}

test "eval on-err HOF" {
    var a = std.heap.ArenaAllocator.init(testing.allocator); defer a.deinit();
    const al = a.allocator();
    // ok value passes through unchanged
    const ok_result = try evalStr(al, "{ok: 42} |> on-err (fn [_] 0)");
    try testing.expect(ok_result.isErr() == false);
    // error value calls handler; handler returns 99
    const handled = try evalStr(al, "{err: \"oops\"} |> on-err (fn [_] 99)");
    try testing.expectEqual(@as(i64, 99), handled.int);
}

test "eval compose HOF" {
    var a = std.heap.ArenaAllocator.init(testing.allocator); defer a.deinit();
    // (compose (* 2) (+ 1)) 3  = (* 2) ((+ 1) 3) = (* 2) 4 = 8
    const v = try evalStr(a.allocator(), "((compose (* 2) (+ 1)) 3)");
    try testing.expectEqual(@as(i64, 8), v.int);
}

test "eval to-str stdlib" {
    var a = std.heap.ArenaAllocator.init(testing.allocator); defer a.deinit();
    const v = try evalStr(a.allocator(), "42 |> to-str");
    try testing.expectEqualStrings("42", v.string);
}

test "eval f! no placeholders" {
    var a = std.heap.ArenaAllocator.init(testing.allocator); defer a.deinit();
    const v = try evalStr(a.allocator(), "(f! \"hello\")");
    try testing.expectEqualStrings("hello", v.string);
}

test "eval f! one placeholder int" {
    var a = std.heap.ArenaAllocator.init(testing.allocator); defer a.deinit();
    const v = try evalStr(a.allocator(), "(f! \"x={}\" 42)");
    try testing.expectEqualStrings("x=42", v.string);
}

test "eval f! multiple placeholders" {
    var a = std.heap.ArenaAllocator.init(testing.allocator); defer a.deinit();
    const v = try evalStr(a.allocator(), "(f! \"{} + {} = {}\" 1 2 3)");
    try testing.expectEqualStrings("1 + 2 = 3", v.string);
}

test "eval f! with string arg" {
    var a = std.heap.ArenaAllocator.init(testing.allocator); defer a.deinit();
    const v = try evalStr(a.allocator(), "(f! \"hello, {}!\" \"world\")");
    try testing.expectEqualStrings("hello, world!", v.string);
}

test "eval format alias" {
    var a = std.heap.ArenaAllocator.init(testing.allocator); defer a.deinit();
    const v = try evalStr(a.allocator(), "(format \"val={}\" 99)");
    try testing.expectEqualStrings("val=99", v.string);
}

test "eval f! via pipe" {
    var a = std.heap.ArenaAllocator.init(testing.allocator); defer a.deinit();
    // 42 |> f! "n={}"  →  (f! "n={}") 42  →  "n=42"
    const v = try evalStr(a.allocator(), "42 |> f! \"n={}\"");
    try testing.expectEqualStrings("n=42", v.string);
}

test "eval f! error propagates through" {
    var a = std.heap.ArenaAllocator.init(testing.allocator); defer a.deinit();
    const v = try evalStr(a.allocator(), "{err: \"oops\"} |> f! \"val={}\"");
    try testing.expect(v.isErr());
}

test "eval do block multiple stmts and bindings" {
    var a = std.heap.ArenaAllocator.init(testing.allocator); defer a.deinit();
    const al = a.allocator();
    // plain expr discarded, two bindings, final expr
    const v = try evalStr(al, "(do 1 x <- 2 y <- (x + 3) (x * y))");
    try testing.expectEqual(@as(i64, 10), v.int);
}

test "eval and/or variadic 3-arg" {
    var a = std.heap.ArenaAllocator.init(testing.allocator); defer a.deinit();
    const al = a.allocator();
    try testing.expect((try evalStr(al, "(and true true true)")).bool_val  == true);
    try testing.expect((try evalStr(al, "(and true false true)")).bool_val == false);
    try testing.expect((try evalStr(al, "(or false false true)")).bool_val == true);
    try testing.expect((try evalStr(al, "(or false false false)")).bool_val == false);
}

test "eval and/or infix form" {
    var a = std.heap.ArenaAllocator.init(testing.allocator); defer a.deinit();
    const al = a.allocator();
    try testing.expect((try evalStr(al, "true and false")).bool_val == false);
    try testing.expect((try evalStr(al, "false or true")).bool_val  == true);
}

test "eval float arithmetic" {
    var a = std.heap.ArenaAllocator.init(testing.allocator); defer a.deinit();
    const al = a.allocator();
    try testing.expectApproxEqAbs(@as(f64, 2.0), (try evalStr(al, "1.5 + 0.5")).float, 1e-9);
    try testing.expectApproxEqAbs(@as(f64, 1.0), (try evalStr(al, "3.0 - 2.0")).float, 1e-9);
    try testing.expectApproxEqAbs(@as(f64, 6.0), (try evalStr(al, "2.0 * 3.0")).float, 1e-9);
    try testing.expectApproxEqAbs(@as(f64, 1.5), (try evalStr(al, "3.0 / 2.0")).float, 1e-9);
    // int + float promotes to float
    try testing.expectApproxEqAbs(@as(f64, 2.5), (try evalStr(al, "1 + 1.5")).float, 1e-9);
}

test "eval unary not" {
    var a = std.heap.ArenaAllocator.init(testing.allocator); defer a.deinit();
    const al = a.allocator();
    try testing.expect((try evalStr(al, "not true")).bool_val  == false);
    try testing.expect((try evalStr(al, "not false")).bool_val == true);
    try testing.expect((try evalStr(al, "not null")).bool_val  == true);
}

test "eval comparison ops !=, <=, >=" {
    var a = std.heap.ArenaAllocator.init(testing.allocator); defer a.deinit();
    const al = a.allocator();
    try testing.expect((try evalStr(al, "1 != 2")).bool_val  == true);
    try testing.expect((try evalStr(al, "2 != 2")).bool_val  == false);
    try testing.expect((try evalStr(al, "2 <= 2")).bool_val  == true);
    try testing.expect((try evalStr(al, "1 <= 2")).bool_val  == true);
    try testing.expect((try evalStr(al, "3 <= 2")).bool_val  == false);
    try testing.expect((try evalStr(al, "3 >= 2")).bool_val  == true);
    try testing.expect((try evalStr(al, "2 >= 2")).bool_val  == true);
    try testing.expect((try evalStr(al, "1 >= 2")).bool_val  == false);
}

test "eval map-ok HOF" {
    var a = std.heap.ArenaAllocator.init(testing.allocator); defer a.deinit();
    const al = a.allocator();
    // success: transforms inner value
    const ok_v = try evalStr(al, "{ok: 5} |> map-ok (* 2)");
    try testing.expectEqual(@as(i64, 10), ok_v.record[0].val.int);
    // error: passes through unchanged
    const err_v = try evalStr(al, "{err: \"boom\"} |> map-ok (* 2)");
    try testing.expect(err_v.isErr());
}

test "eval and-then HOF" {
    var a = std.heap.ArenaAllocator.init(testing.allocator); defer a.deinit();
    const al = a.allocator();
    // success: chains into the next result-returning fn
    const ok_v = try evalStr(al, "{ok: 4} |> and-then (fn [x] {ok: (x * 3)})");
    try testing.expectEqual(@as(i64, 12), ok_v.record[0].val.int);
    // error: short-circuits
    const err_v = try evalStr(al, "{err: \"e\"} |> and-then (fn [x] {ok: x})");
    try testing.expect(err_v.isErr());
}

test "eval flip HOF" {
    var a = std.heap.ArenaAllocator.init(testing.allocator); defer a.deinit();
    // (flip f 3 10) = f(10)(3); f = fn[x][y] x-y → 10-3 = 7
    const v = try evalStr(a.allocator(), "((flip (fn [x] (fn [y] x - y)) 3) 10)");
    try testing.expectEqual(@as(i64, 7), v.int);
}

test "eval pipe HOF" {
    var a = std.heap.ArenaAllocator.init(testing.allocator); defer a.deinit();
    // (pipe (+ 1) (* 2)) 3  = (* 2) ((+ 1) 3) = 8
    const v = try evalStr(a.allocator(), "((pipe (+ 1) (* 2)) 3)");
    try testing.expectEqual(@as(i64, 8), v.int);
}

test "eval identity and const" {
    var a = std.heap.ArenaAllocator.init(testing.allocator); defer a.deinit();
    const al = a.allocator();
    try testing.expectEqual(@as(i64, 42), (try evalStr(al, "(identity 42)")).int);
    try testing.expectEqual(@as(i64, 7),  (try evalStr(al, "((const 7) 99)")).int);
}

test "eval list reverse, flatten, zip, concat fn" {
    var a = std.heap.ArenaAllocator.init(testing.allocator); defer a.deinit();
    const al = a.allocator();
    const rev = try evalStr(al, "[1 2 3] |> reverse");
    try testing.expectEqual(@as(i64, 3), rev.list[0].int);
    const flat = try evalStr(al, "[[1 2] [3 4]] |> flatten");
    try testing.expectEqual(@as(usize, 4), flat.list.len);
    const zipped = try evalStr(al, "(zip [1 2] [3 4])");
    try testing.expectEqual(@as(usize, 2), zipped.list.len);
    const cat = try evalStr(al, "(concat [1 2] [3 4])");
    try testing.expectEqual(@as(usize, 4), cat.list.len);
}

test "eval record ops: keys, values, get, set, del, has, merge" {
    var a = std.heap.ArenaAllocator.init(testing.allocator); defer a.deinit();
    const al = a.allocator();
    try testing.expectEqual(@as(usize, 2), (try evalStr(al, "(keys {a: 1 b: 2})")).list.len);
    try testing.expectEqual(@as(usize, 2), (try evalStr(al, "(values {a: 1 b: 2})")).list.len);
    try testing.expectEqual(@as(i64, 1),   (try evalStr(al, "(get \"a\" {a: 1 b: 2})")).int);
    try testing.expect((try evalStr(al, "(get \"z\" {a: 1})")) == .null_val);
    try testing.expect((try evalStr(al, "(has \"a\" {a: 1})")).bool_val == true);
    try testing.expect((try evalStr(al, "(has \"z\" {a: 1})")).bool_val == false);
    const deleted = try evalStr(al, "(del \"a\" {a: 1 b: 2})");
    try testing.expectEqual(@as(usize, 1), deleted.record.len);
    const updated = try evalStr(al, "(set \"a\" 99 {a: 1 b: 2})");
    try testing.expectEqual(@as(i64, 99), updated.record[0].val.int);
    const merged = try evalStr(al, "(merge {a: 1} {b: 2})");
    try testing.expectEqual(@as(usize, 2), merged.record.len);
}

test "eval string ops: str-join, str-split, str-concat" {
    var a = std.heap.ArenaAllocator.init(testing.allocator); defer a.deinit();
    const al = a.allocator();
    const joined = try evalStr(al, "(str-join \",\" [\"a\" \"b\" \"c\"])");
    try testing.expectEqualStrings("a,b,c", joined.string);
    const split = try evalStr(al, "(str-split \",\" \"a,b,c\")");
    try testing.expectEqual(@as(usize, 3), split.list.len);
    // data-last: (str-concat suffix data) = data ++ suffix
    const cat = try evalStr(al, "(str-concat \" world\" \"hello\")");
    try testing.expectEqualStrings("hello world", cat.string);
}

test "eval ok/err constructors and ok?/err?/unwrap" {
    var a = std.heap.ArenaAllocator.init(testing.allocator); defer a.deinit();
    const al = a.allocator();
    const ok_v = try evalStr(al, "(ok 42)");
    try testing.expect(!ok_v.isErr());
    try testing.expect((try evalStr(al, "(ok? (ok 1))")).bool_val  == true);
    try testing.expect((try evalStr(al, "(err? (err \"e\"))")).bool_val == true);
    try testing.expect((try evalStr(al, "(ok? (err \"e\"))")).bool_val == false);
    const unwrapped = try evalStr(al, "(unwrap (ok 7))");
    try testing.expectEqual(@as(i64, 7), unwrapped.int);
}

test "eval to-int and to-float" {
    var a = std.heap.ArenaAllocator.init(testing.allocator); defer a.deinit();
    const al = a.allocator();
    try testing.expectEqual(@as(i64, 42),   (try evalStr(al, "(to-int \"42\")")).int);
    try testing.expect((try evalStr(al, "(to-int \"bad\")")) == .null_val);
    try testing.expectApproxEqAbs(@as(f64, 3.14), (try evalStr(al, "(to-float \"3.14\")")).float, 1e-9);
}

test "eval chained field access" {
    var a = std.heap.ArenaAllocator.init(testing.allocator); defer a.deinit();
    // cfg:server:port — (cfg:server):port
    const v = try evalStr(a.allocator(),
        "(let cfg {server: {host: \"rpi\" port: 8080}} cfg:server:port)");
    try testing.expectEqual(@as(i64, 8080), v.int);
}
