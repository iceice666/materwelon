// Pure standard library — see SPEC.md §10
// All functions here are pure (no closure callbacks).
// HOFs that call closures (map, filter, fold, …) live in eval.zig.
const std    = @import("std");
const value  = @import("value.zig");
const errors = @import("errors.zig");

const Value = value.Value;

pub const Error = errors.PureError;

// ─── Builtin registry ────────────────────────────────────────────────────────
//
// Single authoritative table of every builtin name: curried arity plus a
// rough kind. The key set gates REPL bare-command dispatch via isStdlib —
// a missing name routes input to the platform command path, an extra name
// shadows platform commands.

pub const Kind = enum {
    op,      // arithmetic/comparison/unary operators (dispatched in eval/ops)
    pure,    // pure stdlib functions (applyPure below)
    hof,     // need eval context to call closures (dispatched in eval.zig)
    special, // bespoke application rules in eval.zig (field access, format)
};

pub const BuiltinInfo = struct { arity: u8, kind: Kind };

pub const builtins = std.StaticStringMap(BuiltinInfo).initComptime(.{
    // Unary operators
    .{ "neg", BuiltinInfo{ .arity = 1, .kind = .op } },
    .{ "not", BuiltinInfo{ .arity = 1, .kind = .op } },
    // Binary arithmetic / comparison / concat operators
    .{ "+",   BuiltinInfo{ .arity = 2, .kind = .op } },
    .{ "-",   BuiltinInfo{ .arity = 2, .kind = .op } },
    .{ "*",   BuiltinInfo{ .arity = 2, .kind = .op } },
    .{ "/",   BuiltinInfo{ .arity = 2, .kind = .op } },
    .{ "mod", BuiltinInfo{ .arity = 2, .kind = .op } },
    .{ "++",  BuiltinInfo{ .arity = 2, .kind = .op } },
    .{ "=",   BuiltinInfo{ .arity = 2, .kind = .op } },
    .{ "!=",  BuiltinInfo{ .arity = 2, .kind = .op } },
    .{ "<",   BuiltinInfo{ .arity = 2, .kind = .op } },
    .{ ">",   BuiltinInfo{ .arity = 2, .kind = .op } },
    .{ "<=",  BuiltinInfo{ .arity = 2, .kind = .op } },
    .{ ">=",  BuiltinInfo{ .arity = 2, .kind = .op } },
    // Field access — right side is a literal name (SPEC §3.6)
    .{ ":",   BuiltinInfo{ .arity = 2, .kind = .special } },
    // List
    .{ "first",   BuiltinInfo{ .arity = 1, .kind = .pure } },
    .{ "rest",    BuiltinInfo{ .arity = 1, .kind = .pure } },
    .{ "count",   BuiltinInfo{ .arity = 1, .kind = .pure } },
    .{ "reverse", BuiltinInfo{ .arity = 1, .kind = .pure } },
    .{ "flatten", BuiltinInfo{ .arity = 1, .kind = .pure } },
    .{ "append",  BuiltinInfo{ .arity = 2, .kind = .pure } },
    .{ "concat",  BuiltinInfo{ .arity = 2, .kind = .pure } },
    .{ "nth",     BuiltinInfo{ .arity = 2, .kind = .pure } },
    .{ "zip",     BuiltinInfo{ .arity = 2, .kind = .pure } },
    .{ "map",     BuiltinInfo{ .arity = 2, .kind = .hof } },
    .{ "filter",  BuiltinInfo{ .arity = 2, .kind = .hof } },
    .{ "fold",    BuiltinInfo{ .arity = 3, .kind = .hof } },
    // Record
    .{ "keys",   BuiltinInfo{ .arity = 1, .kind = .pure } },
    .{ "values", BuiltinInfo{ .arity = 1, .kind = .pure } },
    .{ "get",    BuiltinInfo{ .arity = 2, .kind = .pure } },
    .{ "del",    BuiltinInfo{ .arity = 2, .kind = .pure } },
    .{ "has",    BuiltinInfo{ .arity = 2, .kind = .pure } },
    .{ "merge",  BuiltinInfo{ .arity = 2, .kind = .pure } },
    .{ "set",    BuiltinInfo{ .arity = 3, .kind = .pure } }, // (set k v r)
    // String
    .{ "str-len",    BuiltinInfo{ .arity = 1, .kind = .pure } },
    .{ "to-str",     BuiltinInfo{ .arity = 1, .kind = .pure } },
    .{ "to-int",     BuiltinInfo{ .arity = 1, .kind = .pure } },
    .{ "to-float",   BuiltinInfo{ .arity = 1, .kind = .pure } },
    .{ "to-number",  BuiltinInfo{ .arity = 1, .kind = .pure } },
    .{ "str-join",   BuiltinInfo{ .arity = 2, .kind = .pure } },
    .{ "str-split",  BuiltinInfo{ .arity = 2, .kind = .pure } },
    .{ "str-concat", BuiltinInfo{ .arity = 2, .kind = .pure } },
    // Result helpers
    .{ "ok",       BuiltinInfo{ .arity = 1, .kind = .pure } },
    .{ "err",      BuiltinInfo{ .arity = 1, .kind = .pure } },
    .{ "unwrap",   BuiltinInfo{ .arity = 1, .kind = .pure } },
    .{ "ok?",      BuiltinInfo{ .arity = 1, .kind = .pure } },
    .{ "err?",     BuiltinInfo{ .arity = 1, .kind = .pure } },
    .{ "on-err",   BuiltinInfo{ .arity = 2, .kind = .hof } },
    .{ "map-ok",   BuiltinInfo{ .arity = 2, .kind = .hof } },
    .{ "and-then", BuiltinInfo{ .arity = 2, .kind = .hof } },
    // Higher-order utilities
    .{ "identity", BuiltinInfo{ .arity = 1, .kind = .pure } },
    .{ "const",    BuiltinInfo{ .arity = 2, .kind = .pure } },
    .{ "compose",  BuiltinInfo{ .arity = 2, .kind = .hof } },
    .{ "pipe",     BuiltinInfo{ .arity = 2, .kind = .hof } },
    .{ "flip",     BuiltinInfo{ .arity = 3, .kind = .hof } },
    // Synthetic ops created mid-evaluation for compose/pipe result functions;
    // arity 1 = "fire on the next argument" (the Partial already holds 2 args).
    .{ "compose/call", BuiltinInfo{ .arity = 1, .kind = .hof } },
    .{ "pipe/call",    BuiltinInfo{ .arity = 1, .kind = .hof } },
    // Format — variadic; eval.zig determines true arity from placeholder count
    .{ "f!",      BuiltinInfo{ .arity = 2, .kind = .special } },
    .{ "format",  BuiltinInfo{ .arity = 2, .kind = .special } },
    .{ "f!/call", BuiltinInfo{ .arity = 2, .kind = .special } },
});

