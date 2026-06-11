# materwelon Shell Language — User Manual

materwelon is a minimal pure-functional scripting REPL that runs bare-metal on the
RP2350 (Raspberry Pi Pico 2). You type expressions and commands over a serial
connection; the board evaluates them and prints the result. It is designed for
controlling hardware (GPIO, ADC, servos) from a structured language, including
from ROS 2 callbacks.

---

## Connecting

Connect at **115200 baud, 8N1**.

The default build (`ENABLE_MICROROS=OFF`) routes the console to **UART0** — pin
**GP0 = TX** (output from Pico) and **GP1 = RX** (input to Pico). There is no
native USB-CDC in the default build. You need a USB-to-UART adapter connected
to GP0 and GP1; depending on its chip it will appear as `/dev/ttyACM0`,
`/dev/ttyUSB0`, or similar.

```
picocom -b 115200 /dev/ttyUSB0    # typical FTDI / CH340 adapter
# or
minicom -D /dev/ttyUSB0 -b 115200
```

The board greets you with:

```
materwelon shell
type 'help' for commands

$
```

Type `help` to see the hardware command summary at any time. Press **Backspace**
to delete the previous character. Lines are capped at **256 bytes**; extra input
is silently dropped.

> **Firmware note (ENABLE_MICROROS=ON).** Builds compiled with
> `ENABLE_MICROROS=ON` enable USB-CDC, but it is consumed by the micro-ROS agent
> transport — the REPL console **still stays on UART0** (GP0/GP1). The
> USB-CDC port is only used by the `ros2 run micro_ros_agent` process on the host.

---

## How the REPL works

Every line you type is dispatched in this order:

