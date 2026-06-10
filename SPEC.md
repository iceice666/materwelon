# Materwelon Shell Language Specification

**Status**: Draft  
**Target**: RP2350 bare metal, 64 KB heap, USB CDC serial I/O  
**Implementation language**: Zig

---

## 1. Design Goals

- **Minimal**: as few primitives as possible; everything else is stdlib
- **Structured data**: pipelines carry typed values, not text strings
- **Functional**: immutable values, curried pure functions, higher-order composition
- **Two callable classes**: pure functions (curried, no effects) and commands (variadic, effectful)
- **Infix operators**: limited set of symbolic infix operators, all curried, all data-last
- **Embedded-aware**: bounded memory, deterministic allocation, full TCO

---

## 2. Values and Types

### Numeric types

| Type     | Description                         | Literal examples     |
|----------|-------------------------------------|----------------------|
| `int`    | 64-bit signed integer               | `42`, `-7`, `0`      |
| `float`  | 64-bit IEEE 754 double              | `3.14`, `-0.5`       |
| `number` | Arbitrary-precision integer/decimal | `42N`, `3.14N`       |

A bare integer literal is `int`. A literal with `.` and no `N` suffix is `float`.
The `N` suffix produces `number`. Mixed arithmetic promotes: `int` + `float` → `float`,
anything + `number` → `number`.

> **Platform note**: On RP2350, `number` is implemented as a software bignum within
> the 64 KB heap. Very large values may exhaust the heap. Small `number` values
> (fitting in 128 bits) are efficient.

### Other primitive types

| Type    | Literals             | Notes            |
|---------|----------------------|------------------|
| `string`| `"hello"`, `"a\nb"`  | UTF-8            |
| `bool`  | `true`, `false`      |                  |
| `null`  | `null`               | absence of value |

### Compound types

| Type    | Literal syntax                  | Notes                           |
|---------|---------------------------------|---------------------------------|
| `list`  | `[1 2 3]`, `[]`                 | ordered, heterogeneous          |
| `record`| `{name: "alice" age: 30}`, `{}` | string-keyed, unordered         |

Record keys in literals are bare names — `{age: 30}` not `{"age": 30}`.

### Function type

Pure functions are first-class values. Commands are not function values.

---

## 3. Syntax

### 3.1 Comments

```
; this is a line comment
```

### 3.2 Literals

As defined in §2. Whitespace separates items inside `[...]` and `{...}`.

### 3.3 Function Application (prefix)

```
(f a)         ; apply f to a
(f a b)       ; curried: ((f a) b)
(f a b c)     ; (((f a) b) c)
```

Named functions always use prefix form. There are no zero-parameter functions.

### 3.4 Infix Operators

A fixed set of symbolic operators may appear infix. Infix is syntactic sugar;
all operators are curried functions and can be partially applied.

**Operator precedence** (lowest to highest):

| Level | Operators                   | Associativity | Notes                       |
|-------|-----------------------------|---------------|-----------------------------|
| 0     | `\|>`                       | left          | pipe forward                |
| 1     | `or`                        | left          | special form, short-circuit |
| 2     | `and`                       | left          | special form, short-circuit |
| 3     | `=` `!=` `<` `>` `<=` `>=`  | non-assoc     | no chaining                 |
| 4     | `++`                        | left          | concat (string and list)    |
| 5     | `+` `-`                     | left          | additive                    |
| 6     | `*` `/` `mod`               | left          | multiplicative              |
| 7     | unary `-` `not`             | prefix        |                             |
| 8     | `:`                         | left          | field access                |

No other infix operators. User-defined functions always use prefix application.

### 3.5 Data-last infix desugaring

All binary operators follow a **data-last convention**:
- The **right operand** is the "modifier" — the first curried argument.
- The **left operand** is the "data" — the last curried argument.

```
a op b   ≡   (op b a)
```

This makes partial application always produce a useful transformer or predicate:

