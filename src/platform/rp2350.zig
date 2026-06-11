// RP2350 platform — pico-sdk stdio glue + hardware commands.
// This is the Zig root compiled by CMake; it exports shell_main for firmware/main.c.
const std  = @import("std");
const shell = @import("../shell/root.zig");
const lang  = @import("../lang/root.zig");

extern fn stdio_putchar_raw(c: c_int) c_int;
extern fn stdio_getchar_timeout_us(timeout_us: u32) c_int;
extern fn stdio_flush() void;
extern fn watchdog_reboot(pc: u32, sp: u32, delay_ms: u32) void;

// 48 KB for per-expression evaluation (reset each turn).
// 16 KB for top-level defs and closures (never reset).
var eval_heap: [48 * 1024]u8 = undefined;
var perm_heap: [16 * 1024]u8 = undefined;

var env_store: lang.env.EnvStore = .{};

// Io handle stored at startup so eval.Commands can write output.
var g_io: shell.Io = undefined;

fn readByte() ?u8 {
    const c = stdio_getchar_timeout_us(0xFFFF_FFFF);
    if (c < 0) return null;
    return @intCast(c & 0xFF);
}

fn writeBytes(s: []const u8) void {
    for (s) |c| _ = stdio_putchar_raw(c);
}

fn flushIo() void {
    stdio_flush();
}

const io: shell.Io = .{
    .read_byte   = &readByte,
    .write_bytes = &writeBytes,
    .flush       = &flushIo,
};

// ─── eval.Commands ───────────────────────────────────────────────────────────
// Single-argument commands callable from inside language expressions.
// Each receives one evaluated Value and returns {ok: null} or {err: msg}.

fn cmdEcho(alloc: std.mem.Allocator, args: []const lang.value.Value) lang.eval.EvalError!lang.value.Value {
    const sv = try lang.stdlib.toStr(alloc, args[0]);
    g_io.write_bytes(sv.string);
    g_io.write_bytes("\r\n");
    return lang.stdlib.makeOk(alloc, .null_val);
}

const eval_commands: []const lang.eval.Command = &.{
    .{ .name = "echo", .func = &cmdEcho },
};

// ─── Dispatch (bare REPL commands, multi-arg string form) ────────────────────

fn runBuiltin(run_io: shell.Io, argv: []const []const u8) bool {
    const cmd = argv[0];

    if (std.mem.eql(u8, cmd, "echo")) {
        for (argv[1..], 0..) |arg, i| {
            if (i > 0) shell.repl.writeStr(run_io, " ");
            shell.repl.writeStr(run_io, arg);
        }
        shell.repl.writeStr(run_io, "\r\n");
        return true;
    }

    if (std.mem.eql(u8, cmd, "help")) {
        shell.repl.writeStr(run_io, "builtins: echo help reboot\r\n");
        return true;
    }

    if (std.mem.eql(u8, cmd, "reboot")) {
        shell.repl.writeStr(run_io, "rebooting...\r\n");
        run_io.flush();
        watchdog_reboot(0, 0, 100);
        while (true) {}
    }

    return false;
}

pub export fn shell_main() void {
    g_io = io;
    var eval_fba = std.heap.FixedBufferAllocator.init(&eval_heap);
    var perm_fba = std.heap.FixedBufferAllocator.init(&perm_heap);
    shell.repl.run(io, &eval_fba, &perm_fba, eval_commands, &env_store, &runBuiltin);
}