/// Number of curried arguments a builtin consumes before executing.
pub fn arityOf(name: []const u8) ?u8 {
    return if (builtins.get(name)) |b| b.arity else null;
}

pub fn isStdlib(name: []const u8) bool {
    return builtins.has(name);
}

// ─── Pure dispatch ────────────────────────────────────────────────────────────
//
// Called by eval.zig once all args are collected for a non-HOF builtin.
// `args` is oldest-first: args[0] = first applied arg, args[n-1] = last (data).

pub fn applyPure(alloc: std.mem.Allocator, name: []const u8, args: []const Value) Error!Value {
    // List — 1-arg
    if (std.mem.eql(u8, name, "first"))   return listFirst(args[0]);
    if (std.mem.eql(u8, name, "rest"))    return try listRest(alloc, args[0]);
    if (std.mem.eql(u8, name, "count"))   return listCount(args[0]);
    if (std.mem.eql(u8, name, "reverse")) return try listReverse(alloc, args[0]);
    if (std.mem.eql(u8, name, "flatten")) return try listFlatten(alloc, args[0]);

    // List — 2-arg: args[0]=modifier/function, args[1]=data (data-last)
    if (std.mem.eql(u8, name, "append"))  return try listAppend(alloc, args[1], args[0]);
    if (std.mem.eql(u8, name, "concat"))  return try listConcat(alloc, args[1], args[0]);
    if (std.mem.eql(u8, name, "nth"))     return listNth(args[0], args[1]);
    if (std.mem.eql(u8, name, "zip"))     return try listZip(alloc, args[1], args[0]);

    // Record — 1-arg
    if (std.mem.eql(u8, name, "keys"))    return try recordKeys(alloc, args[0]);
    if (std.mem.eql(u8, name, "values"))  return try recordValues(alloc, args[0]);

    // Record — 2-arg: args[0]=modifier, args[1]=data
    if (std.mem.eql(u8, name, "get"))     return recordGet(args[0], args[1]);
    if (std.mem.eql(u8, name, "del"))     return try recordDel(alloc, args[0], args[1]);
    if (std.mem.eql(u8, name, "has"))     return recordHas(args[0], args[1]);
    if (std.mem.eql(u8, name, "merge"))   return try recordMerge(alloc, args[1], args[0]);

    // Record — 3-arg: (set k v r) → args[0]=k, args[1]=v, args[2]=r
    if (std.mem.eql(u8, name, "set"))     return try recordSet(alloc, args[0], args[1], args[2]);

    // String — 1-arg
    if (std.mem.eql(u8, name, "str-len")) return strLen(args[0]);
    if (std.mem.eql(u8, name, "to-str"))  return try toStr(alloc, args[0]);
    if (std.mem.eql(u8, name, "to-int"))  return toInt(args[0]);
    if (std.mem.eql(u8, name, "to-float")) return toFloat(args[0]);
    if (std.mem.eql(u8, name, "to-number")) return .number; // TODO bignum

    // String — 2-arg: args[0]=modifier, args[1]=data (data-last)
    if (std.mem.eql(u8, name, "str-join"))   return try strJoin(alloc, args[0], args[1]);
    if (std.mem.eql(u8, name, "str-split"))  return try strSplit(alloc, args[0], args[1]);
    if (std.mem.eql(u8, name, "str-concat")) return try strConcat(alloc, args[1], args[0]);

    // Result helpers — 1-arg
    if (std.mem.eql(u8, name, "ok"))      return try makeOk(alloc, args[0]);
    if (std.mem.eql(u8, name, "err"))     return try makeErr(alloc, args[0]);
    if (std.mem.eql(u8, name, "unwrap"))  return unwrap(args[0]);
    if (std.mem.eql(u8, name, "ok?"))     return Value{ .bool_val = isOk(args[0]) };
    if (std.mem.eql(u8, name, "err?"))    return Value{ .bool_val = args[0].isErr() };

    // HOF stubs — should not reach here (eval.zig handles HOFs)
    if (std.mem.eql(u8, name, "identity")) return args[0];
    if (std.mem.eql(u8, name, "const"))    return args[0]; // args[0]=x, args[1]=_ ignored

    return error.TypeError;
}

