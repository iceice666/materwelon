//! Tree-walk evaluator with TCO trampolining — see SPEC.md §11.
//! Trampoline contract: step() returns Step.tail instead of recursing for
//! calls in tail position; eval() is the only loop, so tail calls run in
//! O(1) stack. Everything here needs Ctx (allocator, command table, env
//! store); pure operators live in ops.zig and pure functions in stdlib.zig.
const std   = @import("std");
const ast   = @import("ast.zig");
const value = @import("value.zig");
const env   = @import("env.zig");

const stdlib = @import("stdlib.zig");
const ops    = @import("ops.zig");
const errors = @import("errors.zig");

const Node  = ast.Node;
const Value = value.Value;
const Frame = env.Frame;

pub const EvalError = errors.RuntimeError;

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
// Pure formatting core lives in stdlib; these wrappers implement the dynamic
// arity (placeholder count) via the Partial application machinery.

fn applyFmtFirst(ctx: Ctx, arg: Value) EvalError!Value {
    const fmt_str = switch (arg) { .string => |s| s, else => return error.TypeError };
    if (stdlib.countPlaceholders(fmt_str) == 0) return arg; // no placeholders: identity
    const args = try ctx.alloc.alloc(Value, 1);
    args[0] = arg;
    const p = try ctx.alloc.create(Value.Partial);
    p.* = .{ .op = "f!/call", .args = args };
    return Value{ .partial = p };
}

fn applyFmtPartial(ctx: Ctx, p: *const Value.Partial, data: Value) EvalError!Value {
    const fmt_str = switch (p.args[0]) { .string => |s| s, else => return error.TypeError };
    const n_needed = stdlib.countPlaceholders(fmt_str);
    const new_args = try ctx.alloc.alloc(Value, p.args.len + 1);
    @memcpy(new_args[0..p.args.len], p.args);
    new_args[p.args.len] = data;
    // new_args[0] = fmt_str, new_args[1..] = value args collected so far
    if (new_args.len - 1 < n_needed) {
        const new_p = try ctx.alloc.create(Value.Partial);
        new_p.* = .{ .op = "f!/call", .args = new_args };
        return Value{ .partial = new_p };
    }
    return stdlib.formatBuiltin(ctx.alloc, fmt_str, new_args[1..]);
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

