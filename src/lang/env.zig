// Lexical environment chain + mutable env store — see SPEC.md §9
const std = @import("std");
const value = @import("value.zig");

// ─── Lexical frame ────────────────────────────────────────────────────────────
//
// A singly-linked chain of (name, value) bindings.
// Frames are arena-allocated and never individually freed;
// the whole chain is reclaimed when the REPL resets its allocator.

pub const Frame = struct {
    name:   []const u8,
    val:    value.Value,
    parent: ?*const Frame,

    pub fn lookup(self: *const Frame, name: []const u8) ?value.Value {
        if (std.mem.eql(u8, self.name, name)) return self.val;
        return if (self.parent) |p| p.lookup(name) else null;
    }

    /// Extend this frame with a new binding.  Returns a pointer to the new
    /// frame, allocated from `alloc`.
    pub fn extend(
        self: *const Frame,
        alloc: std.mem.Allocator,
        name: []const u8,
        val: value.Value,
    ) !*Frame {
        const f = try alloc.create(Frame);
        f.* = .{ .name = name, .val = val, .parent = self };
        return f;
    }
};

/// Sentinel empty frame — the root of every environment chain.
pub const empty_frame = Frame{ .name = "", .val = .null_val, .parent = null };

// ─── Mutable env store ────────────────────────────────────────────────────────
//
// A flat key-value store backed by a static buffer.
// Lives outside the main heap; survives REPL resets.
// Keys and values are copied in; no lifetime dependency on the parse arena.

const MAX_ENV_ENTRIES = 64;
const MAX_KEY_LEN     = 32;
const MAX_VAL_STR_LEN = 128;

pub const EnvStore = struct {
    entries: [MAX_ENV_ENTRIES]Entry = undefined,
    len:     usize = 0,

    const Entry = struct {
        key: [MAX_KEY_LEN]u8,
        key_len: usize,
        val: value.Value,
    };

    pub fn get(self: *const EnvStore, key: []const u8) ?value.Value {
        for (self.entries[0..self.len]) |*e| {
            if (std.mem.eql(u8, e.key[0..e.key_len], key)) return e.val;
        }
        return null;
    }

    pub fn set(self: *EnvStore, key: []const u8, val: value.Value) error{KeyTooLong, StoreFull}!void {
        if (key.len > MAX_KEY_LEN) return error.KeyTooLong;
        // Update existing entry.
        for (self.entries[0..self.len]) |*e| {
            if (std.mem.eql(u8, e.key[0..e.key_len], key)) {
                e.val = val;
                return;
            }
        }
        // Insert new entry.
        if (self.len >= MAX_ENV_ENTRIES) return error.StoreFull;
        var e = &self.entries[self.len];
        @memcpy(e.key[0..key.len], key);
        e.key_len = key.len;
        e.val     = val;
        self.len += 1;
    }
};

// ─── Tests ────────────────────────────────────────────────────────────────────

const testing = std.testing;

test "frame lookup finds own binding" {
    const f = Frame{ .name = "x", .val = .{ .int = 42 }, .parent = null };
    try testing.expectEqual(@as(i64, 42), f.lookup("x").?.int);
}

test "frame lookup returns null for missing name" {
    const f = Frame{ .name = "x", .val = .null_val, .parent = null };
    try testing.expect(f.lookup("y") == null);
}

test "frame lookup walks parent chain" {
    const parent = Frame{ .name = "x", .val = .{ .int = 1 }, .parent = null };
    const child  = Frame{ .name = "y", .val = .{ .int = 2 }, .parent = &parent };
    try testing.expectEqual(@as(i64, 1), child.lookup("x").?.int);
    try testing.expectEqual(@as(i64, 2), child.lookup("y").?.int);
}

test "frame extend creates child" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const parent = Frame{ .name = "x", .val = .{ .int = 1 }, .parent = null };
    const child  = try parent.extend(arena.allocator(), "y", .{ .int = 2 });
    try testing.expectEqual(@as(i64, 1), child.lookup("x").?.int);
    try testing.expectEqual(@as(i64, 2), child.lookup("y").?.int);
}

test "inner binding shadows outer" {
    const outer = Frame{ .name = "x", .val = .{ .int = 1 }, .parent = null };
    const inner = Frame{ .name = "x", .val = .{ .int = 99 }, .parent = &outer };
    try testing.expectEqual(@as(i64, 99), inner.lookup("x").?.int);
}

test "EnvStore get/set basic" {
    var store: EnvStore = .{};
    try store.set("HOST", .{ .string = "rpi.local" });
    try testing.expectEqualStrings("rpi.local", store.get("HOST").?.string);
}

test "EnvStore update existing key" {
    var store: EnvStore = .{};
    try store.set("BAUD", .{ .int = 9600 });
    try store.set("BAUD", .{ .int = 115200 });
    try testing.expectEqual(@as(i64, 115200), store.get("BAUD").?.int);
}

test "EnvStore missing key returns null" {
    var store: EnvStore = .{};
    try testing.expect(store.get("MISSING") == null);
}

test "EnvStore key too long" {
    var store: EnvStore = .{};
    const long_key = "A" ** (MAX_KEY_LEN + 1);
    try testing.expectError(error.KeyTooLong, store.set(long_key, .null_val));
}
