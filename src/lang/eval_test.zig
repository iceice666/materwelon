//! Black-box integration tests for the evaluator — every test goes through
//! the public pipeline (tokenize → parse → eval) via evalStr. Unit tests of
//! private functions stay inline in their own modules.
const std    = @import("std");
const lexer  = @import("lexer.zig");
const parser = @import("parser.zig");
const env    = @import("env.zig");
const value  = @import("value.zig");
const evalmod = @import("eval.zig");

const testing = std.testing;
const Value   = value.Value;
const Ctx     = evalmod.Ctx;
const Command = evalmod.Command;
const eval    = evalmod.eval;

var dummy_store: env.EnvStore = .{};

const no_commands: []const Command = &[_]Command{};

fn makeCtx(alloc: std.mem.Allocator) Ctx {
    return .{ .alloc = alloc, .commands = no_commands, .env_store = &dummy_store };
}

fn evalStr(alloc: std.mem.Allocator, src: []const u8) !Value {
    // No freeTokens: alloc is expected to be an arena; all memory is
    // released together when the caller deinits the arena.
    const tokens = try lexer.tokenize(alloc, src);
    const node = try parser.parse(alloc, tokens);
    return eval(makeCtx(alloc), node, &env.empty_frame);
}

test "eval integer" {
    var a = std.heap.ArenaAllocator.init(testing.allocator); defer a.deinit();
    const v = try evalStr(a.allocator(), "42");
    try testing.expectEqual(@as(i64, 42), v.int);
}

test "eval float" {
    var a = std.heap.ArenaAllocator.init(testing.allocator); defer a.deinit();
    const v = try evalStr(a.allocator(), "3.14");
    try testing.expectEqual(@as(f64, 3.14), v.float);
}

test "eval bool and null" {
    var a = std.heap.ArenaAllocator.init(testing.allocator); defer a.deinit();
    try testing.expect((try evalStr(a.allocator(), "true")).bool_val  == true);
    try testing.expect((try evalStr(a.allocator(), "false")).bool_val == false);
    try testing.expectEqual(Value.null_val, try evalStr(a.allocator(), "null"));
}

test "eval string" {
    var a = std.heap.ArenaAllocator.init(testing.allocator); defer a.deinit();
    const v = try evalStr(a.allocator(), "\"hello\"");
    try testing.expectEqualStrings("hello", v.string);
}

test "eval list" {
    var a = std.heap.ArenaAllocator.init(testing.allocator); defer a.deinit();
    const v = try evalStr(a.allocator(), "[1 2 3]");
    try testing.expectEqual(@as(usize, 3), v.list.len);
    try testing.expectEqual(@as(i64, 2),   v.list[1].int);
}

test "eval record field access" {
    var a = std.heap.ArenaAllocator.init(testing.allocator); defer a.deinit();
    const v = try evalStr(a.allocator(), "{x: 42}:x");
    try testing.expectEqual(@as(i64, 42), v.int);
}

test "eval missing field returns null" {
    var a = std.heap.ArenaAllocator.init(testing.allocator); defer a.deinit();
    const v = try evalStr(a.allocator(), "{x: 1}:y");
    try testing.expectEqual(Value.null_val, v);
}

test "eval addition" {
    var a = std.heap.ArenaAllocator.init(testing.allocator); defer a.deinit();
    const v = try evalStr(a.allocator(), "1 + 2");
    try testing.expectEqual(@as(i64, 3), v.int);
}

test "eval subtraction" {
    var a = std.heap.ArenaAllocator.init(testing.allocator); defer a.deinit();
    const v = try evalStr(a.allocator(), "10 - 3");
    try testing.expectEqual(@as(i64, 7), v.int);
}

test "eval multiplication" {
    var a = std.heap.ArenaAllocator.init(testing.allocator); defer a.deinit();
    const v = try evalStr(a.allocator(), "3 * 4");
    try testing.expectEqual(@as(i64, 12), v.int);
}

test "eval division" {
    var a = std.heap.ArenaAllocator.init(testing.allocator); defer a.deinit();
    const v = try evalStr(a.allocator(), "10 / 2");
    try testing.expectEqual(@as(i64, 5), v.int);
}

