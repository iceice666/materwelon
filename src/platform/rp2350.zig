//! RP2350 platform — pico-sdk stdio glue + GPIO/ADC hardware commands.
//! This is the Zig root compiled by CMake (firmware/CMakeLists.txt); it
//! exports shell_main for firmware/main.c. Host development uses host.zig
//! (`zig build run`) instead.
const std   = @import("std");
const shell = @import("shell");
const lang  = @import("lang");
const servo = lang.servo;

// ─── pico-sdk externs ─────────────────────────────────────────────────────────

extern fn stdio_putchar_raw(c: c_int) c_int;
extern fn stdio_getchar_timeout_us(timeout_us: u32) c_int;
extern fn stdio_flush() void;
extern fn watchdog_reboot(pc: u32, sp: u32, delay_ms: u32) void;

// GPIO (hardware/gpio.h). gpio_init is a real SDK symbol; the rest are
// static inline in the SDK headers, so firmware/main.c exports shim_*
// wrappers with real linkage for them.
extern fn gpio_init(gpio: c_uint) void;
extern fn shim_gpio_set_dir(gpio: c_uint, out: bool) void;
extern fn shim_gpio_put(gpio: c_uint, value: bool) void;
extern fn shim_gpio_get(gpio: c_uint) bool;
const gpio_set_dir = shim_gpio_set_dir;
const gpio_put     = shim_gpio_put;
const gpio_get     = shim_gpio_get;

// ADC (hardware/adc.h) — same shim arrangement; adc_init is real.
extern fn adc_init() void;
extern fn shim_adc_gpio_init(gpio: c_uint) void;
extern fn shim_adc_select_input(input: c_uint) void;
extern fn shim_adc_read() u16;
const adc_gpio_init    = shim_adc_gpio_init;
const adc_select_input = shim_adc_select_input;
const adc_read         = shim_adc_read;

// Servo UART (hardware/uart.h) — shims in firmware/main.c because uart1 is a
// macro in the pico-sdk headers and cannot be referenced from Zig directly.
extern fn shim_servo_init(tx_pin: c_uint, rx_pin: c_uint, baud: c_uint) void;
extern fn shim_servo_write_blocking(buf: [*]const u8, len: usize) void;

// micro-ROS (firmware/uros.c) — only linked when ENABLE_MICROROS is set.
// Declared unconditionally so the Zig source compiles either way; the linker
// will error if they are referenced without ENABLE_MICROROS.
extern fn uros_init() void;
extern fn uros_spin_forever() noreturn;

// ─── Servo UART defaults ──────────────────────────────────────────────────────
// UART1 GP4 (TX) / GP5 (RX), 115200 baud — the LewanSoul bus default.
// TX-only in practice (write-only half-duplex), but RX pin is routed so the
// UART peripheral doesn't complain about missing RX.
const servo_tx_pin:  c_uint = 4;
const servo_rx_pin:  c_uint = 5;
const servo_baud:    c_uint = 115200;

// ─── Memory budget ────────────────────────────────────────────────────────────
// RP2350 has 520 KB SRAM total; the SPEC budgets 64 KB for the language heap.

/// Per-expression arena; reset before every REPL turn. Sized so deep
/// recursion and list-building intermediates fit in one evaluation.
const eval_heap_len = 48 * 1024;
/// Holds top-level `def` bindings, their re-parsed ASTs, and closures;
/// never reset for the lifetime of the session.
const perm_heap_len = 16 * 1024;

// ─── Hardware limits ──────────────────────────────────────────────────────────

/// RP2350 QFN-60 package exposes GPIO 0..29.
const max_gpio_pin = 29;
/// ADC channels 0..3 map to GPIO 26..29; channel 4 is the temperature sensor.
const max_adc_channel = 4;
const adc_channel_0_gpio = 26;

// ─── Allocators and state ─────────────────────────────────────────────────────

var eval_heap: [eval_heap_len]u8 = undefined;
var perm_heap: [perm_heap_len]u8 = undefined;

var env_store: lang.env.EnvStore = .{};

// Io handle stored at startup so eval.Commands can write output.
var g_io: shell.Io = undefined;

// Servo UART is lazily initialised on the first servo command.
var servo_ready: bool = false;

// ─── micro-ROS state ──────────────────────────────────────────────────────────
// Sized for 18 servo records ({id, pos}) plus list/frame overhead.
const uros_msg_heap_len = 8 * 1024;
var uros_msg_heap: [uros_msg_heap_len]u8 = undefined;
var uros_msg_fba: std.heap.FixedBufferAllocator = undefined;

/// Handler closure installed by (uros-on-traj h).
/// MUST point into perm_fba (i.e. the user must `def` the function first).
var uros_handler: ?lang.value.Value = null;

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

