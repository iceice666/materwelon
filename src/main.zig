/// Shell entry point for RP2350 bare metal.
/// I/O is routed through pico-sdk stdio (USB CDC on port 2).
const std = @import("std");
const parse = @import("parse.zig");

// pico-sdk stdio — use the concrete (non-inline) symbols
extern fn stdio_putchar_raw(c: c_int) c_int;
extern fn stdio_getchar_timeout_us(timeout_us: u32) c_int;
extern fn stdio_flush() void;

// pico-sdk watchdog for soft reboot
extern fn watchdog_reboot(pc: u32, sp: u32, delay_ms: u32) void;

var heap: [64 * 1024]u8 = undefined;

fn writeStr(s: []const u8) void {
    for (s) |c| _ = stdio_putchar_raw(c);
}

fn writeFmt(comptime fmt: []const u8, args: anytype) void {
    var buf: [512]u8 = undefined;
    const s = std.fmt.bufPrint(&buf, fmt, args) catch buf[0..];
    writeStr(s);
}

/// Read one line from USB CDC into buf, echoing input. Returns slice or null on error.
fn readLine(buf: []u8) ?[]u8 {
    var i: usize = 0;
    while (true) {
        const c = stdio_getchar_timeout_us(0xFFFF_FFFF);
        if (c < 0) return null;
        const ch: u8 = @intCast(c & 0xFF);
        switch (ch) {
            '\r', '\n' => {
                writeStr("\r\n");
                return buf[0..i];
            },
            127, 8 => { // backspace / DEL
                if (i > 0) {
                    i -= 1;
                    writeStr("\x08 \x08");
                }
            },
            else => {
                if (i < buf.len - 1) {
                    buf[i] = ch;
                    i += 1;
                    _ = stdio_putchar_raw(ch); // echo
                }
            },
        }
    }
}

fn runBuiltin(argv: []const []const u8) bool {
    const cmd = argv[0];

    if (std.mem.eql(u8, cmd, "echo")) {
        for (argv[1..], 0..) |arg, i| {
            if (i > 0) writeStr(" ");
            writeStr(arg);
        }
        writeStr("\r\n");
        return true;
    }

    if (std.mem.eql(u8, cmd, "help")) {
        writeStr("builtins: echo help reboot\r\n");
        return true;
    }

    if (std.mem.eql(u8, cmd, "reboot")) {
        writeStr("rebooting...\r\n");
        stdio_flush();
        watchdog_reboot(0, 0, 100);
        while (true) {}
    }

    return false;
}

pub export fn shell_main() void {
    writeStr("\r\nmaterwelon shell — RP2350\r\ntype 'help' for commands\r\n\n");

    var fba = std.heap.FixedBufferAllocator.init(&heap);
    var line_buf: [256]u8 = undefined;

    while (true) {
        // reset allocator between commands so we never exhaust the heap
        fba.reset();
        const alloc = fba.allocator();

        writeStr("$ ");
        stdio_flush();

        const line = readLine(&line_buf) orelse continue;
        const trimmed = std.mem.trim(u8, line, " \t");
        if (trimmed.len == 0) continue;

        const argv = parse.tokenize(alloc, trimmed) catch {
            writeStr("error: out of memory\r\n");
            continue;
        };

        if (argv.len == 0) continue;

        if (!runBuiltin(argv)) {
            writeFmt("{s}: command not found\r\n", .{argv[0]});
        }

        stdio_flush();
    }
}