test "eval mod" {
    var a = std.heap.ArenaAllocator.init(testing.allocator); defer a.deinit();
    const v = try evalStr(a.allocator(), "7 mod 3");
    try testing.expectEqual(@as(i64, 1), v.int);
}

test "eval negation" {
    var a = std.heap.ArenaAllocator.init(testing.allocator); defer a.deinit();
    const v = try evalStr(a.allocator(), "-5");
    try testing.expectEqual(@as(i64, -5), v.int);
}

test "eval comparison" {
    var a = std.heap.ArenaAllocator.init(testing.allocator); defer a.deinit();
    const alloc = a.allocator();
    try testing.expect((try evalStr(alloc, "3 > 2")).bool_val  == true);
    try testing.expect((try evalStr(alloc, "2 > 3")).bool_val  == false);
    try testing.expect((try evalStr(alloc, "2 = 2")).bool_val  == true);
    try testing.expect((try evalStr(alloc, "2 != 3")).bool_val == true);
}

test "eval string concat" {
    var a = std.heap.ArenaAllocator.init(testing.allocator); defer a.deinit();
    const v = try evalStr(a.allocator(), "\"foo\" ++ \"bar\"");
    try testing.expectEqualStrings("foobar", v.string);
}

test "eval list concat" {
    var a = std.heap.ArenaAllocator.init(testing.allocator); defer a.deinit();
    const v = try evalStr(a.allocator(), "[1 2] ++ [3 4]");
    try testing.expectEqual(@as(usize, 4), v.list.len);
    try testing.expectEqual(@as(i64, 3),   v.list[2].int);
}

test "eval let binding" {
    var a = std.heap.ArenaAllocator.init(testing.allocator); defer a.deinit();
    const v = try evalStr(a.allocator(), "(let x 5 (x * 2))");
    try testing.expectEqual(@as(i64, 10), v.int);
}

test "eval if true branch" {
    var a = std.heap.ArenaAllocator.init(testing.allocator); defer a.deinit();
    const v = try evalStr(a.allocator(), "(if true 1 2)");
    try testing.expectEqual(@as(i64, 1), v.int);
}

test "eval if false branch" {
    var a = std.heap.ArenaAllocator.init(testing.allocator); defer a.deinit();
    const v = try evalStr(a.allocator(), "(if false 1 2)");
    try testing.expectEqual(@as(i64, 2), v.int);
}

test "eval lambda and apply" {
    var a = std.heap.ArenaAllocator.init(testing.allocator); defer a.deinit();
    const v = try evalStr(a.allocator(), "((fn [x] (x + 1)) 4)");
    try testing.expectEqual(@as(i64, 5), v.int);
}

test "eval closure captures lexical scope" {
    var a = std.heap.ArenaAllocator.init(testing.allocator); defer a.deinit();
    // (let n 10 ((fn [x] (x + n)) 5))  → 15
    const v = try evalStr(a.allocator(), "(let n 10 ((fn [x] (x + n)) 5))");
    try testing.expectEqual(@as(i64, 15), v.int);
}

test "eval do block" {
    var a = std.heap.ArenaAllocator.init(testing.allocator); defer a.deinit();
    const v = try evalStr(a.allocator(), "(do x <- 3 (x + 4))");
    try testing.expectEqual(@as(i64, 7), v.int);
}

test "eval and short-circuits on false" {
    var a = std.heap.ArenaAllocator.init(testing.allocator); defer a.deinit();
    const alloc = a.allocator();
    try testing.expect((try evalStr(alloc, "(and true true)")).bool_val  == true);
    try testing.expect((try evalStr(alloc, "(and true false)")).bool_val == false);
    try testing.expect((try evalStr(alloc, "(and false true)")).bool_val == false);
}

test "eval or short-circuits on true" {
    var a = std.heap.ArenaAllocator.init(testing.allocator); defer a.deinit();
    const alloc = a.allocator();
    try testing.expect((try evalStr(alloc, "(or false false)")).bool_val == false);
    try testing.expect((try evalStr(alloc, "(or true false)")).bool_val  == true);
}