// ─── List operations ──────────────────────────────────────────────────────────

fn listFirst(xs: Value) Error!Value {
    return switch (xs) {
        .list => |s| if (s.len > 0) s[0] else .null_val,
        else  => error.TypeError,
    };
}

fn listRest(alloc: std.mem.Allocator, xs: Value) Error!Value {
    _ = alloc;
    return switch (xs) {
        .list => |s| Value{ .list = if (s.len > 0) s[1..] else s },
        else  => error.TypeError,
    };
}

fn listCount(xs: Value) Error!Value {
    return switch (xs) {
        .list   => |s| Value{ .int = @intCast(s.len) },
        .string => |s| Value{ .int = @intCast(s.len) },
        else    => error.TypeError,
    };
}

fn listReverse(alloc: std.mem.Allocator, xs: Value) Error!Value {
    return switch (xs) {
        .list => |s| {
            const out = try alloc.alloc(Value, s.len);
            for (s, 0..) |v, i| out[s.len - 1 - i] = v;
            return Value{ .list = out };
        },
        else => error.TypeError,
    };
}

fn listFlatten(alloc: std.mem.Allocator, xs: Value) Error!Value {
    const outer = switch (xs) {
        .list => |s| s,
        else  => return error.TypeError,
    };
    var total: usize = 0;
    for (outer) |inner| {
        switch (inner) {
            .list => |s| total += s.len,
            else  => return error.TypeError,
        }
    }
    const out = try alloc.alloc(Value, total);
    var i: usize = 0;
    for (outer) |inner| {
        const s = inner.list;
        @memcpy(out[i .. i + s.len], s);
        i += s.len;
    }
    return Value{ .list = out };
}

// (append xs x) — x appended to end of xs
fn listAppend(alloc: std.mem.Allocator, xs: Value, x: Value) Error!Value {
    const s = switch (xs) {
        .list => |s| s,
        else  => return error.TypeError,
    };
    const out = try alloc.alloc(Value, s.len + 1);
    @memcpy(out[0..s.len], s);
    out[s.len] = x;
    return Value{ .list = out };
}

