// RP2350 platform — pico-sdk stdio glue + hardware commands.
// This is the Zig root compiled by CMake; it exports shell_main for firmware/main.c.
const std   = @import("std");
const shell = @import("shell");
const lang  = @import("lang");

// ─── pico-sdk externs ─────────────────────────────────────────────────────────

extern fn stdio_putchar_raw(c: c_int) c_int;
extern fn stdio_getchar_timeout_us(timeout_us: u32) c_int;
extern fn stdio_flush() void;
extern fn watchdog_reboot(pc: u32, sp: u32, delay_ms: u32) void;

// GPIO (hardware/gpio.h)
extern fn gpio_init(gpio: c_uint) void;
extern fn gpio_set_dir(gpio: c_uint, out: bool) void;
extern fn gpio_put(gpio: c_uint, value: bool) void;
extern fn gpio_get(gpio: c_uint) bool;

// ADC (hardware/adc.h)
extern fn adc_init() void;
extern fn adc_gpio_init(gpio: c_uint) void;
extern fn adc_select_input(input: c_uint) void;
extern fn adc_read() u16;

// ─── Allocators and state ─────────────────────────────────────────────────────

// 48 KB for per-expression evaluation (reset each turn).
// 16 KB for top-level defs and closures (never reset).
var eval_heap: [48 * 1024]u8 = undefined;
var perm_heap: [16 * 1024]u8 = undefined;

var env_store: lang.env.EnvStore = .{};

// Io handle stored at startup so eval.Commands can write output.
var g_io: shell.Io = undefined;

// ─── Io callbacks ─────────────────────────────────────────────────────────────

fn readByte() ?u8 {
    const c = stdio_getchar_timeout_us(0xFFFF_FFFF);
    if (c < 0) return null;
    return @intCast(c & 0xFF);
}

fn writeBytes(s: []const u8) void {
    for (s) |c| _ = stdio_putchar_raw(c);
}

fn flushIo() void { stdio_flush(); }

const io: shell.Io = .{
    .read_byte   = &readByte,
    .write_bytes = &writeBytes,
    .flush       = &flushIo,
};

// ─── Validation helpers ────────────────────────────────────────────────────────

fn validPin(n: i64) bool    { return n >= 0 and n <= 29; }
fn validChannel(n: i64) bool { return n >= 0 and n <= 4; }

fn pinFromArg(args: []const lang.value.Value) ?c_uint {
    const n = switch (args[0]) { .int => |v| v, else => return null };
    return if (validPin(n)) @intCast(n) else null;
}

// ─── eval.Commands ────────────────────────────────────────────────────────────
// Callable from language expressions: (echo x), (gpio-out 1), (adc-read 0), ...

fn cmdEcho(alloc: std.mem.Allocator, args: []const lang.value.Value) lang.eval.EvalError!lang.value.Value {
    const sv = try lang.stdlib.toStr(alloc, args[0]);
    g_io.write_bytes(sv.string);
    g_io.write_bytes("\r\n");
    return lang.stdlib.makeOk(alloc, .null_val);
}

fn cmdGpioOut(alloc: std.mem.Allocator, args: []const lang.value.Value) lang.eval.EvalError!lang.value.Value {
    const pin = pinFromArg(args) orelse
        return try lang.stdlib.makeErr(alloc, .{ .string = "invalid pin" });
    gpio_init(pin);
    gpio_set_dir(pin, true);
    return lang.stdlib.makeOk(alloc, .null_val);
}

fn cmdGpioIn(alloc: std.mem.Allocator, args: []const lang.value.Value) lang.eval.EvalError!lang.value.Value {
    const pin = pinFromArg(args) orelse
        return try lang.stdlib.makeErr(alloc, .{ .string = "invalid pin" });
    gpio_init(pin);
    gpio_set_dir(pin, false);
    return lang.stdlib.makeOk(alloc, .null_val);
}

fn cmdGpioHigh(alloc: std.mem.Allocator, args: []const lang.value.Value) lang.eval.EvalError!lang.value.Value {
    const pin = pinFromArg(args) orelse
        return try lang.stdlib.makeErr(alloc, .{ .string = "invalid pin" });
    gpio_put(pin, true);
    return lang.stdlib.makeOk(alloc, .null_val);
}

fn cmdGpioLow(alloc: std.mem.Allocator, args: []const lang.value.Value) lang.eval.EvalError!lang.value.Value {
    const pin = pinFromArg(args) orelse
        return try lang.stdlib.makeErr(alloc, .{ .string = "invalid pin" });
    gpio_put(pin, false);
    return lang.stdlib.makeOk(alloc, .null_val);
}

fn cmdGpioRead(alloc: std.mem.Allocator, args: []const lang.value.Value) lang.eval.EvalError!lang.value.Value {
    const pin = pinFromArg(args) orelse
        return try lang.stdlib.makeErr(alloc, .{ .string = "invalid pin" });
    return lang.stdlib.makeOk(alloc, .{ .bool_val = gpio_get(pin) });
}