test "eval pipe |>" {
    var a = std.heap.ArenaAllocator.init(testing.allocator); defer a.deinit();
    // 3 |> (* 2)  →  ((*) 2 3)  →  6
    const v = try evalStr(a.allocator(), "3 |> (* 2)");
    try testing.expectEqual(@as(i64, 6), v.int);
}

test "eval tail-call recursion (TCO)" {
    var a = std.heap.ArenaAllocator.init(testing.allocator); defer a.deinit();
    // Self-passing style (since `let` is not `letrec`).
    // f = fn self -> fn n -> fn acc -> if n=0 then acc else self self (n-1) (acc+n)
    // Call: ((f f 1000) 0)  — should not stack overflow with TCO.
    const src =
        \\(let f
        \\  (fn [self]
        \\    (fn [n]
        \\      (fn [acc]
        \\        (if (n = 0)
        \\          acc
        \\          (((self self) (n - 1)) (acc + n))))))
        \\  (((f f) 1000) 0))
    ;
    const v = try evalStr(a.allocator(), src);
    try testing.expectEqual(@as(i64, 500500), v.int);
}

test "eval error result propagates through pipe" {
    var a = std.heap.ArenaAllocator.init(testing.allocator); defer a.deinit();
    const alloc = a.allocator();
    // {err: "oops"} |> (* 2) — the closure receives an error record, short-circuits
    const v = try evalStr(alloc, "{err: \"oops\"} |> (* 2)");
    try testing.expect(v.isErr());
}

test "eval stdlib unary: count, first, rest" {
    var a = std.heap.ArenaAllocator.init(testing.allocator); defer a.deinit();
    const al = a.allocator();
    try testing.expectEqual(@as(i64, 3),   (try evalStr(al, "[1 2 3] |> count")).int);
    try testing.expectEqual(@as(i64, 1),   (try evalStr(al, "[1 2 3] |> first")).int);
    try testing.expectEqual(@as(usize, 2), (try evalStr(al, "[1 2 3] |> rest")).list.len);
}

test "eval stdlib binary: nth, append" {
    var a = std.heap.ArenaAllocator.init(testing.allocator); defer a.deinit();
    const al = a.allocator();
    try testing.expectEqual(@as(i64, 20),  (try evalStr(al, "[10 20 30] |> nth 1")).int);
    try testing.expectEqual(@as(usize, 3), (try evalStr(al, "[1 2] |> append 3")).list.len);
}

test "eval map HOF" {
    var a = std.heap.ArenaAllocator.init(testing.allocator); defer a.deinit();
    // map (* 2) [1 2 3] = [2 4 6]
    const v = try evalStr(a.allocator(), "[1 2 3] |> map (* 2)");
    try testing.expectEqual(@as(usize, 3), v.list.len);
    try testing.expectEqual(@as(i64, 4),   v.list[1].int);
}

test "eval filter HOF" {
    var a = std.heap.ArenaAllocator.init(testing.allocator); defer a.deinit();
    // filter (> 2) [1 2 3 4] — keeps elements where elem > 2
    const v = try evalStr(a.allocator(), "[1 2 3 4] |> filter (> 2)");
    try testing.expectEqual(@as(usize, 2), v.list.len);
    try testing.expectEqual(@as(i64, 3),   v.list[0].int);
}

test "eval fold HOF" {
    var a = std.heap.ArenaAllocator.init(testing.allocator); defer a.deinit();
    // Use (+) in parens so the pipe loop captures it (bare + would be seen as infix)
    const v = try evalStr(a.allocator(), "[1 2 3 4 5] |> fold (+) 0");
    try testing.expectEqual(@as(i64, 15), v.int);
}

test "eval on-err HOF" {
    var a = std.heap.ArenaAllocator.init(testing.allocator); defer a.deinit();
    const al = a.allocator();
    // ok value passes through unchanged
    const ok_result = try evalStr(al, "{ok: 42} |> on-err (fn [_] 0)");
    try testing.expect(ok_result.isErr() == false);
    // error value calls handler; handler returns 99
    const handled = try evalStr(al, "{err: \"oops\"} |> on-err (fn [_] 99)");
    try testing.expectEqual(@as(i64, 99), handled.int);
}