// (concat xs ys) — ys appended to end of xs
fn listConcat(alloc: std.mem.Allocator, xs: Value, ys: Value) Error!Value {
    const a = switch (xs) { .list => |s| s, else => return error.TypeError };
    const b = switch (ys) { .list => |s| s, else => return error.TypeError };
    const out = try alloc.alloc(Value, a.len + b.len);
    @memcpy(out[0..a.len], a);
    @memcpy(out[a.len..], b);
    return Value{ .list = out };
}

// (nth n xs) — data-last, so args[0]=n modifier, args[1]=xs data
fn listNth(n_val: Value, xs: Value) Error!Value {
    const n = switch (n_val) { .int => |i| i, else => return error.TypeError };
    const s = switch (xs)    { .list => |s| s, else => return error.TypeError };
    if (n < 0 or n >= @as(i64, @intCast(s.len))) return .null_val;
    return s[@intCast(n)];
}

// (zip xs ys) — args[0]=ys modifier, args[1]=xs data
fn listZip(alloc: std.mem.Allocator, xs: Value, ys: Value) Error!Value {
    const a = switch (xs) { .list => |s| s, else => return error.TypeError };
    const b = switch (ys) { .list => |s| s, else => return error.TypeError };
    const len = @min(a.len, b.len);
    const out = try alloc.alloc(Value, len);
    for (0..len) |i| {
        const fields = try alloc.alloc(Value.Field, 2);
        fields[0] = .{ .key = "fst", .val = a[i] };
        fields[1] = .{ .key = "snd", .val = b[i] };
        out[i] = Value{ .record = fields };
    }
    return Value{ .list = out };
}

// ─── Record operations ────────────────────────────────────────────────────────

fn recordGet(key: Value, rec: Value) Error!Value {
    const k = switch (key) { .string => |s| s, else => return error.TypeError };
    const fields = switch (rec) { .record => |f| f, else => return .null_val };
    for (fields) |f| if (std.mem.eql(u8, f.key, k)) return f.val;
    return .null_val;
}

fn recordDel(alloc: std.mem.Allocator, key: Value, rec: Value) Error!Value {
    const k = switch (key) { .string => |s| s, else => return error.TypeError };
    const fields = switch (rec) { .record => |f| f, else => return error.TypeError };
    var out: std.ArrayList(Value.Field) = .empty;
    for (fields) |f| {
        if (!std.mem.eql(u8, f.key, k)) try out.append(alloc, f);
    }
    return Value{ .record = try out.toOwnedSlice(alloc) };
}

fn recordHas(key: Value, rec: Value) Error!Value {
    const k = switch (key) { .string => |s| s, else => return error.TypeError };
    const fields = switch (rec) { .record => |f| f, else => return Value{ .bool_val = false } };
    for (fields) |f| if (std.mem.eql(u8, f.key, k)) return Value{ .bool_val = true };
    return Value{ .bool_val = false };
}

fn recordKeys(alloc: std.mem.Allocator, rec: Value) Error!Value {
    const fields = switch (rec) { .record => |f| f, else => return error.TypeError };
    const out = try alloc.alloc(Value, fields.len);
    for (fields, 0..) |f, i| out[i] = Value{ .string = f.key };
    return Value{ .list = out };
}

fn recordValues(alloc: std.mem.Allocator, rec: Value) Error!Value {
    const fields = switch (rec) { .record => |f| f, else => return error.TypeError };
    const out = try alloc.alloc(Value, fields.len);
    for (fields, 0..) |f, i| out[i] = f.val;
    return Value{ .list = out };
}

// (merge r1 r2) — r2 wins on key conflict; args[0]=r2 modifier, args[1]=r1 data
fn recordMerge(alloc: std.mem.Allocator, r1: Value, r2: Value) Error!Value {
    const f1 = switch (r1) { .record => |f| f, else => return error.TypeError };
    const f2 = switch (r2) { .record => |f| f, else => return error.TypeError };
    var out: std.ArrayList(Value.Field) = .empty;
    // Add all from r1 that are not in r2
    for (f1) |f| {
        var in_r2 = false;
        for (f2) |g| if (std.mem.eql(u8, f.key, g.key)) { in_r2 = true; break; };
        if (!in_r2) try out.append(alloc, f);
    }
    // Add all from r2
    for (f2) |f| try out.append(alloc, f);
    return Value{ .record = try out.toOwnedSlice(alloc) };
}

