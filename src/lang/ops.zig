//! Binary and unary operator implementations — see SPEC.md §3.4, §10.
//! Pure `Value × Value → Value` functions: no evaluation context needed,
//! only an allocator (for `++` concat). HOFs that re-enter the evaluator
//! live in eval.zig.
const std    = @import("std");
const value  = @import("value.zig");
const errors = @import("errors.zig");

const Value = value.Value;

pub const Error = errors.PureError;

// ─── Binary operator dispatch ─────────────────────────────────────────────────
// Convention: `data op mod` — data is left operand, mod is right operand.

pub fn applyBinaryOp(alloc: std.mem.Allocator, op: []const u8, data: Value, mod: Value) Error!Value {
    // `++` — concat strings or lists
    if (std.mem.eql(u8, op, "++")) return applyConcat(alloc, data, mod);

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

pub fn isBinaryOp(name: []const u8) bool {
    const ops = [_][]const u8{
        "+", "-", "*", "/", "mod", "++",
        "=", "!=", "<", ">", "<=", ">=",
    };
    for (ops) |op| if (std.mem.eql(u8, name, op)) return true;
    return false;
}

const CmpOp = enum { eq, ne, lt, gt, le, ge };

fn applyCmp(data: Value, mod: Value, op: CmpOp) Error!Value {
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

fn applyAdd(a: Value, b: Value) Error!Value {
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

fn applySub(a: Value, b: Value) Error!Value {
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

fn applyMul(a: Value, b: Value) Error!Value {
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

fn applyDiv(a: Value, b: Value) Error!Value {
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

fn applyMod(a: Value, b: Value) Error!Value {
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

pub fn applyNeg(arg: Value) Error!Value {
    return switch (arg) {
        .int   => |n| .{ .int   = -n },
        .float => |f| .{ .float = -f },
        else   => error.TypeError,
    };
}

fn applyConcat(alloc: std.mem.Allocator, a: Value, b: Value) Error!Value {
    return switch (a) {
        .string => |s| switch (b) {
            .string => |t| blk: {
                const out = try alloc.alloc(u8, s.len + t.len);
                @memcpy(out[0..s.len], s);
                @memcpy(out[s.len..], t);
                break :blk Value{ .string = out };
            },
            else => error.TypeError,
        },
        .list => |xs| switch (b) {
            .list => |ys| blk: {
                const out = try alloc.alloc(Value, xs.len + ys.len);
                @memcpy(out[0..xs.len], xs);
                @memcpy(out[xs.len..], ys);
                break :blk Value{ .list = out };
            },
            else => error.TypeError,
        },
        else => error.TypeError,
    };
}