fn validPin(n: i64) bool    { return n >= 0 and n <= max_gpio_pin; }
fn validChannel(n: i64) bool { return n >= 0 and n <= max_adc_channel; }

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

// ─── Servo helpers ────────────────────────────────────────────────────────────

/// Ensure UART1 is initialised; idempotent.
fn ensureServo() void {
    if (!servo_ready) {
        shim_servo_init(servo_tx_pin, servo_rx_pin, servo_baud);
        servo_ready = true;
    }
}

/// Extract a record field value by name, or return null.
fn recordField(fields: []const lang.value.Value.Field, key: []const u8) ?lang.value.Value {
    for (fields) |f| {
        if (std.mem.eql(u8, f.key, key)) return f.val;
    }
    return null;
}

fn cmdAdcRead(alloc: std.mem.Allocator, args: []const lang.value.Value) lang.eval.EvalError!lang.value.Value {
    const n = switch (args[0]) { .int => |v| v, else => return error.TypeError };
    if (!validChannel(n))
        return try lang.stdlib.makeErr(alloc, .{ .string = "invalid channel" });
    const ch: c_uint = @intCast(n);
    if (ch < max_adc_channel) adc_gpio_init(adc_channel_0_gpio + ch);
    adc_select_input(ch);
    return lang.stdlib.makeOk(alloc, .{ .int = adc_read() });
}

/// (servo-move {id: N pos: DEG})
/// Moves servo with the given ID to DEG degrees (0–240) at max speed.
/// Both `id` (1–253) and `pos` (float or int) are required record fields.
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
            return try lang.stdlib.makeErr(alloc, .{ .string = "servo-move: id out of range (1-253)" }),
        else => return try lang.stdlib.makeErr(alloc, .{ .string = "servo-move: id must be an int" }),
    };
    const deg: f32 = switch (pos_val) {
        .float => |v| @floatCast(v),
        .int   => |v| @floatFromInt(v),
        else   => return try lang.stdlib.makeErr(alloc, .{ .string = "servo-move: pos must be a number" }),
    };

    ensureServo();
    const pkt = servo.buildMovePacket(id, deg);
    shim_servo_write_blocking(&pkt, pkt.len);
    return lang.stdlib.makeOk(alloc, .null_val);
}

/// (servo-torque {id: N on: BOOL})
/// Enables (on=true) or disables (on=false) torque/hold on the given servo.
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
            return try lang.stdlib.makeErr(alloc, .{ .string = "servo-torque: id out of range (1-253)" }),
        else => return try lang.stdlib.makeErr(alloc, .{ .string = "servo-torque: id must be an int" }),
    };
    const on: bool = switch (on_val) {
        .bool_val => |b| b,
        else      => return try lang.stdlib.makeErr(alloc, .{ .string = "servo-torque: on must be bool" }),
    };

    ensureServo();
    const pkt = servo.buildTorquePacket(id, on);
    shim_servo_write_blocking(&pkt, pkt.len);
    return lang.stdlib.makeOk(alloc, .null_val);
}

/// (uros-on-traj handler)
/// Registers a materwelon closure to be called on each incoming
/// /servo_trajectory message.  The handler receives a list of
/// {id: N pos: DEG} records (id = joint index + 1, pos = degrees).
///
/// IMPORTANT: the handler MUST be installed via a top-level `def` before
/// calling (uros-on-traj ...).  Inline fn literals are allocated in the
/// per-line eval arena; they will be freed before the micro-ROS executor
/// ever calls them.  Example:
///
///   (def handle-traj (fn [positions] (map servo-move positions)))
///   (uros-on-traj handle-traj)
///   uros start
fn cmdUrosOnTraj(alloc: std.mem.Allocator, args: []const lang.value.Value) lang.eval.EvalError!lang.value.Value {
    switch (args[0]) {
        .closure => {},
        else     => return try lang.stdlib.makeErr(alloc,
            .{ .string = "uros-on-traj: argument must be a closure (use def first)" }),
    }
    uros_handler = args[0];
    return lang.stdlib.makeOk(alloc, .null_val);
}