// (set k v r) — args[0]=k, args[1]=v, args[2]=r
fn recordSet(alloc: std.mem.Allocator, k_val: Value, v: Value, rec: Value) Error!Value {
    const k = switch (k_val) { .string => |s| s, else => return error.TypeError };
    const fields = switch (rec) { .record => |f| f, else => return error.TypeError };
    var out: std.ArrayList(Value.Field) = .empty;
    var updated = false;
    for (fields) |f| {
        if (std.mem.eql(u8, f.key, k)) {
            try out.append(alloc, .{ .key = k, .val = v });
            updated = true;
        } else {
            try out.append(alloc, f);
        }
    }
    if (!updated) try out.append(alloc, .{ .key = k, .val = v });
    return Value{ .record = try out.toOwnedSlice(alloc) };
}

// ─── String operations ────────────────────────────────────────────────────────

fn strLen(s: Value) Error!Value {
    return switch (s) {
        .string => |str| Value{ .int = @intCast(str.len) },
        else    => error.TypeError,
    };
}

// (str-join sep xs) — args[0]=sep, args[1]=xs (data-last)
fn strJoin(alloc: std.mem.Allocator, sep: Value, xs: Value) Error!Value {
    const sep_str = switch (sep) { .string => |s| s, else => return error.TypeError };
    const items   = switch (xs)  { .list   => |s| s, else => return error.TypeError };
    if (items.len == 0) return Value{ .string = "" };
    var buf: std.ArrayList(u8) = .empty;
    for (items, 0..) |item, i| {
        if (i > 0) try buf.appendSlice(alloc, sep_str);
        switch (item) {
            .string => |s| try buf.appendSlice(alloc, s),
            else    => return error.TypeError,
        }
    }
    return Value{ .string = try buf.toOwnedSlice(alloc) };
}

// (str-split sep s) — args[0]=sep, args[1]=s (data-last)
fn strSplit(alloc: std.mem.Allocator, sep: Value, s: Value) Error!Value {
    const sep_str = switch (sep) { .string => |str| str, else => return error.TypeError };
    const src     = switch (s)   { .string => |str| str, else => return error.TypeError };
    var parts: std.ArrayList(Value) = .empty;
    var it = std.mem.splitSequence(u8, src, sep_str);
    while (it.next()) |part| {
        try parts.append(alloc, Value{ .string = part });
    }
    return Value{ .list = try parts.toOwnedSlice(alloc) };
}

fn strConcat(alloc: std.mem.Allocator, a: Value, b: Value) Error!Value {
    const sa = switch (a) { .string => |s| s, else => return error.TypeError };
    const sb = switch (b) { .string => |s| s, else => return error.TypeError };
    const out = try alloc.alloc(u8, sa.len + sb.len);
    @memcpy(out[0..sa.len], sa);
    @memcpy(out[sa.len..], sb);
    return Value{ .string = out };
}

pub fn toStr(alloc: std.mem.Allocator, v: Value) Error!Value {
    const s = switch (v) {
        .string   => |s|   return Value{ .string = s },
        .int      => |n|   try std.fmt.allocPrint(alloc, "{}", .{n}),
        .float    => |f|   try std.fmt.allocPrint(alloc, "{d}", .{f}),
        .bool_val => |b|   if (b) "true" else "false",
        .null_val =>       "null",
        .number   =>       "number",
        .list     => |xs|  blk: {
            var buf: std.ArrayList(u8) = .empty;
            try buf.append(alloc, '[');
            for (xs, 0..) |x, i| {
                if (i > 0) try buf.appendSlice(alloc, " ");
                const inner = try toStr(alloc, x);
                try buf.appendSlice(alloc, inner.string);
            }
            try buf.append(alloc, ']');
            break :blk try buf.toOwnedSlice(alloc);
        },
        .record   => |fs|  blk: {
            var buf: std.ArrayList(u8) = .empty;
            try buf.append(alloc, '{');
            for (fs, 0..) |f, i| {
                if (i > 0) try buf.appendSlice(alloc, " ");
                try buf.appendSlice(alloc, f.key);
                try buf.appendSlice(alloc, ": ");
                const inner = try toStr(alloc, f.val);
                try buf.appendSlice(alloc, inner.string);
            }
            try buf.append(alloc, '}');
            break :blk try buf.toOwnedSlice(alloc);
        },
        .closure  => "<function>",
        .builtin  => |n|   n,
        .partial  => "<partial>",
    };
    return Value{ .string = s };
}