test "eval compose HOF" {
    var a = std.heap.ArenaAllocator.init(testing.allocator); defer a.deinit();
    // (compose (* 2) (+ 1)) 3  = (* 2) ((+ 1) 3) = (* 2) 4 = 8
    const v = try evalStr(a.allocator(), "((compose (* 2) (+ 1)) 3)");
    try testing.expectEqual(@as(i64, 8), v.int);
}

test "eval to-str stdlib" {
    var a = std.heap.ArenaAllocator.init(testing.allocator); defer a.deinit();
    const v = try evalStr(a.allocator(), "42 |> to-str");
    try testing.expectEqualStrings("42", v.string);
}

test "eval f! no placeholders" {
    var a = std.heap.ArenaAllocator.init(testing.allocator); defer a.deinit();
    const v = try evalStr(a.allocator(), "(f! \"hello\")");
    try testing.expectEqualStrings("hello", v.string);
}

test "eval f! one placeholder int" {
    var a = std.heap.ArenaAllocator.init(testing.allocator); defer a.deinit();
    const v = try evalStr(a.allocator(), "(f! \"x={}\" 42)");
    try testing.expectEqualStrings("x=42", v.string);
}

test "eval f! multiple placeholders" {
    var a = std.heap.ArenaAllocator.init(testing.allocator); defer a.deinit();
    const v = try evalStr(a.allocator(), "(f! \"{} + {} = {}\" 1 2 3)");
    try testing.expectEqualStrings("1 + 2 = 3", v.string);
}

test "eval f! with string arg" {
    var a = std.heap.ArenaAllocator.init(testing.allocator); defer a.deinit();
    const v = try evalStr(a.allocator(), "(f! \"hello, {}!\" \"world\")");
    try testing.expectEqualStrings("hello, world!", v.string);
}

test "eval format alias" {
    var a = std.heap.ArenaAllocator.init(testing.allocator); defer a.deinit();
    const v = try evalStr(a.allocator(), "(format \"val={}\" 99)");
    try testing.expectEqualStrings("val=99", v.string);
}

test "eval f! via pipe" {
    var a = std.heap.ArenaAllocator.init(testing.allocator); defer a.deinit();
    // 42 |> f! "n={}"  →  (f! "n={}") 42  →  "n=42"
    const v = try evalStr(a.allocator(), "42 |> f! \"n={}\"");
    try testing.expectEqualStrings("n=42", v.string);
}

test "eval f! error propagates through" {
    var a = std.heap.ArenaAllocator.init(testing.allocator); defer a.deinit();
    const v = try evalStr(a.allocator(), "{err: \"oops\"} |> f! \"val={}\"");
    try testing.expect(v.isErr());
}

test "eval do block multiple stmts and bindings" {
    var a = std.heap.ArenaAllocator.init(testing.allocator); defer a.deinit();
    const al = a.allocator();
    // plain expr discarded, two bindings, final expr
    const v = try evalStr(al, "(do 1 x <- 2 y <- (x + 3) (x * y))");
    try testing.expectEqual(@as(i64, 10), v.int);
}

test "eval and/or variadic 3-arg" {
    var a = std.heap.ArenaAllocator.init(testing.allocator); defer a.deinit();
    const al = a.allocator();
    try testing.expect((try evalStr(al, "(and true true true)")).bool_val  == true);
    try testing.expect((try evalStr(al, "(and true false true)")).bool_val == false);
    try testing.expect((try evalStr(al, "(or false false true)")).bool_val == true);
    try testing.expect((try evalStr(al, "(or false false false)")).bool_val == false);
}

test "eval and/or infix form" {
    var a = std.heap.ArenaAllocator.init(testing.allocator); defer a.deinit();
    const al = a.allocator();
    try testing.expect((try evalStr(al, "true and false")).bool_val == false);
    try testing.expect((try evalStr(al, "false or true")).bool_val  == true);
}

test "eval float arithmetic" {
    var a = std.heap.ArenaAllocator.init(testing.allocator); defer a.deinit();
    const al = a.allocator();
    try testing.expectApproxEqAbs(@as(f64, 2.0), (try evalStr(al, "1.5 + 0.5")).float, 1e-9);
    try testing.expectApproxEqAbs(@as(f64, 1.0), (try evalStr(al, "3.0 - 2.0")).float, 1e-9);
    try testing.expectApproxEqAbs(@as(f64, 6.0), (try evalStr(al, "2.0 * 3.0")).float, 1e-9);
    try testing.expectApproxEqAbs(@as(f64, 1.5), (try evalStr(al, "3.0 / 2.0")).float, 1e-9);
    // int + float promotes to float
    try testing.expectApproxEqAbs(@as(f64, 2.5), (try evalStr(al, "1 + 1.5")).float, 1e-9);
}