```
(> 5)       ; fn data -> data > 5       ("greater than 5")
(< 10)      ; fn data -> data < 10      ("less than 10")
(+ 1)       ; fn data -> data + 1       ("add 1")
(- 1)       ; fn data -> data - 1       ("subtract 1")
(* 2)       ; fn data -> data * 2       ("double")
(/ 2)       ; fn data -> data / 2       ("halve")
(++ [0])    ; fn data -> data ++ [0]    ("append 0")
(:name)     ; fn data -> data:name      ("get field name")
```

Infix `a op b` evaluates correctly because `(op b a)` with the data-last definition
gives `a op b`:

```
5 > 3   ≡   (> 3 5)   ≡   5 > 3   ≡   true
5 - 3   ≡   (- 3 5)   ≡   5 - 3   ≡   2
```

> **Note for prefix usage with two known arguments**: write infix for clarity.
> `(op b a)` is surprising to read directly — it means "`a op b`" — so prefer
> the infix form when both operands are present.

### 3.6 Field Access Operator `:`

`:` accesses a named field of a record. The right operand is a literal identifier,
not an evaluated expression.

```
r:name              ; get field "name" from r
config:server:port  ; left-associative chain: (config:server):port
```

Desugars as `a:b` → `(: b a)` (data-last). Partial form `(:name)` is a getter:
```
people |> map (:name)     ; extract "name" field from each record
```

If the field does not exist, the result is `null`.

### 3.7 Pipe Operator `|>`

`|>` passes the left-hand value into the **last curried slot** of the right-hand
expression. This is symmetric with all pure functions, which take data last.

```
val |> f          ≡   (f val)
val |> f a        ≡   (f a val)      ; val fills the last slot
a |> f |> g       ≡   (g (f a))
```

`|>` has the lowest precedence, so the full left expression is evaluated first:
```
a + b |> to-str   ≡   (to-str (a + b))
```

### 3.8 Special Forms

| Form                     | Meaning                                             |
|--------------------------|-----------------------------------------------------|
| `(def name val)`         | Bind `name` in the top-level environment            |
| `(fn [params] body)`     | Anonymous function; see §4.1                        |
| `(let x val body)`       | Bind `x` to `val` within `body` only               |
| `(if cond then else)`    | Conditional; evaluates only the taken branch        |
| `(do ...)`               | Sequence of expressions; see §3.9                   |

`and` and `or` are also special forms (§6).

### 3.9 `do` Blocks

`do` sequences expressions. The block's value is the value of the last expression.

```
(do
  expr1        ; evaluated for effect; result discarded
  expr2
  expr3)       ; block returns this
```

`<-` inside `do` binds an expression's result for the remainder of the block.
It is only valid inside `do`.

```
(do
  x <- (adc read 0)
  y <- (adc read 1)
  (echo (f! "avg: {}" (/ (x + y) 2))))
```

Desugaring: each `<-` threads the remainder of the block as a `let` body:
```
(do
  x <- e1
  e2)
≡
(let x e1 e2)
```

Plain expressions (without `<-`) bind to `_` (discarded):
```
(do
  (echo "starting")     ; ≡  (let _ (echo "starting") ...)
  x <- (adc read 0)
  x)
```

---

## 4. Pure Functions

### 4.1 Lambda

```
(fn [x] body)           ; single parameter
(fn [x y] body)         ; sugar; desugars to (fn [x] (fn [y] body))
(fn [x y z] body)       ; desugars to (fn [x] (fn [y] (fn [z] body)))
```

All multi-param lambdas desugar to curried single-param lambdas at parse time.

### 4.2 Closures

Lambdas capture their lexical environment by value. Captured bindings are immutable.

### 4.3 Immutability

All values are immutable. `let` and `def` create new bindings; they never overwrite
in place. An inner `let` binding shadows but does not destroy the outer binding.

### 4.4 Tail-Call Optimization