fn cmdAdcRead(alloc: std.mem.Allocator, args: []const lang.value.Value) lang.eval.EvalError!lang.value.Value {
    const n = switch (args[0]) { .int => |v| v, else => return error.TypeError };
    if (!validChannel(n))
        return try lang.stdlib.makeErr(alloc, .{ .string = "invalid channel" });
    const ch: c_uint = @intCast(n);
    // ADC channels 0-3 map to GPIO 26-29; channel 4 is the temperature sensor.
    if (ch <= 3) adc_gpio_init(26 + ch);
    adc_select_input(ch);
    return lang.stdlib.makeOk(alloc, .{ .int = adc_read() });
}

const eval_commands: []const lang.eval.Command = &.{
    .{ .name = "echo",      .func = &cmdEcho      },
    .{ .name = "gpio-out",  .func = &cmdGpioOut   },
    .{ .name = "gpio-in",   .func = &cmdGpioIn    },
    .{ .name = "gpio-high", .func = &cmdGpioHigh  },
    .{ .name = "gpio-low",  .func = &cmdGpioLow   },
    .{ .name = "gpio-read", .func = &cmdGpioRead  },
    .{ .name = "adc-read",  .func = &cmdAdcRead   },
};

// ─── Bare REPL command dispatch ───────────────────────────────────────────────
// Handles multi-word hardware commands before the language parser sees the line.

fn parsePin(s: []const u8) ?c_uint {
    const n = std.fmt.parseInt(i64, s, 10) catch return null;
    return if (validPin(n)) @intCast(n) else null;
}

fn parseChannel(s: []const u8) ?c_uint {
    const n = std.fmt.parseInt(i64, s, 10) catch return null;
    return if (validChannel(n)) @intCast(n) else null;
}

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
        shell.repl.writeStr(run_io,
            "builtins: echo help reboot\r\n" ++
            "gpio:     gpio out|in <pin>   gpio set <pin> high|low   gpio get <pin>\r\n" ++
            "adc:      adc read <channel 0-4>\r\n" ++
            "expr cmds: gpio-out gpio-in gpio-high gpio-low gpio-read adc-read\r\n");
        return true;
    }

    if (std.mem.eql(u8, cmd, "reboot")) {
        shell.repl.writeStr(run_io, "rebooting...\r\n");
        run_io.flush();
        watchdog_reboot(0, 0, 100);
        while (true) {}
    }

    if (std.mem.eql(u8, cmd, "gpio")) {
        if (argv.len < 3) {
            shell.repl.writeStr(run_io,
                "usage: gpio out|in <pin>   gpio set <pin> high|low   gpio get <pin>\r\n");
            return true;
        }
        const sub = argv[1];
        if (std.mem.eql(u8, sub, "out") or std.mem.eql(u8, sub, "in")) {
            const pin = parsePin(argv[2]) orelse {
                shell.repl.writeStr(run_io, "error: invalid pin\r\n");
                return true;
            };
            gpio_init(pin);
            gpio_set_dir(pin, std.mem.eql(u8, sub, "out"));
            return true;
        }
        if (std.mem.eql(u8, sub, "get")) {
            const pin = parsePin(argv[2]) orelse {
                shell.repl.writeStr(run_io, "error: invalid pin\r\n");
                return true;
            };
            shell.repl.writeStr(run_io, if (gpio_get(pin)) "1\r\n" else "0\r\n");
            return true;
        }
        if (std.mem.eql(u8, sub, "set") and argv.len >= 4) {
            const pin = parsePin(argv[2]) orelse {
                shell.repl.writeStr(run_io, "error: invalid pin\r\n");
                return true;
            };
            const lvl = argv[3];
            const high = std.mem.eql(u8, lvl, "high") or std.mem.eql(u8, lvl, "1");
            const low  = std.mem.eql(u8, lvl, "low")  or std.mem.eql(u8, lvl, "0");
            if (!high and !low) {
                shell.repl.writeStr(run_io, "error: expected high|low|0|1\r\n");
                return true;
            }
            gpio_put(pin, high);
            return true;
        }
        shell.repl.writeStr(run_io,
            "usage: gpio out|in <pin>   gpio set <pin> high|low   gpio get <pin>\r\n");
        return true;
    }

    if (std.mem.eql(u8, cmd, "adc")) {
        if (argv.len < 3 or !std.mem.eql(u8, argv[1], "read")) {
            shell.repl.writeStr(run_io, "usage: adc read <channel 0-4>\r\n");
            return true;
        }
        const ch = parseChannel(argv[2]) orelse {
            shell.repl.writeStr(run_io, "error: invalid channel (0-4)\r\n");
            return true;
        };
        if (ch <= 3) adc_gpio_init(26 + ch);
        adc_select_input(ch);
        shell.repl.writeFmt(run_io, "{}\r\n", .{adc_read()});
        return true;
    }

    return false;
}

pub export fn shell_main() void {
    g_io = io;
    adc_init();
    var eval_fba = std.heap.FixedBufferAllocator.init(&eval_heap);
    var perm_fba = std.heap.FixedBufferAllocator.init(&perm_heap);
    shell.repl.run(io, &eval_fba, &perm_fba, eval_commands, &env_store, &runBuiltin);
}
