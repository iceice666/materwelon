// REPL loop — platform-agnostic, driven entirely through Io.
const std = @import("std");
const lang = @import("lang");

/// Platform-agnostic I/O interface — filled in by the platform layer.
pub const Io = struct {
    read_byte:   *const fn () ?u8,
    write_bytes: *const fn ([]const u8) void,
    flush:       *const fn () void,
};

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

/// Print a result value per SPEC §11:
/// null    → silent
/// {err:m} → "error: m\r\n"
/// {ok: v} → print v recursively
/// other   → toStr, then print
fn printResult(io: Io, alloc: std.mem.Allocator, v: lang.value.Value) void {
    switch (v) {
        .null_val => return,
        .record => |fields| {
            if (v.isErr()) {
                var msg: []const u8 = "error";
                for (fields) |f| {
                    if (std.mem.eql(u8, f.key, "err")) {
                        msg = switch (f.val) {
                            .string => |s| s,
                            else    => "error",
                        };
                        break;
                    }
                }
                writeFmt(io, "error: {s}\r\n", .{msg});
                return;
            }
            // {ok: val} — unwrap and print the inner value
            for (fields) |f| {
                if (std.mem.eql(u8, f.key, "ok")) {
                    printResult(io, alloc, f.val);
                    return;
                }
            }
            // Plain record: fall through to toStr
        },
        else => {},
    }
    const str = lang.stdlib.toStr(alloc, v) catch {
        writeStr(io, "error: out of memory\r\n");
        return;
    };
    writeFmt(io, "{s}\r\n", .{str.string});
}