Full TCO is guaranteed for **all tail positions**:
- Self-recursive tail calls
- Mutual tail calls between top-level functions
- Tail calls in `if` branches, `let` bodies, and `do` blocks

The implementation must trampoline or otherwise eliminate stack growth in all these
positions.

```
(def loop
  (fn [n acc]
    (if (= n 0)
      acc
      (loop (n - 1) (acc + n)))))    ; tail call — O(1) stack

(loop 1000000 0)    ; safe
```

---

## 5. Commands

### 5.1 What commands are

Commands are firmware-registered callables: variadic, effectful, not curried,
not first-class values. Current builtins: `echo`, `help`, `reboot`.

### 5.2 Registration

Registered at firmware compile time. No runtime registration, no PATH lookup.

```zig
const builtins = [_]Command{
    .{ .name = "echo",   .fn = cmd_echo   },
    .{ .name = "gpio",   .fn = cmd_gpio   },
    .{ .name = "reboot", .fn = cmd_reboot },
};
```

### 5.3 Invocation syntax

A command is invoked by a bare name not bound in scope, followed by zero or more
evaluated argument expressions:

```
echo "hello"
gpio set 1 high
adc read 0
```

Commands are **not** wrapped in `(...)`. Wrapping in parens triggers function
application — if the name is not a bound function, this is a runtime error.

### 5.4 Return values

Commands return a result record: `{ok: value}` on success (use `{ok: null}` for
effect-only commands), or `{err: "message"}` on failure. The same convention as
pure functions — there is one unified error type (see §8).

### 5.5 Commands in pipelines

The piped value fills the **last** argument position, symmetric with pure functions:

```
adc read 0 |> echo "reading:"
; ≡  echo "reading:" <adc-result>    — piped value is last
```

---

## 6. Boolean Operators

`and` and `or` are **variadic special forms** accepting 2 or more arguments.
They evaluate left-to-right and short-circuit at the first decisive value.

```
(and a b)        ; if a is falsy, return a; else return b
(and a b c d)    ; left-to-right: stops and returns first falsy; else returns d
(or a b)         ; if a is truthy, return a; else return b
(or a b c d)     ; left-to-right: stops and returns first truthy; else returns d
(not x)          ; boolean negation — a regular function, not a special form
```

Infix `a and b` desugars to `(and a b)` — **standard left-to-right** argument order
(not data-last). This is an exception to §3.5: `and`/`or` are special forms, not
operator functions, so data-last partial application does not apply.

```
x > 0 and x < 100
a or b or c          ; ≡ (or a b c) via left-assoc parse → (or (or a b) c) → same semantics
```

Falsy values: `false`, `null`. Everything else is truthy (including `0`, `""`).
An error result `{err: ...}` is falsy (see §8).

`and` and `or` cannot be passed as values or partially applied.

---

## 7. String Formatting

```
(format "temp: {} deg" val)      ; positional placeholder
(f! "coords: ({}, {})" x y)      ; shorthand alias — same semantics
```

`{}` placeholders are filled left-to-right from the remaining arguments, each
converted via `(to-str x)`.

No string interpolation in literals. All dynamic string construction uses `format`/`f!`.

---

## 8. Error Handling

Both pure functions and commands use a single unified mechanism: **result records**.

### 8.1 Result records

A result record is a record with exactly one of two shapes:

```
{ok: value}        ; success — value is any type, including null
{err: "message"}   ; failure — message is a string
```

`ok` and `err` are conventional keys. Any record that has an `err` key and no `ok`
key is treated as an error result by the pipeline and stdlib helpers.

Pure functions signal errors explicitly:

```
(def safe-div
  (fn [a b]
    (if (= b 0)
      {err: "division by zero"}
      {ok: (/ a b)})))

(safe-div 10 2):ok      ; 5
(safe-div 10 0):err     ; "division by zero"
```

Commands return `{ok: val}` or `{err: "msg"}`. Effect-only commands return `{ok: null}`.

### 8.2 Pipeline short-circuit