// ─── String formatting (f! / format) ─────────────────────────────────────────
// eval.zig determines the true arity of f!/format dynamically from the
// placeholder count; these helpers are the pure formatting core.

pub fn countPlaceholders(fmt: []const u8) usize {
    var n: usize = 0;
    var i: usize = 0;
    while (i + 1 < fmt.len) : (i += 1) {
        if (fmt[i] == '{' and fmt[i + 1] == '}') { n += 1; i += 1; }
    }
    return n;
}

pub fn formatBuiltin(alloc: std.mem.Allocator, fmt: []const u8, values: []const Value) Error!Value {
    var buf: std.ArrayList(u8) = .empty;
    var vi: usize = 0;
    var i: usize = 0;
    while (i < fmt.len) {
        if (i + 1 < fmt.len and fmt[i] == '{' and fmt[i + 1] == '}') {
            if (vi >= values.len) return error.TypeError;
            const sv = try toStr(alloc, values[vi]);
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

fn toInt(v: Value) Error!Value {
    return switch (v) {
        .int    => v,
        .float  => |f| Value{ .int = @intFromFloat(f) },
        .string => |s| blk: {
            const n = std.fmt.parseInt(i64, s, 10) catch return .null_val;
            break :blk Value{ .int = n };
        },
        else => .null_val,
    };
}

fn toFloat(v: Value) Error!Value {
    return switch (v) {
        .float  => v,
        .int    => |n| Value{ .float = @floatFromInt(n) },
        .string => |s| blk: {
            const f = std.fmt.parseFloat(f64, s) catch return .null_val;
            break :blk Value{ .float = f };
        },
        else => .null_val,
    };
}

// ─── Result helpers ───────────────────────────────────────────────────────────

pub fn makeOk(alloc: std.mem.Allocator, v: Value) Error!Value {
    const fields = try alloc.alloc(Value.Field, 1);
    fields[0] = .{ .key = "ok", .val = v };
    return Value{ .record = fields };
}

pub fn makeErr(alloc: std.mem.Allocator, msg: Value) Error!Value {
    const fields = try alloc.alloc(Value.Field, 1);
    fields[0] = .{ .key = "err", .val = msg };
    return Value{ .record = fields };
}

fn unwrap(v: Value) Error!Value {
    if (!v.isErr()) {
        // Extract :ok field
        switch (v) {
            .record => |fields| {
                for (fields) |f| if (std.mem.eql(u8, f.key, "ok")) return f.val;
            },
            else => {},
        }
        return v; // bare value (not a result record) passes through
    }
    return v; // error result: return as-is; REPL prints it
}

fn isOk(v: Value) bool {
    if (v.isErr()) return false;
    switch (v) {
        .record => |fields| {
            for (fields) |f| if (std.mem.eql(u8, f.key, "ok")) return true;
            return false;
        },
        else => return false,
    }
}

// ─── Tests ────────────────────────────────────────────────────────────────────

const testing = std.testing;

fn testAlloc() std.mem.Allocator { return testing.allocator; }

test "arityOf operators" {
    try testing.expectEqual(@as(?u8, 2), arityOf("+"));
    try testing.expectEqual(@as(?u8, 2), arityOf("*"));
    try testing.expectEqual(@as(?u8, 2), arityOf(":"));
    try testing.expectEqual(@as(?u8, 1), arityOf("neg"));
}

test "arityOf stdlib" {
    try testing.expectEqual(@as(?u8, 1), arityOf("count"));
    try testing.expectEqual(@as(?u8, 2), arityOf("map"));
    try testing.expectEqual(@as(?u8, 3), arityOf("fold"));
    try testing.expectEqual(@as(?u8, 3), arityOf("set"));
    try testing.expectEqual(@as(?u8, null), arityOf("unknown"));
}

test "builtin registry parity" {
    // isStdlib gates REPL bare-command dispatch: a missing name routes input
    // to the platform command path; an extra name shadows platform commands.
    // This pins the exact key set and arities of the registry.
    const arity1 = [_][]const u8{
        "neg", "not",
        "first", "rest", "count", "reverse", "flatten",
        "keys", "values",
        "str-len", "to-str", "to-int", "to-float", "to-number",
        "ok", "err", "unwrap", "ok?", "err?",
        "identity",
        "compose/call", "pipe/call",
    };
    const arity2 = [_][]const u8{
        "+", "-", "*", "/", "mod", "++",
        "=", "!=", "<", ">", "<=", ">=",
        ":",
        "map", "filter", "append", "concat", "nth", "zip",
        "get", "del", "has", "merge",
        "str-join", "str-split", "str-concat",
        "on-err", "map-ok", "and-then",
        "const", "compose", "pipe",
        "f!", "format", "f!/call",
    };
    const arity3 = [_][]const u8{ "fold", "set", "flip" };

    for (arity1) |n| try testing.expectEqual(@as(?u8, 1), arityOf(n));
    for (arity2) |n| try testing.expectEqual(@as(?u8, 2), arityOf(n));
    for (arity3) |n| try testing.expectEqual(@as(?u8, 3), arityOf(n));

    // No extra keys beyond the lists above.
    try testing.expectEqual(arity1.len + arity2.len + arity3.len, builtins.kvs.len);
}

test "listFirst/rest" {
    const xs = Value{ .list = &[_]Value{ .{ .int = 1 }, .{ .int = 2 } } };
    try testing.expectEqual(@as(i64, 1), (try listFirst(xs)).int);
    const rest = try listRest(testing.allocator, xs);
    try testing.expectEqual(@as(usize, 1), rest.list.len);
    try testing.expectEqual(@as(i64, 2), rest.list[0].int);
}

test "listCount" {
    const xs = Value{ .list = &[_]Value{ .{ .int = 1 }, .{ .int = 2 }, .{ .int = 3 } } };
    try testing.expectEqual(@as(i64, 3), (try listCount(xs)).int);
}

test "listReverse" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator); defer arena.deinit();
    const xs = Value{ .list = &[_]Value{ .{ .int = 1 }, .{ .int = 2 }, .{ .int = 3 } } };
    const rev = try listReverse(arena.allocator(), xs);
    try testing.expectEqual(@as(i64, 3), rev.list[0].int);
    try testing.expectEqual(@as(i64, 1), rev.list[2].int);
}

test "listAppend" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator); defer arena.deinit();
    const xs = Value{ .list = &[_]Value{ .{ .int = 1 }, .{ .int = 2 } } };
    const out = try listAppend(arena.allocator(), xs, Value{ .int = 3 });
    try testing.expectEqual(@as(usize, 3), out.list.len);
    try testing.expectEqual(@as(i64, 3), out.list[2].int);
}

