//! Host platform — runs the REPL on stdin/stdout for development, no
//! hardware needed (`zig build run`). Mirrors rp2350.zig's shape:
//! module-level state + bare Io function pointers (the platform ABI
//! cannot capture state).
const std   = @import("std");
const shell = @import("shell");
const lang  = @import("lang");
const servo = lang.servo;

// ─── Memory budget ────────────────────────────────────────────────────────────
// Roomy on the host; the firmware budgets live in rp2350.zig.

const eval_heap_len = 1024 * 1024;
const perm_heap_len = 256 * 1024;

var eval_heap: [eval_heap_len]u8 = undefined;
var perm_heap: [perm_heap_len]u8 = undefined;

var env_store: lang.env.EnvStore = .{};

// ─── Io callbacks ─────────────────────────────────────────────────────────────

fn readByte() ?u8 {
    var b: [1]u8 = undefined;
    const n = std.posix.read(std.posix.STDIN_FILENO, &b) catch return null;
    return if (n == 0) null else b[0]; // EOF → repl.run returns
}

fn writeBytes(s: []const u8) void {
    // std.posix has no write() wrapper in Zig 0.16; use the raw syscall +
    // errno idiom the std lib itself uses.
    var off: usize = 0;
    while (off < s.len) {
        const rc = std.posix.system.write(std.posix.STDOUT_FILENO, s[off..].ptr, s.len - off);
        switch (std.posix.errno(rc)) {
            .SUCCESS => off += @intCast(rc),
            .INTR => continue,
            else => return,
        }
    }
}

fn flushIo() void {}

const io: shell.Io = .{
    .read_byte   = &readByte,
    .write_bytes = &writeBytes,
    .flush       = &flushIo,
};

// ─── eval.Commands ────────────────────────────────────────────────────────────
// echo is registered so the command path is exercisable off-hardware.

fn cmdEcho(alloc: std.mem.Allocator, args: []const lang.value.Value) lang.eval.EvalError!lang.value.Value {
    const sv = try lang.stdlib.toStr(alloc, args[0]);
    writeBytes(sv.string);
    writeBytes("\r\n");
    return lang.stdlib.makeOk(alloc, .null_val);
}

/// Extract a record field value by name, or return null.
fn recordField(fields: []const lang.value.Value.Field, key: []const u8) ?lang.value.Value {
    for (fields) |f| {
        if (std.mem.eql(u8, f.key, key)) return f.val;
    }
    return null;
}

/// Host stub for servo-move: hex-prints the packet bytes so the language path
/// is exercisable from `zig build run` without hardware.
fn cmdServoMove(alloc: std.mem.Allocator, args: []const lang.value.Value) lang.eval.EvalError!lang.value.Value {
    const fields = switch (args[0]) {
        .record => |f| f,
        else    => return try lang.stdlib.makeErr(alloc, .{ .string = "servo-move expects {id pos}" }),
    };
    const id_val  = recordField(fields, "id")  orelse
        return try lang.stdlib.makeErr(alloc, .{ .string = "servo-move: missing field 'id'" });
    const pos_val = recordField(fields, "pos") orelse
        return try lang.stdlib.makeErr(alloc, .{ .string = "servo-move: missing field 'pos'" });

    const id: u8 = switch (id_val) {
        .int => |v| if (v >= 1 and v <= 253) @intCast(v) else
            return try lang.stdlib.makeErr(alloc, .{ .string = "servo-move: id out of range" }),
        else => return try lang.stdlib.makeErr(alloc, .{ .string = "servo-move: id must be an int" }),
    };
    const deg: f32 = switch (pos_val) {
        .float => |v| @floatCast(v),
        .int   => |v| @floatFromInt(v),
        else   => return try lang.stdlib.makeErr(alloc, .{ .string = "servo-move: pos must be a number" }),
    };

    const pkt = servo.buildMovePacket(id, deg);
    // Hex-print: "servo-move pkt: 55 55 01 07 01 77 01 00 00 7e\r\n"
    writeBytes("servo-move pkt:");
    for (pkt) |b| {
        var buf: [3]u8 = undefined;
        const s = std.fmt.bufPrint(&buf, " {x:0>2}", .{b}) catch buf[0..];
        writeBytes(s);
    }
    writeBytes("\r\n");
    return lang.stdlib.makeOk(alloc, .null_val);
}

/// Host stub for servo-torque: hex-prints the packet bytes.
fn cmdServoTorque(alloc: std.mem.Allocator, args: []const lang.value.Value) lang.eval.EvalError!lang.value.Value {
    const fields = switch (args[0]) {
        .record => |f| f,
        else    => return try lang.stdlib.makeErr(alloc, .{ .string = "servo-torque expects {id on}" }),
    };
    const id_val = recordField(fields, "id") orelse
        return try lang.stdlib.makeErr(alloc, .{ .string = "servo-torque: missing field 'id'" });
    const on_val = recordField(fields, "on") orelse
        return try lang.stdlib.makeErr(alloc, .{ .string = "servo-torque: missing field 'on'" });

    const id: u8 = switch (id_val) {
        .int => |v| if (v >= 1 and v <= 253) @intCast(v) else
            return try lang.stdlib.makeErr(alloc, .{ .string = "servo-torque: id out of range" }),
        else => return try lang.stdlib.makeErr(alloc, .{ .string = "servo-torque: id must be an int" }),
    };
    const on: bool = switch (on_val) {
        .bool_val => |b| b,
        else      => return try lang.stdlib.makeErr(alloc, .{ .string = "servo-torque: on must be bool" }),
    };

    const pkt = servo.buildTorquePacket(id, on);
    writeBytes("servo-torque pkt:");
    for (pkt) |b| {
        var buf: [3]u8 = undefined;
        const s = std.fmt.bufPrint(&buf, " {x:0>2}", .{b}) catch buf[0..];
        writeBytes(s);
    }
    writeBytes("\r\n");
    return lang.stdlib.makeOk(alloc, .null_val);
}