`|>` inspects each intermediate value before passing it to the next stage. If the
value is an error result — a record with `err` key and no `ok` key — the remainder
of the pipeline is **skipped** and the error result propagates to the end.

```
adc read 0             ; returns {ok: 512} or {err: "invalid pin"}
|> map-ok (* 2)        ; skipped on {err:...}
|> map-ok (+ 100)      ; skipped on {err:...}
; final value: {ok: 1124} or {err: "invalid pin"}
```

At the REPL top level, an error result is printed as an error to serial:
```
adc read 99    ; prints: error: invalid pin
```

### 8.3 Stdlib helpers

```
(unwrap r)        ; extract r:ok, or halt + print r:err to serial
(on-err f r)      ; (string -> a) -> result -> a  — call f with message on error
(map-ok f r)      ; (a -> b) -> result -> result  — transform :ok value, pass errors
(and-then f r)    ; (a -> result) -> result -> result  — chain result-returning fn
(ok? r)           ; result -> bool
(err? r)          ; result -> bool
(ok val)          ; a -> {ok: val}      — construct a success result
(err msg)         ; string -> {err: msg} — construct an error result
```

`(ok val)` and `(err msg)` are stdlib functions (not special forms) that construct
result records. They are the conventional way to return results without writing
record literals.

---

## 9. Mutable Environment (`env`)

`env` is the single mutable global key-value store. It cannot be rebound with
`def` or `let`.

### 9.1 Reading `env`

`env` reads use the `:` field access operator and return the value or `null`:

```
env:HOST       ; string or null
env:BAUD       ; int or null
```

`env` reads are **effectful** (reading mutable state). They are therefore restricted
by scope:

- **REPL / top-level expression context**: `env` is always in scope.
- **Inside a `do` block**: `env` is in scope.
- **Inside a function body without an enclosing `do`**: `env` is **not in scope** —
  a compile error.
- **Inside a lambda body, even if the lambda is defined inside a `do`**: `env` is
  **not in scope**. Lambdas are pure functions; capture the value explicitly.

```
; OK — top level
env:BAUD

; OK — inside do
(do
  baud <- env:BAUD
  (echo baud))

; ERROR — function body, no do
(def f (fn [x] (x + env:OFFSET)))

; CORRECT — capture env value in do, pass to function
(def f (fn [offset x] (x + offset)))
(do
  offset <- env:OFFSET
  (f offset 42))

; ERROR — lambda inside do, env still not accessible inside lambda body
(do
  result <- (map (fn [x] x + env:OFFSET) [1 2 3]))

; CORRECT — read env before the lambda
(do
  offset <- env:OFFSET
  result <- (map (fn [x] x + offset) [1 2 3])
  result)
```

### 9.2 Writing `env`

Use the `env!` command. Commands are always effectful, so `env!` is valid at
top-level and inside `do` blocks.

```
env! HOST "rpi.local"
env! BAUD 115200
```

`env!` takes a bare key name (not a string literal) and a value expression.
Keys are stored as strings. Firmware sets initial values at startup.

---

## 10. Core Standard Library

All pure functions. All follow data-last convention.

### Arithmetic
```
(+ a b)    (- a b)    (* a b)    (/ a b)    (mod a b)    (neg x)
```

### Comparison
```
(= a b)   (!= a b)   (< a b)   (> a b)   (<= a b)   (>= a b)
```

### List operations
```
(map f xs)           ; (a -> b) -> [a] -> [b]
(filter pred xs)     ; (a -> bool) -> [a] -> [a]
(fold f init xs)     ; (b -> a -> b) -> b -> [a] -> b
(first xs)           ; [a] -> a | null
(rest xs)            ; [a] -> [a]
(count xs)           ; [a] -> int
(append xs x)        ; [a] -> a -> [a]
(concat xs ys)       ; [a] -> [a] -> [a]      (also: xs ++ ys)
(nth n xs)           ; int -> [a] -> a | null
(reverse xs)         ; [a] -> [a]
(flatten xs)         ; [[a]] -> [a]
(zip xs ys)          ; [a] -> [b] -> [{fst: a snd: b}]
```