/// Main REPL loop.
/// eval_fba is reset between commands; perm_fba holds top-level defs.
pub fn run(
    io:        Io,
    eval_fba:  *std.heap.FixedBufferAllocator,
    perm_fba:  *std.heap.FixedBufferAllocator,
    commands:  []const lang.eval.Command,
    env_store: *lang.env.EnvStore,
    dispatch:  Dispatch,
) void {
    writeStr(io, "\r\nmaterwelon shell — RP2350\r\ntype 'help' for commands\r\n\n");
    var line_buf: [256]u8 = undefined;
    const perm_alloc = perm_fba.allocator();
    var top_frame: *const lang.env.Frame = &lang.env.empty_frame;

    while (true) {
        eval_fba.reset();
        const eval_alloc = eval_fba.allocator();

        writeStr(io, "$ ");
        io.flush();

        const line = readLine(io, &line_buf) orelse return;
        const trimmed = std.mem.trim(u8, line, " \t");
        if (trimmed.len == 0) continue;

        const tokens = lang.lexer.tokenize(eval_alloc, trimmed) catch |err| {
            switch (err) {
                error.UnexpectedChar     => writeStr(io, "error: unexpected character\r\n"),
                error.UnterminatedString => writeStr(io, "error: unterminated string\r\n"),
                error.InvalidEscape      => writeStr(io, "error: invalid escape sequence\r\n"),
                error.NumberOverflow     => writeStr(io, "error: number out of range\r\n"),
                else                     => writeStr(io, "error: out of memory\r\n"),
            }
            continue;
        };
        defer lang.lexer.freeTokens(eval_alloc, tokens);
        if (tokens.len == 0 or tokens[0] == .Eof) continue;

        // ── env! KEY expr ────────────────────────────────────────────────────────
        // Handled before dispatch: needs env_store and expression evaluation.
        const is_env_bang: bool = switch (tokens[0]) {
            .Ident => |n| std.mem.eql(u8, n, "env!"),
            else => false,
        };
        if (is_env_bang) {
            // Re-tokenize with perm_alloc so key/value strings survive reset.
            const perm_src = perm_alloc.dupe(u8, trimmed) catch {
                writeStr(io, "error: out of memory\r\n");
                continue;
            };
            const perm_toks = lang.lexer.tokenize(perm_alloc, perm_src) catch {
                writeStr(io, "error: out of memory\r\n");
                continue;
            };
            if (perm_toks.len < 3) {
                writeStr(io, "error: env! requires a key and value\r\n");
                continue;
            }
            const key: []const u8 = switch (perm_toks[1]) {
                .Ident => |k| k,
                else   => {
                    writeStr(io, "error: env! key must be a bare name\r\n");
                    continue;
                },
            };
            // Parse perm_toks[2..] as the value expression (includes trailing Eof).
            const val_node = lang.parser.parse(perm_alloc, perm_toks[2..]) catch |err| {
                switch (err) {
                    error.UnexpectedToken => writeStr(io, "error: unexpected token\r\n"),
                    error.UnexpectedEof   => writeStr(io, "error: unexpected end of input\r\n"),
                    error.ExpectedIdent   => writeStr(io, "error: expected identifier\r\n"),
                    error.EmptyFnParams   => writeStr(io, "error: empty fn params\r\n"),
                    error.OutOfMemory     => writeStr(io, "error: out of memory\r\n"),
                }
                continue;
            };
            const perm_ctx = lang.eval.Ctx{
                .alloc     = perm_alloc,
                .commands  = commands,
                .env_store = env_store,
            };
            const val = lang.eval.eval(perm_ctx, val_node, top_frame) catch |err| {
                switch (err) {
                    error.UnboundName    => writeStr(io, "error: unbound name\r\n"),
                    error.TypeError      => writeStr(io, "error: type error\r\n"),
                    error.DivisionByZero => writeStr(io, "error: division by zero\r\n"),
                    error.OutOfMemory    => writeStr(io, "error: out of memory\r\n"),
                }
                continue;
            };
            env_store.set(key, val) catch |err| {
                switch (err) {
                    error.KeyTooLong => writeStr(io, "error: env key too long\r\n"),
                    error.StoreFull  => writeStr(io, "error: env store full\r\n"),
                }
                continue;
            };
            // env! is silent on success
            continue;
        }

        // ── Bare command dispatch ─────────────────────────────────────────────────
        // If the first token is an ident not known to stdlib, try the platform
        // dispatch before parsing.  Dispatch returns true if it handled the command.
        const first_is_command: bool = switch (tokens[0]) {
            .Ident => |n| !lang.stdlib.isStdlib(n),
            else => false,
        };
        if (first_is_command) {
            var argv_buf: [16][]const u8 = undefined;
            var fmt_bufs: [16][32]u8     = undefined;
            var argc: usize = 0;
            for (tokens) |tok| {
                if (argc >= argv_buf.len) break;
                switch (tok) {
                    .Eof        => break,
                    .Ident      => |s| { argv_buf[argc] = s;       argc += 1; },
                    .Lit_String => |s| { argv_buf[argc] = s;       argc += 1; },
                    .Lit_True   =>     { argv_buf[argc] = "true";  argc += 1; },
                    .Lit_False  =>     { argv_buf[argc] = "false"; argc += 1; },
                    .Lit_Null   =>     { argv_buf[argc] = "null";  argc += 1; },
                    .Lit_Int    => |n| {
                        const s = std.fmt.bufPrint(&fmt_bufs[argc], "{}", .{n}) catch break;
                        argv_buf[argc] = s; argc += 1;
                    },
                    else => break,
                }
            }
            if (argc > 0 and dispatch(io, argv_buf[0..argc])) continue;
        }

        // ── Parse ─────────────────────────────────────────────────────────────────
        const node = lang.parser.parse(eval_alloc, tokens) catch |err| {
            switch (err) {
                error.UnexpectedToken => writeStr(io, "error: unexpected token\r\n"),
                error.UnexpectedEof   => writeStr(io, "error: unexpected end of input\r\n"),
                error.ExpectedIdent   => writeStr(io, "error: expected identifier\r\n"),
                error.EmptyFnParams   => writeStr(io, "error: empty fn params\r\n"),
                error.OutOfMemory     => writeStr(io, "error: out of memory\r\n"),
            }
            continue;
        };

        // ── def: install persistent top-level binding ─────────────────────────────
        switch (node) {
            .def => {
                // Re-tokenize and re-parse with perm_alloc: all AST nodes,
                // string literals, and ident slices must survive eval_fba.reset().
                const perm_src = perm_alloc.dupe(u8, trimmed) catch {
                    writeStr(io, "error: out of memory\r\n");
                    continue;
                };
                const perm_toks = lang.lexer.tokenize(perm_alloc, perm_src) catch {
                    writeStr(io, "error: out of memory\r\n");
                    continue;
                };
                const perm_node = lang.parser.parse(perm_alloc, perm_toks) catch {
                    writeStr(io, "error: unexpected\r\n");
                    continue;
                };
                const d = perm_node.def;
                const perm_ctx = lang.eval.Ctx{
                    .alloc     = perm_alloc,
                    .commands  = commands,
                    .env_store = env_store,
                };
                const val = lang.eval.eval(perm_ctx, d.val, top_frame) catch |err| {
                    switch (err) {
                        error.UnboundName    => writeStr(io, "error: unbound name\r\n"),
                        error.TypeError      => writeStr(io, "error: type error\r\n"),
                        error.DivisionByZero => writeStr(io, "error: division by zero\r\n"),
                        error.OutOfMemory    => writeStr(io, "error: out of memory\r\n"),
                    }
                    continue;
                };
                top_frame = top_frame.extend(perm_alloc, d.name, val) catch {
                    writeStr(io, "error: out of memory\r\n");
                    continue;
                };
                // def is silent
            },

            // ── All other expressions ─────────────────────────────────────────────
            else => {
                const ctx = lang.eval.Ctx{
                    .alloc     = eval_alloc,
                    .commands  = commands,
                    .env_store = env_store,
                };
                const val = lang.eval.eval(ctx, node, top_frame) catch |err| {
                    switch (err) {
                        error.UnboundName    => writeStr(io, "error: unbound name\r\n"),
                        error.TypeError      => writeStr(io, "error: type error\r\n"),
                        error.DivisionByZero => writeStr(io, "error: division by zero\r\n"),
                        error.OutOfMemory    => writeStr(io, "error: out of memory\r\n"),
                    }
                    continue;
                };
                printResult(io, eval_alloc, val);
                io.flush();
            },
        }
    }
}