test "eval unary not" {
    var a = std.heap.ArenaAllocator.init(testing.allocator); defer a.deinit();
    const al = a.allocator();
    try testing.expect((try evalStr(al, "not true")).bool_val  == false);
    try testing.expect((try evalStr(al, "not false")).bool_val == true);
    try testing.expect((try evalStr(al, "not null")).bool_val  == true);
}

test "eval comparison ops !=, <=, >=" {
    var a = std.heap.ArenaAllocator.init(testing.allocator); defer a.deinit();
    const al = a.allocator();
    try testing.expect((try evalStr(al, "1 != 2")).bool_val  == true);
    try testing.expect((try evalStr(al, "2 != 2")).bool_val  == false);
    try testing.expect((try evalStr(al, "2 <= 2")).bool_val  == true);
    try testing.expect((try evalStr(al, "1 <= 2")).bool_val  == true);
    try testing.expect((try evalStr(al, "3 <= 2")).bool_val  == false);
    try testing.expect((try evalStr(al, "3 >= 2")).bool_val  == true);
    try testing.expect((try evalStr(al, "2 >= 2")).bool_val  == true);
    try testing.expect((try evalStr(al, "1 >= 2")).bool_val  == false);
}

test "eval map-ok HOF" {
    var a = std.heap.ArenaAllocator.init(testing.allocator); defer a.deinit();
    const al = a.allocator();
    // success: transforms inner value
    const ok_v = try evalStr(al, "{ok: 5} |> map-ok (* 2)");
    try testing.expectEqual(@as(i64, 10), ok_v.record[0].val.int);
    // error: passes through unchanged
    const err_v = try evalStr(al, "{err: \"boom\"} |> map-ok (* 2)");
    try testing.expect(err_v.isErr());
}

test "eval and-then HOF" {
    var a = std.heap.ArenaAllocator.init(testing.allocator); defer a.deinit();
    const al = a.allocator();
    // success: chains into the next result-returning fn
    const ok_v = try evalStr(al, "{ok: 4} |> and-then (fn [x] {ok: (x * 3)})");
    try testing.expectEqual(@as(i64, 12), ok_v.record[0].val.int);
    // error: short-circuits
    const err_v = try evalStr(al, "{err: \"e\"} |> and-then (fn [x] {ok: x})");
    try testing.expect(err_v.isErr());
}

test "eval flip HOF" {
    var a = std.heap.ArenaAllocator.init(testing.allocator); defer a.deinit();
    // (flip f 3 10) = f(10)(3); f = fn[x][y] x-y → 10-3 = 7
    const v = try evalStr(a.allocator(), "((flip (fn [x] (fn [y] x - y)) 3) 10)");
    try testing.expectEqual(@as(i64, 7), v.int);
}

test "eval pipe HOF" {
    var a = std.heap.ArenaAllocator.init(testing.allocator); defer a.deinit();
    // (pipe (+ 1) (* 2)) 3  = (* 2) ((+ 1) 3) = 8
    const v = try evalStr(a.allocator(), "((pipe (+ 1) (* 2)) 3)");
    try testing.expectEqual(@as(i64, 8), v.int);
}

test "eval identity and const" {
    var a = std.heap.ArenaAllocator.init(testing.allocator); defer a.deinit();
    const al = a.allocator();
    try testing.expectEqual(@as(i64, 42), (try evalStr(al, "(identity 42)")).int);
    try testing.expectEqual(@as(i64, 7),  (try evalStr(al, "((const 7) 99)")).int);
}