1. **`env!` write** — lines starting with `env!` update the persistent key-value
   store (see [The env store](#the-env-store)). Silent on success.
2. **Bare hardware command** — if the first token of the line is an identifier
   that is not a stdlib name AND the platform recognises it, the whole line is
   split into argv tokens and dispatched to the hardware command handler.
   First-word examples: `gpio`, `adc`, `servo`, `uros`, `echo`, `help`, `reboot`.
   Lines starting with keywords (`if`, `let`, `fn`, `and`, …) or with a literal
   or opening paren always skip this path and go straight to (3).
3. **Language expression** — everything else is parsed and evaluated. The result is
   printed according to these rules:
   - `null` → **silent** (nothing printed)
   - `{ok: v}` → prints **`v`** (the result record is unwrapped)
   - `{err: "msg"}` → prints **`error: msg`**
   - anything else → printed via `to-str`

`def` bindings and `env!` writes persist across lines. All other values are
freed at the end of every line evaluation.

---

## Values and Types

### Primitive types

| Type | Literals | Notes |
|------|----------|-------|
| `int` | `0`, `42`, `-7` | 64-bit signed |
| `float` | `3.14`, `-0.5`, `1.0` | 64-bit IEEE 754 double; requires a digit on both sides of `.` |
| `string` | `"hello"`, `""` | UTF-8; see escapes below |
| `bool` | `true`, `false` | |
| `null` | `null` | absence of value; prints silently |

**String escapes:** `\n` `\t` `\r` `\\` `\"` `\0` — only these six are valid;
anything else is a lex error.

> ⚠️ **`number` / `N` suffix is reserved and not yet usable.**
> `42N`, `3.14N` lex and parse without error but the type has no working
> arithmetic. Any operation on a `number` value produces `error: type error`.
> Do not use it.

### Compound types

| Type | Literal | Notes |
|------|---------|-------|
| `list` | `[1 2 3]`, `[]` | ordered; heterogeneous; space-separated |
| `record` | `{name: "alice" age: 30}`, `{}` | string-keyed, unordered; bare-name keys, no commas |

String values inside records and lists print **without quotes** — `to-str` on
a string returns the string itself.

```
$ {name: "alice" age: 30}
{name: alice age: 30}

$ [1 "two" true null]
[1 two true null]
```

---

## Syntax basics

### Comments
```
; this is a line comment — from ; to end of line
42   ; inline comment
```
No block comments.

### Function application
```
(f a)         ; apply f to a
(f a b)       ; curried: same as ((f a) b)
(f a b c)     ; same as (((f a) b) c)
```
Functions are **always** applied in prefix form (inside parens) or via the pipe
operator. There are no zero-argument functions.

### Infix operators

A fixed set of symbols may appear infix. They are **all** curried functions
and follow **data-last** ordering (see below).

**Precedence, low to high:**

| Precedence | Operators | Notes |
|-----------|-----------|-------|
| lowest | `\|>` | pipe forward |
| | `or` | short-circuit (special form) |
| | `and` | short-circuit (special form) |
| | `=` `!=` `<` `>` `<=` `>=` | comparisons |
| | `++` | concat strings or lists |
| | `+` `-` | additive |
| | `*` `/` `mod` | multiplicative |
| | unary `-` `not` | prefix only |
| highest | `:` | field access |

### Data-last desugaring

**This is the most important rule for reading and writing materwelon.**

All infix binary expressions desugar to `(op right-operand left-operand)`:

```
a + b   ≡   (+ b a)
a > b   ≡   (> b a)
a ++ b  ≡   (++ b a)
```

The **right** operand becomes the **first** (modifier) curried argument; the
**left** operand becomes the **last** (data) argument. This means:

- Infix `5 > 3` reads as "5 is greater than 3" ✓ (evaluates correctly)
- Prefix `(> 3 5)` means modifier=3, data=5, so it also computes "5 > 3" ✓
- But `(> 5 3)` means modifier=5, data=3 → "3 > 5" = **false** ⚠️

**Prefer infix** when both operands are known. Use prefix only when partially applying:

```
; partial application — safe and idiomatic
(> 5)       ; fn x → x > 5   ("greater than 5")
(+ 1)       ; fn x → x + 1   ("add 1")
(* 2)       ; fn x → x * 2   ("double")

; infix — use for concrete values
5 > 3       ; true
5 - 3       ; 2
```

> ⚠️ **There is no `-`-partial for subtraction.** A leading `-` in primary
> position is *always* unary negation: `(- 5)` = `-5` (an integer), never a
> function. `(+ -1)` also type-errors: inside parens, `+ - 1` is parsed as the
> infix expression `"+" - 1`, not as applying `+` to `-1`.
>
> To make a "subtract 1" function:
> - `(fn [x] (x - 1))` — most readable
> - `(+ (-1))` — partial of `+` with modifier `(-1)` (the extra parens force `-1`
>   to be parsed as a standalone negation before being passed to `+`)

### Pipe operator `|>`

`|>` passes the left value into the **last** argument slot of the right-hand
expression:

```
val |> f          ≡   (f val)
val |> f a        ≡   (f a val)      ; val fills the last slot
a |> f |> g       ≡   (g (f a))      ; chains left to right
```

This pairs cleanly with partial application:

```
[1 2 3 4 5] |> filter (> 2)     ; [3 4 5]  — elements greater than 2
[1 2 3 4 5] |> map (* 2)        ; [2 4 6 8 10]
"hello" |> str-len               ; 5
```

### Field access `:`

```
r:name              ; get field "name" from record r → value or null
cfg:server:port     ; left-associative chain: (cfg:server):port
```

The right operand must be a **bare identifier**, not a computed expression.
Missing fields return `null`, not an error.

```
$ {name: "alice" age: 30}:name
alice

$ {name: "alice" age: 30}:missing
         ← (nothing — null is silent)
```

Partial form `(:name)` is a getter function, useful with `map`:

```
[{name: "a" val: 1} {name: "b" val: 2}] |> map (:name)
; [a b]
```

---

## Special Forms

### `def` — top-level binding

```
(def name value-expr)
```

Binds `name` permanently for the rest of the session. **Silent** (prints nothing).
Later lines can refer to the name.

```
$ (def x 10)
$ x
10
$ (def double (fn [n] (n * 2)))
$ (double 7)
14
```

> ⚠️ **Self-recursion via `def` does not work.** The closure is created before
> the name is bound, so calling the function by its own name inside its body
> produces `error: unbound name`. Use higher-order functions (`fold`, `map`) for
> iterative patterns, or pass the function as an argument.

### `fn` — anonymous function

```
(fn [param] body)
(fn [p1 p2 p3] body)    ; desugars to (fn [p1] (fn [p2] (fn [p3] body)))
```

Multi-parameter `fn` is **syntactic sugar for nested single-parameter closures**
(currying). Closures capture their lexical environment by value. All values are
immutable.

```
$ (def add (fn [a b] (a + b)))
$ (add 3 4)
7
$ (def inc (add 1))    ; partial application — inc is (add 1), a fn waiting for data
$ (inc 10)
11
```

### `let` — local binding

```
(let name value-expr body)
```

Binds `name` within `body` only (not visible outside). Returns the value of `body`.

```
$ (let y 5 (y * y))
25
```

### `if` — conditional

```
(if cond then-expr else-expr)
```

All three sub-expressions are required. Only the taken branch is evaluated.

```
$ (if (5 > 3) "yes" "no")
yes
```

### `do` — sequencing with binds

```
(do stmt1 stmt2 ... stmtN)
```

Evaluates statements left to right. The value is the value of the last statement.
Intermediate results are **discarded** unless bound with `<-`.

**Everything on one line** — the REPL reads one line at a time; you cannot
spread a `do` block across multiple lines.

```
; plain sequencing — discard intermediate values
(do (echo "a") (echo "b") 42)
; prints: a  b  then result 42

; <-  binding — use result later in the block
(do x <- 3 y <- 4 (f! "sum={}" (x + y)))
; sum=7

; reading hardware state
(do raw <- (adc-read 0) (f! "voltage={}" (raw * 3300 / 4095)))
```

`<-` is only valid inside `do`. The name is visible for the **remainder** of the
block only.

### `and` / `or` — short-circuit logic

```
(and e1 e2 ...)    ; returns first falsy value, or the last value if all truthy
(or  e1 e2 ...)    ; returns first truthy value, or the last value if all falsy
```

Both accept **one or more** arguments (zero args: `(and)` → `true`,
`(or)` → `false`) and short-circuit. They return the **deciding value**, not
necessarily a boolean.

```
$ (and true true false)
false
$ (or false null 42)
42
$ (or false false false)
false
```

Infix `a and b` = `(and a b)` — **standard left-to-right** (not data-last; this
is an exception because `and`/`or` are special forms).

**Falsy values:** `false`, `null`, and error records `{err: ...}`. Everything
else — including `0` and `""` — is truthy.

`(not x)` negates the truthiness of `x`:

```
$ (not false)
true
$ (not null)
true
$ (not 42)
false
```

---

## Tail-Call Optimization

Tail-call elimination is implemented for `if`/`let`/`do` tail positions and for
closure tail-calls. Builtin and HOF call chains are **not** eliminated. Since
self-recursion via `def` isn't supported, design iterative algorithms using
`fold`, `map`, or `filter` instead.

```
; fold is the primary iteration tool
(fold (fn [elem acc] (elem + acc)) 0 [1 2 3 4 5])
; 15

; fold callback receives (element, accumulator) — element FIRST, accumulator second
; Each step: new_acc = fn(elem, old_acc). With f! "{},{}", elem is prepended each time:
(fold (fn [elem acc] (f! "{},{}" elem acc)) "end" [1 2 3])
; "3,2,1,end"  ← last element reached first because each step wraps the previous acc
```

---

## Standard Library

All pure functions follow **data-last** convention — the "data" being transformed
is always the **last** argument. This makes pipe (`|>`) and partial application
(`(f modifier)`) idiomatic.

### Arithmetic

| Expression | Result | Notes |
|------------|--------|-------|
| `3 + 4` | `7` | |
| `10 - 3` | `7` | |
| `3 * 4` | `12` | |
| `7 / 2` | `3` | integer division (truncates) |
| `7.0 / 2` | `3.5` | float if either operand is float |
| `7 mod 3` | `1` | integer only; float → type error |
| `(neg 5)` | `-5` | unary negation |

Integer division: `7 / 2 = 3` (truncates toward zero). Mix one float to get
float division: `7.0 / 2 = 3.5` or `(/ 2 7.0)`.

### Comparison

Infix form is clearest:

```
5 > 3     ; true
5 < 3     ; false
5 = 5     ; true
5 != 3    ; true
5 >= 5    ; true
5 <= 4    ; false
```

> ⚠️ **Do not chain comparisons.** `a < b < c` parses as `(a < b) < c` and
> likely produces a type error. Use `(and (a < b) (b < c))` instead.

### Strings

```
"hello" ++ " world"             ; "hello world"   (infix concat — use this)
(str-concat "foo" "bar")        ; "barfoo"  ⚠️ confusing in prefix — use ++ infix
(str-len "hello")               ; 5
(str-join ", " ["a" "b" "c"])   ; "a, b, c"
(str-split "," "a,b,c")         ; [a b c]
(to-str 42)                     ; "42"
(to-str true)                   ; "true"
(to-str null)                   ; "null"
(to-str 3.14)                   ; "3.14"
(to-str [1 "a"])                ; "[1 a]"     (strings unquoted)
(to-str {x: 1})                 ; "{x: 1}"
(to-str (fn [x] x))             ; "<function>"    (closures)
(to-str map)                    ; "map"           (builtins → their own name)
(to-str (map (+ 1)))            ; "<partial>"     (partial applications)
(to-int "42")                   ; 42
(to-int 3.7)                    ; 3        (truncates)
(to-float "3.14")               ; 3.14
(to-float 42)                   ; 42.0
```

> `(str-concat "foo" "bar")` returns `"barfoo"` because `"bar"` is the data
> (last arg) and `"foo"` (modifier) is appended **after** it: result = data + modifier
> = `"bar" + "foo"` = `"barfoo"`. Use infix `++` for clarity:
> `"foo" ++ "bar"` = `"foobar"`.

`to-number` is **not functional** — returns a stub value; do not use.

### Lists

| Function | Example | Result |
|----------|---------|--------|
| `(first xs)` | `(first [10 20 30])` | `10` |
| `(rest xs)` | `(rest [10 20 30])` | `[20 30]` |
| `(count xs)` | `(count [1 2 3])` | `3` |
| `(count s)` | `(count "hello")` | `5` — also counts string bytes |
| `(nth n xs)` | `(nth 2 [10 20 30])` | `30` (0-indexed) |
| `(nth 99 xs)` | out of range | `null` |
| `(reverse xs)` | `(reverse [1 2 3])` | `[3 2 1]` |
| `(flatten xss)` | `(flatten [[1 2] [3 4]])` | `[1 2 3 4]` |
| `(zip xs ys)` | `(zip [1 2] ["a" "b"])` | `[{fst: a snd: 1} ...]` |

**`append` and `concat`** — data-last means the list to transform is **last**,
so always use pipe form:

```
[1 2 3] |> append 0           ; [1 2 3 0]   — append element 0 at end
[1 2 3] |> concat [4 5]       ; [1 2 3 4 5] — extend with another list
```

Prefix form works but reverses readability:
```
(append 0 [1 2 3])            ; [1 2 3 0]   — element is modifier (first)
(concat [4 5] [1 2 3])        ; [1 2 3 4 5] — data (second) is the base list
```

**Higher-order list functions:**

```
(map f xs)           ; apply f to each element
(filter pred xs)     ; keep elements where (pred elem) is truthy
(fold fn init xs)    ; left fold; fn receives (element, accumulator)
```

```
[1 2 3 4 5] |> map (+ 1)             ; [2 3 4 5 6]
[1 2 3 4 5] |> filter (> 2)          ; [3 4 5]   — "greater than 2"
(fold (fn [elem acc] (elem + acc)) 0 [1 2 3 4 5])   ; 15

; fold callback: (fn [element accumulator] ...)
; element comes FIRST, accumulator second — opposite of Haskell/Scheme foldl
(fold (fn [elem acc] (append elem acc)) [] [1 2 3])  ; [1 2 3]
```

`zip` pairs two lists into a list of `{fst: y snd: x}` records, truncated to the
shorter length. Note: `fst` receives the second argument (the data), `snd` the first:

```
(zip [1 2 3] ["a" "b" "c"])
; [{fst: a snd: 1} {fst: b snd: 2} {fst: c snd: 3}]
```

### Records

```
(get "name" r)           ; value for key, or null
(has "name" r)           ; true/false
(set "z" 30 r)           ; new record with key added/updated
(del "name" r)           ; new record with key removed
(keys r)                 ; list of key strings
(values r)               ; list of values
(merge r1 r2)            ; union; r1 (first arg) wins on key conflict
```

Note: `get`, `has`, `set`, `del` take the **key as a string** (quoted), not a
bare name. Field access syntax `r:name` is the idiomatic way to read a field.

```
(def r {x: 10 y: 20})
r:x                       ; 10
(get "x" r)               ; 10    — same, string key
(set "z" 30 r)            ; {x: 10 y: 20 z: 30}
(has "x" r)               ; true
(keys r)                  ; [x y]
(merge {a: 1 b: 2} {b: 9 c: 3})  ; {c: 3 a: 1 b: 2}  ← first arg wins for "b" (b=2 not 9)
(merge {a: 1} {a: 2})             ; {a: 1}            ← first arg wins
```

### Higher-order utilities

```
(identity x)              ; x unchanged
(const x _)               ; always returns x, ignores second arg
(flip f a b)              ; calls (f b a) — swaps last two args
(compose f g x)           ; f(g(x))  — right-to-left
(pipe f g x)              ; g(f(x))  — left-to-right
```

```
(def always-zero (const 0))
(always-zero 42)           ; 0

(compose (+ 1) (* 2) 3)   ; (3*2)+1 = 7
(pipe (* 2) (+ 1) 3)      ; (3*2)+1 = 7
```

---

## Error Handling

Both pure functions and hardware commands use **result records**:

```
{ok: value}       ; success
{err: "message"}  ; failure
```

A record is an error result if it has an `err` key and **no** `ok` key. Error
results are **falsy** (see `and`/`or`).

### Pipeline short-circuit

`|>` short-circuits on error results: if a stage returns `{err: ...}`, all
subsequent stages are skipped and the error propagates to the end.

```
adc read 0
|> map-ok (* 2)        ; skipped if adc-read failed
|> map-ok (+ 100)      ; skipped if any prior stage failed
```

### Result helpers

```
(ok val)           ; construct {ok: val}
(err "msg")        ; construct {err: "msg"}
(ok? r)            ; true if r is a success result record
(err? r)           ; true if r is an error result record
(unwrap r)         ; extract :ok value — returns error record unchanged if err
(map-ok f r)       ; apply f to :ok value; pass errors through
(and-then f r)     ; apply f (which returns a result) to :ok value; pass errors through
(on-err f r)       ; call f with the :err message if r is an error; pass success through
```

```
$ (ok 42)
42

$ (err "oops")
error: oops

$ (map-ok (* 2) {ok: 5})
10

$ (map-ok (* 2) {err: "bad"})
error: bad

$ (on-err (fn [m] (f! "caught: {}" m)) {err: "bad"})
caught: bad

$ (and-then (fn [x] (ok (x * 2))) {ok: 3})
6
```

> `unwrap` **does not halt** — if the argument is an error result, it is returned
> unchanged and the REPL prints it as `error: ...`. Use `on-err` or `and-then`
> to handle errors explicitly.

**Write your own safe functions:**

```
(def safe-div
  (fn [b a]
    (if (= b 0)
      {err: "division by zero"}
      {ok: (a / b)})))

; data-last: a is data (denominator b is modifier)
10 |> safe-div 2    ; 5
10 |> safe-div 0    ; error: division by zero
```

---

## String Formatting

```
(f! "template {}" val)            ; one placeholder
(f! "x={} y={}" x y)             ; multiple placeholders
(format "n={}" n)                 ; alias for f!
```

`{}` placeholders are filled left to right via `to-str`. The number of extra
arguments must match the number of `{}` in the template string.

```
$ (f! "sum={}" (3 + 4))
sum=7

$ (f! "({}, {})" 1.5 "hello")
(1.5, hello)
```

---

## The `env` Store

`env` is a persistent mutable key-value store. It survives line resets (unlike
plain `def`, values are stored in a separate static buffer outside the heap).

**Reading:**
```
env:KEY           ; returns the stored value, or null if unset
```

**Writing:**
```
env! KEY value-expr
```

The key is a **bare name** (not a string literal). Silent on success.

```
$ env! BAUD 115200
$ env:BAUD
115200
$ env:MISSING
          ← (nothing — null is silent)
```

**Scope rule:** `env:KEY` is readable in **any expression context** — including
inside `fn` bodies, `let`, `do`, or at the top level. The `env` identifier is
resolved before the lexical frame is searched, so it always reaches the store:

```
$ env! OFFSET 100
$ (def f (fn [x] (x + env:OFFSET)))
$ (f 42)
142
```

The only restriction is `env!` **writes**: those are processed at the REPL
input level (they must be the first thing on a line) and cannot appear inside
an expression.

---

## Hardware Commands

Two invocation styles exist side by side:

- **Bare multi-word commands** — typed directly at the `$` prompt; argv-style;
  output is printed as text; return nothing to the language.
- **Parenthesized expression commands** — called like any function from within
  an expression, e.g. inside `(map ...)` or a `do` block; return
  `{ok: value}` or `{err: "message"}`.

### `echo`

```
echo hello world           ; prints: hello world
(echo x)                   ; to-str(x) then prints it; returns {ok: null}
```

### `help`

```
help                       ; prints the hardware command summary
```

### `reboot`

```
reboot                     ; prints "rebooting..." then watchdog-reboots
```

### GPIO (pins 0–29)

```
; bare commands
gpio out 13                ; set GP13 as output
gpio in 2                  ; set GP2 as input
gpio set 13 high           ; drive GP13 high  (also: low, 1, 0)
gpio get 2                 ; prints 1 or 0

; expression commands — return {ok:...} or {err:"invalid pin"}
(gpio-out 13)              ; set direction output
(gpio-in 2)                ; set direction input
(gpio-high 13)             ; drive high
(gpio-low 13)              ; drive low
(gpio-read 2)              ; returns {ok: true} or {ok: false}
```

### ADC (channels 0–4)

Channels 0–3 map to GP26–GP29. Channel 4 is the on-chip temperature sensor.

```
; bare command
adc read 0                 ; prints the raw 12-bit reading (0–4095)

; expression command — returns {ok: INT} or {err: "invalid channel"}
(adc-read 0)
```

**Reading temperature (channel 4):**
```
; Pico 2 formula: T_C ≈ 27 - (Vadc - 0.706) / 0.001721
; Everything on ONE line (REPL is single-line only):
(do raw <- (adc-read 4) (let v (raw * 3.3 / 4095.0) (f! "approx {}C" (27.0 - (v - 0.706) / 0.001721))))
```
Sample: with `raw=881` (≈room temperature), `v ≈ 0.710`, result ≈ `approx 24.697054059633942C`.

### Servos (LewanSoul / Hiwonder serial-bus)

The servo bus runs on **UART1, GP4 = TX, GP5 = RX, 115200 baud**. Servo IDs
are 1–253. Degrees are nominally 0–240 (clamped internally; not range-checked).
UART is initialized lazily on the first servo command.

```
; bare commands
servo move 1 90            ; move servo id 1 to 90°
servo move 3 180           ; move servo id 3 to 180°
servo torque 1 on          ; enable torque/hold on servo 1 (also: off, 1, 0)

; expression commands — return {ok: null} or {err: "..."}
(servo-move {id: 1 pos: 90})
(servo-torque {id: 1 on: true})
```

> ⚠️ **`(servo-move 1 90)` does NOT work.** Hardware expression commands are
> single-argument, so `(servo-move 1 90)` parses as `((servo-move 1) 90)` —
> it fires the command on `1`, gets an error, then tries to apply `90` to that
> error. Always use the **record form** `(servo-move {id: N pos: DEG})`.

**Scripted multi-servo move:**

```
(map servo-move [{id: 1 pos: 90} {id: 2 pos: 45} {id: 3 pos: 180}])
```

---

## micro-ROS (requires `ENABLE_MICROROS` build)

The firmware subscribes to `/servo_trajectory`
(`trajectory_msgs/msg/JointTrajectory`). Each message's first trajectory point
drives servos: `positions[i]` in degrees controls servo id `i+1`.

**`uros start` is mode-switched** — it takes over the REPL loop and spins the
micro-ROS executor until the board is rebooted. There is no way to return to
the REPL without rebooting.

### Workflow

1. Define a handler function using top-level `def` — **do not use an inline `fn`**
   here; inline lambdas are freed at the end of the line, before the micro-ROS
   executor ever calls them.

2. Register the handler with `uros-on-traj`.

3. Start the executor with `uros start`.

```
(def handle-traj (fn [positions] (map servo-move positions)))
(uros-on-traj handle-traj)
uros start
```

`positions` will be a list of `{id: N pos: DEG}` records — one per joint in the
trajectory, with `id = joint_index + 1` and `pos` in degrees (float).

### `uros-on-traj` details

```
(uros-on-traj handler)     ; registers a closure; returns {ok: null}
```

The handler must be a closure (produced by `fn`). If a non-closure is passed:

```
error: uros-on-traj: argument must be a closure (use def first)
```

### `uros start`

```
uros start     ; if no handler registered → error
               ; otherwise: prints "starting micro-ROS executor (reboot to exit)"
               ; then blocks forever spinning the executor
```

---

## Worked Session

A complete annotated example combining language features and hardware:

```
; arithmetic and variables
$ 1 + 2
3
$ (def voltage (fn [raw] (raw * 3.3 / 4095.0)))
$ (voltage 2048)
1.6504029304029304

; list processing
$ [1 2 3 4 5] |> filter (> 2) |> map (* 10)
[30 40 50]

; field access
$ (def sensor {id: 1 pin: 26 gain: 2.5})
$ sensor:pin
26
$ sensor:gain
2.5

; records + map
$ (def pins [{id: 1 pin: 13} {id: 2 pin: 14}])
$ pins |> map (:pin)
[13 14]

; do block with hardware (raw=1024 is an illustrative ADC reading)
$ (do raw <- (adc-read 0) (f! "raw={} mV={}" raw (raw * 3300 / 4095)))
raw=1024 mV=825

; error propagation
$ (adc-read 99)
error: invalid channel

; env store
$ env! GAIN 2
$ (do g <- env:GAIN (f! "scaled={}" (512 * g)))
scaled=1024

; servo move (on hardware; host prints packet hex)
$ servo move 1 90
$ (servo-move {id: 2 pos: 45})

; fold to sum
$ (fold (fn [elem acc] (elem + acc)) 0 [10 20 30])
60

; string building
$ (str-join " | " ["alpha" "beta" "gamma"])
alpha | beta | gamma

; result helpers
$ (ok 42) |> map-ok (* 2) |> map-ok (+ 1)
85
$ {err: "bad"} |> map-ok (* 2)
error: bad
```

---

## Known Limitations and Gotchas

| Issue | Detail |
|-------|--------|
| **No self-recursion via `def`** | Closures capture the environment before the name is bound. Design algorithms iteratively using `fold`, `map`, and `filter`. |
| **`number` / `N` suffix not functional** | Parsed without error but produces a non-working value. Any arithmetic on it will `TypeError`. |
| **Commands are NOT parenthesized** | `gpio set 1 high` is a bare command. `(gpio ...)` would be a function call on a non-existent function `gpio`. |
| **Expression commands need a record arg** | `(servo-move 1 90)` is a parse-level application chain; use `(servo-move {id: 1 pos: 90})`. |
| **`str-concat` is data-last** | `(str-concat "a" "b")` = `"ba"`. Use `++` infix: `"a" ++ "b"` = `"ab"`. |
| **Comparison chaining** | `a < b < c` parses as `(a < b) < c` instead of being rejected; will TypeError at eval. Use `(and (a < b) (b < c))`. |
| **`fold` callback order** | Receives `(element, accumulator)` — element first, accumulator second. This is opposite to Haskell/Scheme `foldl`. |
| **`unwrap` does not halt** | Returns the error record unchanged; the REPL prints it. Not a hard abort. |
| **Single-line only** | The REPL reads one line at a time; `do` blocks and all forms must fit on a single line (256-byte limit). |
| **Per-line arena reset** | Only `def` bindings and `env!` writes persist. All other values (including closures created with inline `fn`) are freed after the line. This is why uros handlers need `def`. |
| **`env!` write is top-level only** | `env! KEY val` must be the first thing on a line; it cannot appear inside an expression. `env:KEY` reads, however, work in any context including inside `fn` bodies. |

---

## Quick Reference

### Operators (infix, lowest to highest precedence)
```
|>   or   and   = != < > <= >=   ++   + -   * / mod   (unary: - not)   :
```
All binary ops: `a op b` → `(op b a)` (data-last). Use infix for readability.

### Special forms
```
(def name val)                    ; bind name permanently
(fn [params...] body)             ; anonymous function / closure
(let name val body)               ; local binding
(if cond then else)               ; all three required
(do stmt... )                     ; sequencing; x <- e for binds
(and e1 e2 ...)                   ; short-circuit AND
(or  e1 e2 ...)                   ; short-circuit OR
(not x)                           ; boolean negation (function)
```

### Standard library (quick)
```
; list
first rest count nth reverse flatten append concat zip map filter fold

; record
get set del has keys values merge(r1 wins)   r:field

; string
str-len str-join str-split str-concat to-str to-int to-float   a ++ b

; result
ok err ok? err? unwrap map-ok and-then on-err

; util
identity const flip compose pipe   f! / format
```

### Hardware commands

| Hardware | Bare command | Expression command |
|----------|-------------|-------------------|
| GPIO out/in | `gpio out\|in <pin>` | `(gpio-out N)` `(gpio-in N)` |
| GPIO drive | `gpio set <pin> high\|low` | `(gpio-high N)` `(gpio-low N)` |
| GPIO read | `gpio get <pin>` → prints 0/1 | `(gpio-read N)` → `{ok: bool}` |
| ADC read | `adc read <ch 0-4>` → prints int | `(adc-read N)` → `{ok: int}` |
| Servo move | `servo move <id> <deg>` | `(servo-move {id: N pos: DEG})` |
| Servo torque | `servo torque <id> on\|off` | `(servo-torque {id: N on: BOOL})` |
| micro-ROS handler | `(uros-on-traj handler)` | — |
| micro-ROS start | `uros start` (blocks) | — |
| Reboot | `reboot` | — |

### env store
```
env! KEY value-expr      ; write (bare command)
env:KEY                  ; read (expression, field access on special env receiver)
```

---

*For the formal grammar and design rationale, see [SPEC.md](SPEC.md).*
