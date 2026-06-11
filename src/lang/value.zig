// Runtime value types — see SPEC.md §2
const std = @import("std");
const ast = @import("ast.zig");
const env = @import("env.zig");

pub const Value = union(enum) {
    int:      i64,
    float:    f64,
    number,                  // TODO: software bignum (§2)
    bool_val: bool,
    null_val,
    string:   []const u8,
    list:     []const Value,
    record:   []const Field,
    closure:  *const Closure,
    builtin:  []const u8,    // built-in name, e.g. "+" "neg" "map"
    partial:  *const Partial, // partially-applied builtin; accumulates args

    pub const Field = struct {
        key: []const u8,
        val: Value,
    };

    pub const Closure = struct {
        param: []const u8,
        body:  ast.Node,
        frame: *const env.Frame,
    };

    // A partially-applied built-in.  `args` holds the already-collected
    // arguments (oldest first); once len(args) == arity(op), execution fires.
    pub const Partial = struct {
        op:   []const u8,
        args: []const Value,
    };

    /// True iff the value is an error result record — {err: "..."} with no ok.
    pub fn isErr(self: Value) bool {
        switch (self) {
            .record => |fields| {
                var has_err = false;
                var has_ok  = false;
                for (fields) |f| {
                    if (std.mem.eql(u8, f.key, "err")) has_err = true;
                    if (std.mem.eql(u8, f.key, "ok"))  has_ok  = true;
                }
                return has_err and !has_ok;
            },
            else => return false,
        }
    }

    /// Falsy: false, null, error result records (SPEC §6, §8).
    pub fn isTruthy(self: Value) bool {
        return switch (self) {
            .bool_val => |b| b,
            .null_val => false,
            else      => !self.isErr(),
        };
    }
};