test "listFlatten" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator); defer arena.deinit();
    const inner1 = Value{ .list = &[_]Value{ .{ .int = 1 }, .{ .int = 2 } } };
    const inner2 = Value{ .list = &[_]Value{ .{ .int = 3 } } };
    const outer  = Value{ .list = &[_]Value{ inner1, inner2 } };
    const flat = try listFlatten(arena.allocator(), outer);
    try testing.expectEqual(@as(usize, 3), flat.list.len);
    try testing.expectEqual(@as(i64, 3), flat.list[2].int);
}

test "listNth" {
    const xs = Value{ .list = &[_]Value{ .{ .int = 10 }, .{ .int = 20 }, .{ .int = 30 } } };
    try testing.expectEqual(@as(i64, 20), (try listNth(Value{ .int = 1 }, xs)).int);
    try testing.expectEqual(Value.null_val, try listNth(Value{ .int = 5 }, xs));
}

test "listZip" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator); defer arena.deinit();
    const xs = Value{ .list = &[_]Value{ .{ .int = 1 }, .{ .int = 2 } } };
    const ys = Value{ .list = &[_]Value{ .{ .int = 3 }, .{ .int = 4 } } };
    const out = try listZip(arena.allocator(), xs, ys);
    try testing.expectEqual(@as(usize, 2), out.list.len);
    try testing.expectEqual(@as(i64, 1), out.list[0].record[0].val.int); // fst
    try testing.expectEqual(@as(i64, 4), out.list[1].record[1].val.int); // snd
}