const eval_commands: []const lang.eval.Command = &.{
    .{ .name = "echo",         .func = &cmdEcho        },
    .{ .name = "servo-move",   .func = &cmdServoMove   },
    .{ .name = "servo-torque", .func = &cmdServoTorque },
};

// ─── Bare REPL command dispatch ───────────────────────────────────────────────

fn dispatch(run_io: shell.Io, argv: []const []const u8) bool {
    if (std.mem.eql(u8, argv[0], "echo")) {
        for (argv[1..], 0..) |arg, i| {
            if (i > 0) shell.repl.writeStr(run_io, " ");
            shell.repl.writeStr(run_io, arg);
        }
        shell.repl.writeStr(run_io, "\r\n");
        return true;
    }
    if (std.mem.eql(u8, argv[0], "help")) {
        shell.repl.writeStr(run_io,
            "host REPL — language only; hardware commands need the RP2350 build\r\n" ++
            "builtins: echo help\r\n" ++
            "servo:    servo move <id> <deg>   servo torque <id> on|off  (hex-prints packet)\r\n");
        return true;
    }
    // Servo: bare command that hex-prints the packet (host stub, no hardware).
    if (std.mem.eql(u8, argv[0], "servo")) {
        if (argv.len < 2) {
            shell.repl.writeStr(run_io,
                "usage: servo move <id> <deg>   servo torque <id> on|off\r\n");
            return true;
        }
        const sub = argv[1];
        if (std.mem.eql(u8, sub, "move")) {
            if (argv.len < 4) {
                shell.repl.writeStr(run_io, "usage: servo move <id 1-253> <deg 0-240>\r\n");
                return true;
            }
            const id_n = std.fmt.parseInt(i64, argv[2], 10) catch {
                shell.repl.writeStr(run_io, "error: invalid servo id\r\n");
                return true;
            };
            if (id_n < 1 or id_n > 253) {
                shell.repl.writeStr(run_io, "error: servo id out of range (1-253)\r\n");
                return true;
            }
            const deg_n = std.fmt.parseFloat(f32, argv[3]) catch {
                shell.repl.writeStr(run_io, "error: invalid degrees\r\n");
                return true;
            };
            const pkt = servo.buildMovePacket(@intCast(id_n), deg_n);
            shell.repl.writeStr(run_io, "servo-move pkt:");
            for (pkt) |b| shell.repl.writeFmt(run_io, " {x:0>2}", .{b});
            shell.repl.writeStr(run_io, "\r\n");
            return true;
        }
        if (std.mem.eql(u8, sub, "torque")) {
            if (argv.len < 4) {
                shell.repl.writeStr(run_io, "usage: servo torque <id 1-253> on|off\r\n");
                return true;
            }
            const id_n = std.fmt.parseInt(i64, argv[2], 10) catch {
                shell.repl.writeStr(run_io, "error: invalid servo id\r\n");
                return true;
            };
            if (id_n < 1 or id_n > 253) {
                shell.repl.writeStr(run_io, "error: servo id out of range (1-253)\r\n");
                return true;
            }
            const on_str = argv[3];
            const on  = std.mem.eql(u8, on_str, "on")  or std.mem.eql(u8, on_str, "1");
            const off_ = std.mem.eql(u8, on_str, "off") or std.mem.eql(u8, on_str, "0");
            if (!on and !off_) {
                shell.repl.writeStr(run_io, "error: expected on|off|0|1\r\n");
                return true;
            }
            const pkt = servo.buildTorquePacket(@intCast(id_n), on);
            shell.repl.writeStr(run_io, "servo-torque pkt:");
            for (pkt) |b| shell.repl.writeFmt(run_io, " {x:0>2}", .{b});
            shell.repl.writeStr(run_io, "\r\n");
            return true;
        }
        shell.repl.writeStr(run_io,
            "usage: servo move <id> <deg>   servo torque <id> on|off\r\n");
        return true;
    }
    return false;
}

// ─── Entry ────────────────────────────────────────────────────────────────────

pub fn main() void {
    // readLine() does its own echo and backspace handling, so put the tty in
    // raw-ish mode (no kernel echo, no canonical line buffering) and restore
    // it on exit. tcgetattr fails on pipes (NotATerminal), which doubles as
    // the isatty guard; piped input just streams bytes and EOF ends the REPL.
    var saved: ?std.posix.termios = null;
    if (std.posix.tcgetattr(std.posix.STDIN_FILENO)) |orig| {
        var raw = orig;
        raw.lflag.ECHO = false;
        raw.lflag.ICANON = false;
        std.posix.tcsetattr(std.posix.STDIN_FILENO, .NOW, raw) catch {};
        saved = orig;
    } else |_| {}
    defer if (saved) |orig| std.posix.tcsetattr(std.posix.STDIN_FILENO, .NOW, orig) catch {};

    var eval_fba = std.heap.FixedBufferAllocator.init(&eval_heap);
    var perm_fba = std.heap.FixedBufferAllocator.init(&perm_heap);
    shell.repl.run(io, &eval_fba, &perm_fba, eval_commands, &env_store, &dispatch);
    writeBytes("\r\n");
}