### Record operations
```
(get k r)            ; string -> record -> value | null
(set k v r)          ; string -> a -> record -> record    (new record)
(del k r)            ; string -> record -> record
(has k r)            ; string -> record -> bool
(keys r)             ; record -> [string]
(values r)           ; record -> [any]
(merge r1 r2)        ; record -> record -> record         (r2 wins on conflict)
```

### String operations
```
(str-len s)          ; string -> int
(str-join sep xs)    ; string -> [string] -> string
(str-split sep s)    ; string -> string -> [string]
(str-concat a b)     ; string -> string -> string         (also: a ++ b)
(to-str x)           ; any -> string
(to-int s)           ; string -> int | null
(to-float s)         ; string -> float | null
(to-number s)        ; string -> number | null
```

### Result helpers (§8)
```
(ok val)             ; a -> {ok: val}
(err msg)            ; string -> {err: msg}
(unwrap r)           ; result -> a            (halts + prints on {err:...})
(on-err f r)         ; (string -> a) -> result -> a
(map-ok f r)         ; (a -> b) -> result -> result
(and-then f r)       ; (a -> result) -> result -> result
(ok? r)              ; result -> bool
(err? r)             ; result -> bool
```

### Higher-order utilities
```
(identity x)
(const x _)          ; always returns x — ignores second arg
(flip f a b)         ; (f b a)
(compose f g)        ; fn x -> (f (g x))    — right-to-left
(pipe f g)           ; fn x -> (g (f x))    — left-to-right
```

---

## 11. Evaluation Model

1. **Parse** input into an AST.
2. **Desugar**: `|>`, `(fn [...] ...)`, `<-` in `do`, infix operators (`a op b` → `(op b a)`).
3. **Evaluate** in the current environment:
   - Literals → themselves.
   - Names → look up environment chain; if unbound, check command table.
   - `(f a)` → evaluate `f` and `a`, apply.
   - Special forms → per their rules.
4. **TCO**: tail calls in all tail positions are trampolined.
5. **Print** the top-level result to serial. `{ok: val}` displays as `val`; `{err: msg}` displays as `error: msg`; `null` is silent.
6. **Free** all heap allocations from this evaluation cycle (allocator reset).

---

## 12. Memory Model

64 KB fixed-buffer heap. Allocator resets between REPL top-level evaluations.

- Strings, lists, records: heap-allocated.
- Closures: heap-allocated; captured variables copied at creation.
- `number` bignums: heap-allocated.
- Pipeline intermediates: freed when consumed by the next stage (linear ownership).
- TCO trampolining must not grow the heap per iteration.
- `env` lives in a dedicated static buffer outside the main heap.

---

## 13. Resolved Design Decisions (summary)

All open questions are closed. Key decisions for implementors:

| Decision | Resolution |
|----------|-----------|
| Number literals | `42` int, `3.14` float, `42N` / `3.14N` number |
| Missing field (`:`) | Returns `null` |
| Error type | Unified result records `{ok:...}` / `{err:...}` — no separate error primitive |
| Pipe slot | Last argument; `b \|> f a` ≡ `(f a b)` |
| Operator currying | All symbol operators are curried; `a op b` ≡ `(op b a)` (data-last) |
| `and`/`or` desugaring | Standard left-to-right: `a and b` ≡ `(and a b)` |
| `and`/`or` arity | Variadic, 2+ arguments, left-to-right short-circuit |
| Chained comparisons | Not supported; use `(and (< a x) (< x b))` |
| `++` | Concat for both strings and lists |
| `number` on RP2350 | Software bignum; small values efficient, large values may exhaust heap |
| `env` scope | In scope at REPL/top-level and inside `do` blocks; not in function bodies |
| TCO | Full — all tail positions, trampolined |

