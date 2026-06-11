//! Host platform — runs the REPL on stdin/stdout for development, no
//! hardware needed (`zig build run`). Mirrors rp2350.zig's shape:
//! module-level state + bare Io function pointers (the platform ABI
//! cannot capture state).
const std   = @import("std");
const shell = @import("shell");
const lang  = @import("lang");

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

const eval_commands: []const lang.eval.Command = &.{
    .{ .name = "echo", .func = &cmdEcho },
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
            "builtins: echo help\r\n");
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