test "eval list reverse, flatten, zip, concat fn" {
    var a = std.heap.ArenaAllocator.init(testing.allocator); defer a.deinit();
    const al = a.allocator();
    const rev = try evalStr(al, "[1 2 3] |> reverse");
    try testing.expectEqual(@as(i64, 3), rev.list[0].int);
    const flat = try evalStr(al, "[[1 2] [3 4]] |> flatten");
    try testing.expectEqual(@as(usize, 4), flat.list.len);
    const zipped = try evalStr(al, "(zip [1 2] [3 4])");
    try testing.expectEqual(@as(usize, 2), zipped.list.len);
    const cat = try evalStr(al, "(concat [1 2] [3 4])");
    try testing.expectEqual(@as(usize, 4), cat.list.len);
}

test "eval record ops: keys, values, get, set, del, has, merge" {
    var a = std.heap.ArenaAllocator.init(testing.allocator); defer a.deinit();
    const al = a.allocator();
    try testing.expectEqual(@as(usize, 2), (try evalStr(al, "(keys {a: 1 b: 2})")).list.len);
    try testing.expectEqual(@as(usize, 2), (try evalStr(al, "(values {a: 1 b: 2})")).list.len);
    try testing.expectEqual(@as(i64, 1),   (try evalStr(al, "(get \"a\" {a: 1 b: 2})")).int);
    try testing.expect((try evalStr(al, "(get \"z\" {a: 1})")) == .null_val);
    try testing.expect((try evalStr(al, "(has \"a\" {a: 1})")).bool_val == true);
    try testing.expect((try evalStr(al, "(has \"z\" {a: 1})")).bool_val == false);
    const deleted = try evalStr(al, "(del \"a\" {a: 1 b: 2})");
    try testing.expectEqual(@as(usize, 1), deleted.record.len);
    const updated = try evalStr(al, "(set \"a\" 99 {a: 1 b: 2})");
    try testing.expectEqual(@as(i64, 99), updated.record[0].val.int);
    const merged = try evalStr(al, "(merge {a: 1} {b: 2})");
    try testing.expectEqual(@as(usize, 2), merged.record.len);
}

test "eval string ops: str-join, str-split, str-concat" {
    var a = std.heap.ArenaAllocator.init(testing.allocator); defer a.deinit();
    const al = a.allocator();
    const joined = try evalStr(al, "(str-join \",\" [\"a\" \"b\" \"c\"])");
    try testing.expectEqualStrings("a,b,c", joined.string);
    const split = try evalStr(al, "(str-split \",\" \"a,b,c\")");
    try testing.expectEqual(@as(usize, 3), split.list.len);
    // data-last: (str-concat suffix data) = data ++ suffix
    const cat = try evalStr(al, "(str-concat \" world\" \"hello\")");
    try testing.expectEqualStrings("hello world", cat.string);
}

test "eval ok/err constructors and ok?/err?/unwrap" {
    var a = std.heap.ArenaAllocator.init(testing.allocator); defer a.deinit();
    const al = a.allocator();
    const ok_v = try evalStr(al, "(ok 42)");
    try testing.expect(!ok_v.isErr());
    try testing.expect((try evalStr(al, "(ok? (ok 1))")).bool_val  == true);
    try testing.expect((try evalStr(al, "(err? (err \"e\"))")).bool_val == true);
    try testing.expect((try evalStr(al, "(ok? (err \"e\"))")).bool_val == false);
    const unwrapped = try evalStr(al, "(unwrap (ok 7))");
    try testing.expectEqual(@as(i64, 7), unwrapped.int);
}

test "eval to-int and to-float" {
    var a = std.heap.ArenaAllocator.init(testing.allocator); defer a.deinit();
    const al = a.allocator();
    try testing.expectEqual(@as(i64, 42),   (try evalStr(al, "(to-int \"42\")")).int);
    try testing.expect((try evalStr(al, "(to-int \"bad\")")) == .null_val);
    try testing.expectApproxEqAbs(@as(f64, 3.14), (try evalStr(al, "(to-float \"3.14\")")).float, 1e-9);
}

test "eval chained field access" {
    var a = std.heap.ArenaAllocator.init(testing.allocator); defer a.deinit();
    // cfg:server:port — (cfg:server):port
    const v = try evalStr(a.allocator(),
        "(let cfg {server: {host: \"rpi\" port: 8080}} cfg:server:port)");
    try testing.expectEqual(@as(i64, 8080), v.int);
}