// ─── Tests ────────────────────────────────────────────────────────────────────
//
// Mock Io uses module-level state so plain function pointers can capture it.
// Tests are sequential; state is reset at the start of each replRun call.

const testing = std.testing;

var t_input:    []const u8 = &[_]u8{};
var t_pos:      usize      = 0;
var t_out_buf:  [4096]u8   = undefined;
var t_out_len:  usize      = 0;

// Static arenas — large enough for tests without overflowing the stack.
var t_eval_heap: [16 * 1024]u8 = undefined;
var t_perm_heap: [4  * 1024]u8 = undefined;

fn tRead() ?u8 {
    if (t_pos >= t_input.len) return null;
    const b = t_input[t_pos]; t_pos += 1; return b;
}
fn tWrite(s: []const u8) void {
    const n = @min(s.len, t_out_buf.len - t_out_len);
    @memcpy(t_out_buf[t_out_len..][0..n], s[0..n]);
    t_out_len += n;
}
fn tFlush() void {}
fn tDispatch(_: Io, _: []const []const u8) bool { return false; }

const t_io: Io = .{ .read_byte = &tRead, .write_bytes = &tWrite, .flush = &tFlush };

/// Feed `input` to a fresh REPL instance and return all output.
fn replRun(input: []const u8) []const u8 {
    t_input  = input;
    t_pos    = 0;
    t_out_len = 0;
    var efba = std.heap.FixedBufferAllocator.init(&t_eval_heap);
    var pfba = std.heap.FixedBufferAllocator.init(&t_perm_heap);
    var store: lang.env.EnvStore = .{};
    run(t_io, &efba, &pfba, &[_]lang.eval.Command{}, &store, &tDispatch);
    return t_out_buf[0..t_out_len];
}

/// Assert that running `input` produces output containing `want`.
fn replContains(input: []const u8, want: []const u8) !void {
    const out = replRun(input);
    if (std.mem.indexOf(u8, out, want) == null) {
        std.debug.print("\nexpected output to contain: {s}\ngot: {s}\n", .{ want, out });
        return error.TestUnexpectedResult;
    }
}

test "repl eval integer" {
    try replContains("42\r\n", "42\r\n");
}

test "repl eval arithmetic" {
    try replContains("1 + 2\r\n", "3\r\n");
}

test "repl eval string literal" {
    try replContains("\"hello\"\r\n", "hello\r\n");
}

test "repl null is silent" {
    const out = replRun("null\r\n");
    // echo contributes one "null\r\n"; result must not add a second
    try testing.expectEqual(@as(usize, 1), std.mem.count(u8, out, "null\r\n"));
}

test "repl error result" {
    try replContains("{err: \"oops\"}\r\n", "error: oops\r\n");
}

test "repl ok result unwraps" {
    try replContains("{ok: 42}\r\n", "42\r\n");
}

test "repl def persists across lines" {
    try replContains("def x 10\r\nx\r\n", "10\r\n");
}

test "repl division by zero error" {
    try replContains("1 / 0\r\n", "error: division by zero\r\n");
}

test "repl unbound name error" {
    try replContains("undefined_var\r\n", "error: unbound name\r\n");
}

test "repl f! formatting" {
    try replContains("(f! \"n={}\" 42)\r\n", "n=42\r\n");
}

test "repl env! write and read" {
    try replContains("env! FOO 99\r\nenv:FOO\r\n", "99\r\n");
}