/// Called from firmware/uros.c's traj_cb with the positions array and count.
/// Builds a materwelon list of {id, pos} records and applies uros_handler.
/// All allocations come from uros_msg_fba (reset each call) — completely
/// separate from the REPL arenas so the REPL state is undisturbed.
pub export fn uros_dispatch(positions: [*]const f64, n: usize) void {
    const handler = uros_handler orelse return;
    const c = switch (handler) { .closure => |cl| cl, else => return };

    uros_msg_fba.reset();
    const msg_alloc = uros_msg_fba.allocator();

    // Build list of {id: N pos: DEG} records.
    const records = msg_alloc.alloc(lang.value.Value, n) catch return;
    for (records, 0..) |*rec, i| {
        const fields = msg_alloc.alloc(lang.value.Value.Field, 2) catch return;
        fields[0] = .{ .key = "id",  .val = .{ .int = @intCast(i + 1) } };
        fields[1] = .{ .key = "pos", .val = .{ .float = positions[i] } };
        rec.* = .{ .record = fields };
    }
    const list_val = lang.value.Value{ .list = records };

    // Apply closure: extend the closure's own frame with (param → list) and
    // evaluate the body.  eval.applyVal is private, so we replicate the
    // trampoline entry: extend frame + eval body directly.
    const new_frame = c.frame.extend(msg_alloc, c.param, list_val) catch return;
    const ctx = lang.eval.Ctx{
        .alloc     = msg_alloc,
        .commands  = eval_commands,
        .env_store = &env_store,
    };
    _ = lang.eval.eval(ctx, c.body, new_frame) catch |err| {
        g_io.write_bytes("uros: handler error: ");
        g_io.write_bytes(lang.errors.message(err));
        g_io.write_bytes("\r\n");
        g_io.flush();
    };
}

const eval_commands: []const lang.eval.Command = &.{
    .{ .name = "echo",         .func = &cmdEcho        },
    .{ .name = "gpio-out",     .func = &cmdGpioOut     },
    .{ .name = "gpio-in",      .func = &cmdGpioIn      },
    .{ .name = "gpio-high",    .func = &cmdGpioHigh    },
    .{ .name = "gpio-low",     .func = &cmdGpioLow     },
    .{ .name = "gpio-read",    .func = &cmdGpioRead    },
    .{ .name = "adc-read",     .func = &cmdAdcRead     },
    .{ .name = "servo-move",   .func = &cmdServoMove   },
    .{ .name = "servo-torque", .func = &cmdServoTorque },
    .{ .name = "uros-on-traj", .func = &cmdUrosOnTraj  },
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
            "servo:    servo move <id> <deg>   servo torque <id> on|off\r\n" ++
            "uros:     uros start  (blocks until reboot; set handler first)\r\n" ++
            "expr cmds: gpio-out gpio-in gpio-high gpio-low gpio-read adc-read\r\n" ++
            "           servo-move {id:N pos:DEG}   servo-torque {id:N on:BOOL}\r\n" ++
            "           uros-on-traj <closure>\r\n");
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
        if (ch < max_adc_channel) adc_gpio_init(adc_channel_0_gpio + ch);
        adc_select_input(ch);
        shell.repl.writeFmt(run_io, "{}\r\n", .{adc_read()});
        return true;
    }

    if (std.mem.eql(u8, cmd, "servo")) {
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
            ensureServo();
            const pkt = servo.buildMovePacket(@intCast(id_n), deg_n);
            shim_servo_write_blocking(&pkt, pkt.len);
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
            const on = std.mem.eql(u8, on_str, "on") or std.mem.eql(u8, on_str, "1");
            const off = std.mem.eql(u8, on_str, "off") or std.mem.eql(u8, on_str, "0");
            if (!on and !off) {
                shell.repl.writeStr(run_io, "error: expected on|off|0|1\r\n");
                return true;
            }
            ensureServo();
            const pkt = servo.buildTorquePacket(@intCast(id_n), on);
            shim_servo_write_blocking(&pkt, pkt.len);
            return true;
        }

        shell.repl.writeStr(run_io,
            "usage: servo move <id> <deg>   servo torque <id> on|off\r\n");
        return true;
    }

    if (std.mem.eql(u8, cmd, "uros")) {
        if (argv.len < 2 or !std.mem.eql(u8, argv[1], "start")) {
            shell.repl.writeStr(run_io, "usage: uros start\r\n");
            return true;
        }
        if (uros_handler == null) {
            shell.repl.writeStr(run_io,
                "error: no handler registered — use (uros-on-traj h) first\r\n");
            return true;
        }
        shell.repl.writeStr(run_io, "starting micro-ROS executor (reboot to exit)\r\n");
        run_io.flush();
        uros_init();
        uros_spin_forever();
    }

    return false;
}

pub export fn shell_main() void {
    g_io = io;
    uros_msg_fba = std.heap.FixedBufferAllocator.init(&uros_msg_heap);
    adc_init();
    var eval_fba = std.heap.FixedBufferAllocator.init(&eval_heap);
    var perm_fba = std.heap.FixedBufferAllocator.init(&perm_heap);
    shell.repl.run(io, &eval_fba, &perm_fba, eval_commands, &env_store, &runBuiltin);
}