test "recordGet/has/del" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator); defer arena.deinit();
    const fields = &[_]Value.Field{
        .{ .key = "x", .val = .{ .int = 1 } },
        .{ .key = "y", .val = .{ .int = 2 } },
    };
    const rec = Value{ .record = fields };
    try testing.expectEqual(@as(i64, 1), (try recordGet(Value{ .string = "x" }, rec)).int);
    try testing.expectEqual(Value.null_val, try recordGet(Value{ .string = "z" }, rec));
    try testing.expect((try recordHas(Value{ .string = "x" }, rec)).bool_val == true);
    try testing.expect((try recordHas(Value{ .string = "z" }, rec)).bool_val == false);
    const del = try recordDel(arena.allocator(), Value{ .string = "x" }, rec);
    try testing.expectEqual(@as(usize, 1), del.record.len);
}

test "recordSet" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator); defer arena.deinit();
    const fields = &[_]Value.Field{ .{ .key = "x", .val = .{ .int = 1 } } };
    const rec = Value{ .record = fields };
    const updated = try recordSet(arena.allocator(), Value{ .string = "x" }, Value{ .int = 99 }, rec);
    try testing.expectEqual(@as(i64, 99), updated.record[0].val.int);
    const added = try recordSet(arena.allocator(), Value{ .string = "y" }, Value{ .int = 2 }, rec);
    try testing.expectEqual(@as(usize, 2), added.record.len);
}

test "recordMerge (r2 wins)" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator); defer arena.deinit();
    const r1 = Value{ .record = &[_]Value.Field{
        .{ .key = "a", .val = .{ .int = 1 } },
        .{ .key = "b", .val = .{ .int = 2 } },
    }};
    const r2 = Value{ .record = &[_]Value.Field{
        .{ .key = "b", .val = .{ .int = 99 } },
        .{ .key = "c", .val = .{ .int = 3 } },
    }};
    const merged = try recordMerge(arena.allocator(), r1, r2);
    var b_val: i64 = 0;
    for (merged.record) |f| if (std.mem.eql(u8, f.key, "b")) { b_val = f.val.int; };
    try testing.expectEqual(@as(i64, 99), b_val);
    try testing.expectEqual(@as(usize, 3), merged.record.len);
}

test "strLen" {
    try testing.expectEqual(@as(i64, 5), (try strLen(Value{ .string = "hello" })).int);
}

test "strJoin" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator); defer arena.deinit();
    const items = Value{ .list = &[_]Value{
        .{ .string = "a" }, .{ .string = "b" }, .{ .string = "c" },
    }};
    const out = try strJoin(arena.allocator(), Value{ .string = "," }, items);
    try testing.expectEqualStrings("a,b,c", out.string);
}

test "strSplit" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator); defer arena.deinit();
    const out = try strSplit(arena.allocator(),
        Value{ .string = "," }, Value{ .string = "a,b,c" });
    try testing.expectEqual(@as(usize, 3), out.list.len);
    try testing.expectEqualStrings("b", out.list[1].string);
}

test "toStr conversions" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator); defer arena.deinit();
    const alloc2 = arena.allocator();
    try testing.expectEqualStrings("42",    (try toStr(alloc2, Value{ .int = 42 })).string);
    try testing.expectEqualStrings("true",  (try toStr(alloc2, Value{ .bool_val = true })).string);
    try testing.expectEqualStrings("null",  (try toStr(alloc2, .null_val)).string);
    try testing.expectEqualStrings("hello", (try toStr(alloc2, Value{ .string = "hello" })).string);
}

test "toInt/toFloat" {
    try testing.expectEqual(@as(i64, 42),   (try toInt(Value{ .string = "42" })).int);
    try testing.expectEqual(Value.null_val,  try toInt(Value{ .string = "abc" }));
    try testing.expectEqual(@as(f64, 3.14), (try toFloat(Value{ .string = "3.14" })).float);
}

test "ok/err/unwrap/ok?/err?" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator); defer arena.deinit();
    const ok_val  = try makeOk(arena.allocator(), Value{ .int = 5 });
    const err_val = try makeErr(arena.allocator(), Value{ .string = "oops" });
    try testing.expect(isOk(ok_val));
    try testing.expect(!isOk(err_val));
    try testing.expect(ok_val.isErr() == false);
    try testing.expect(err_val.isErr() == true);
    try testing.expectEqual(@as(i64, 5), (try unwrap(ok_val)).int);
}
