// REPL loop — platform-agnostic, driven entirely through Io.
const std = @import("std");
const lang = @import("../lang/root.zig");
const Io = @import("root.zig").Io;

/// Called per command: returns true if the command was handled.
pub const Dispatch = *const fn (io: Io, argv: []const []const u8) bool;

pub fn writeStr(io: Io, s: []const u8) void {
    io.write_bytes(s);
}

pub fn writeFmt(io: Io, comptime fmt: []const u8, args: anytype) void {
    var buf: [512]u8 = undefined;
    const s = std.fmt.bufPrint(&buf, fmt, args) catch buf[0..];
    io.write_bytes(s);
}

fn readLine(io: Io, buf: []u8) ?[]u8 {
    var i: usize = 0;
    while (true) {
        const ch = io.read_byte() orelse return null;
        switch (ch) {
            '\r', '\n' => {
                io.write_bytes("\r\n");
                return buf[0..i];
            },
            127, 8 => {
                if (i > 0) {
                    i -= 1;
                    io.write_bytes("\x08 \x08");
                }
            },
            else => {
                if (i < buf.len - 1) {
                    buf[i] = ch;
                    i += 1;
                    io.write_bytes(buf[i - 1 .. i]);
                }
            },
        }
    }
}

/// Main REPL loop. `fba` is reset between commands so the heap never exhausts.
pub fn run(io: Io, fba: *std.heap.FixedBufferAllocator, dispatch: Dispatch) void {
    writeStr(io, "\r\nmaterwelon shell — RP2350\r\ntype 'help' for commands\r\n\n");
    var line_buf: [256]u8 = undefined;

    while (true) {
        fba.reset();
        const alloc = fba.allocator();

        writeStr(io, "$ ");
        io.flush();

        const line = readLine(io, &line_buf) orelse continue;
        const trimmed = std.mem.trim(u8, line, " \t");
        if (trimmed.len == 0) continue;

        const argv = lang.lexer.tokenize(alloc, trimmed) catch {
            writeStr(io, "error: out of memory\r\n");
            continue;
        };
        if (argv.len == 0) continue;

        if (!dispatch(io, argv)) {
            writeFmt(io, "{s}: command not found\r\n", .{argv[0]});
        }

        io.flush();
    }
}