---

## Appendix A: Syntax Grammar (informal)

```
program      ::= toplevel*
toplevel     ::= def-form | expr

def-form     ::= "(" "def" name expr ")"

expr         ::= literal
               | name
               | list-lit
               | record-lit
               | app
               | special
               | do-block
               | infix-expr
               | command-invocation

literal      ::= int-lit | float-lit | number-lit | string-lit
               | "true" | "false" | "null"

int-lit      ::= ["-"] [0-9]+
float-lit    ::= ["-"] [0-9]+ "." [0-9]+
number-lit   ::= ["-"] [0-9]+ "N"
               | ["-"] [0-9]+ "." [0-9]+ "N"

list-lit     ::= "[" expr* "]"
record-lit   ::= "{" (name ":" expr)* "}"

app          ::= "(" expr expr* ")"

special      ::= "(" "fn"  "[" name+ "]" expr ")"
               | "(" "let" name expr expr ")"
               | "(" "if"  expr expr expr ")"
               | "(" "and" expr expr+ ")"
               | "(" "or"  expr expr+ ")"

do-block     ::= "(" "do" do-stmt* ")"
do-stmt      ::= name "<-" expr      ; binding — only inside do
               | expr

infix-expr   ::= expr op expr
               | expr ":" name        ; field access — right side is literal name
               | "-" expr             ; unary negation
               | "not" expr           ; unary boolean not

op           ::= "|>" | "or" | "and"
               | "=" | "!=" | "<" | ">" | "<=" | ">="
               | "++" | "+" | "-" | "*" | "/" | "mod"

command-invocation ::= name expr*    ; name unbound in scope, found in command table

name         ::= [a-zA-Z_][a-zA-Z0-9_-]*
               | [+\-*/=<>!?]+        ; operator names in prefix position
```

---

## Appendix B: Example session

```
; field access
(def pin {id: 1 mode: "output" state: false})
pin:state                ; false
pin:id                   ; 1

; chained field access
(def cfg {server: {host: "rpi" port: 8080}})
cfg:server:port          ; 8080

; partial application of operators as predicates
[1 2 3 4 5] |> filter (> 2)        ; [3 4 5]   — "greater than 2"
[1 2 3 4 5] |> map (* 2)           ; [2 4 6 8 10]

; point-free field extraction
[{name: "a" val: 1} {name: "b" val: 2}]
|> map (:name)                     ; ["a" "b"]

; ++ concatenation
"hello" ++ " " ++ "world"          ; "hello world"
[1 2] ++ [3 4]                     ; [1 2 3 4]

; do block with <- bindings
(do
  a <- (adc read 0)
  b <- (adc read 1)
  (echo (f! "sum: {}" (a + b))))

; pure function result record
(def safe-div
  (fn [a b]
    (if (= b 0)
      {err: "div by zero"}
      {ok: (a / b)})))

(safe-div 10 2) |> unwrap           ; 5
(safe-div 10 0) |> on-err echo      ; prints "div by zero"

; command error propagation (result record short-circuit)
adc read 99                         ; returns {err: "invalid pin"}
|> map-ok (* 2)                     ; skipped — {err:...} propagates
|> map-ok (+ 100)                   ; skipped
; final value {err: "invalid pin"} printed as: error: invalid pin

; and/or variadic
(and (> x 0) (< x 100) (= (mod x 2) 0))   ; x is positive, < 100, and even
(or ready? (fallback) (default-val))        ; first truthy wins

; env scoping
env:BAUD                            ; OK at top level
(do
  baud <- env:BAUD                  ; OK inside do
  (echo baud))

; recursion with full TCO
(def sum-to
  (fn [n acc]
    (if (= n 0)
      acc
      (sum-to (n - 1) (acc + n)))))

(sum-to 100000 0)                   ; 5000050000 — no stack overflow

; env write (command — valid at top level and in do blocks)
env! BAUD 9600
```
