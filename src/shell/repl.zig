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

/// Maximum REPL input line length; readLine silently drops further bytes.
const max_line_len = 256;
/// Scratch buffer for writeFmt — bounds any single formatted write.
const write_fmt_buf_len = 512;
/// Bare platform commands take at most this many argv entries; extra
/// tokens are ignored.
const max_command_argv = 16;
/// Each int argument of a bare command is formatted into a buffer this long.
const max_int_arg_len = 32;

pub fn writeStr(io: Io, s: []const u8) void {
    io.write_bytes(s);
}

pub fn writeFmt(io: Io, comptime fmt: []const u8, args: anytype) void {
    var buf: [write_fmt_buf_len]u8 = undefined;
    const s = std.fmt.bufPrint(&buf, fmt, args) catch buf[0..];
    io.write_bytes(s);
}

/// Single user-facing error reporter: every pipeline error set coerces into
/// lang.errors.Error; the canonical messages live in lang/errors.zig.
fn reportError(io: Io, err: lang.errors.Error) void {
    writeFmt(io, "error: {s}\r\n", .{lang.errors.message(err)});
}

/// Re-tokenize `src` with the permanent allocator. Top-level `def` bindings
/// and `env!` writes outlive the per-line eval arena, so everything they
/// reference (token payloads, ident slices, any AST built from the tokens)
/// must survive eval_fba.reset() — hence the dupe + re-tokenize.
fn retokenizePerm(perm_alloc: std.mem.Allocator, src: []const u8) lang.errors.LexError![]const lang.lexer.Token {
    const perm_src = try perm_alloc.dupe(u8, src);
    return lang.lexer.tokenize(perm_alloc, perm_src);
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
    var line_buf: [max_line_len]u8 = undefined;
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
            reportError(io, err);
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
            const perm_toks = retokenizePerm(perm_alloc, trimmed) catch |err| {
                reportError(io, err);
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
                reportError(io, err);
                continue;
            };
            const perm_ctx = lang.eval.Ctx{
                .alloc     = perm_alloc,
                .commands  = commands,
                .env_store = env_store,
            };
            const val = lang.eval.eval(perm_ctx, val_node, top_frame) catch |err| {
                reportError(io, err);
                continue;
            };
            env_store.set(key, val) catch |err| {
                reportError(io, err);
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
            var argv_buf: [max_command_argv][]const u8 = undefined;
            var fmt_bufs: [max_command_argv][max_int_arg_len]u8 = undefined;
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
            reportError(io, err);
            continue;
        };

        // ── def: install persistent top-level binding ─────────────────────────────
        switch (node) {
            .def => {
                const perm_toks = retokenizePerm(perm_alloc, trimmed) catch |err| {
                    reportError(io, err);
                    continue;
                };
                const perm_node = lang.parser.parse(perm_alloc, perm_toks) catch |err| {
                    reportError(io, err);
                    continue;
                };
                const d = perm_node.def;
                const perm_ctx = lang.eval.Ctx{
                    .alloc     = perm_alloc,
                    .commands  = commands,
                    .env_store = env_store,
                };
                const val = lang.eval.eval(perm_ctx, d.val, top_frame) catch |err| {
                    reportError(io, err);
                    continue;
                };
                top_frame = top_frame.extend(perm_alloc, d.name, val) catch |err| {
                    reportError(io, err);
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
                    reportError(io, err);
                    continue;
                };
                printResult(io, eval_alloc, val);
                io.flush();
            },
        }
    }
}

// ─── Tests ────────────────────────────────────────────────────────────────────

const testing = std.testing;

/// Mock Io for tests. State must be module-level because the Io ABI uses
/// bare function pointers (`*const fn () ?u8`), which cannot capture state —
/// that is the contract the platform layer implements. The namespace keeps
/// the non-reentrancy contained: the Zig test runner executes tests serially,
/// and reset() runs at the start of every replRun, so the sharing is sound.
const TestIo = struct {
    var input:   []const u8 = &[_]u8{};
    var pos:     usize      = 0;
    var out_buf: [4096]u8   = undefined;
    var out_len: usize      = 0;

    // Static arenas — large enough for tests without overflowing the stack.
    var eval_heap: [16 * 1024]u8 = undefined;
    var perm_heap: [4 * 1024]u8  = undefined;

    fn reset(in: []const u8) void {
        input = in;
        pos = 0;
        out_len = 0;
    }

    fn readByte() ?u8 {
        if (pos >= input.len) return null;
        const b = input[pos]; pos += 1; return b;
    }
    fn writeBytes(s: []const u8) void {
        const n = @min(s.len, out_buf.len - out_len);
        @memcpy(out_buf[out_len..][0..n], s[0..n]);
        out_len += n;
    }
    fn flush() void {}
    fn dispatch(_: Io, _: []const []const u8) bool { return false; }

    const io: Io = .{ .read_byte = &readByte, .write_bytes = &writeBytes, .flush = &flush };

    fn output() []const u8 { return out_buf[0..out_len]; }
};

/// Feed `input` to a fresh REPL instance and return all output.
fn replRun(input: []const u8) []const u8 {
    TestIo.reset(input);
    var efba = std.heap.FixedBufferAllocator.init(&TestIo.eval_heap);
    var pfba = std.heap.FixedBufferAllocator.init(&TestIo.perm_heap);
    var store: lang.env.EnvStore = .{};
    run(TestIo.io, &efba, &pfba, &[_]lang.eval.Command{}, &store, &TestIo.dispatch);
    return TestIo.output();
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
