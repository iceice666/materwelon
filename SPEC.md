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
- **Lisp-shaped syntax**: uniform S-expression application, no operator precedence
- **Embedded-aware**: bounded memory, no heap fragmentation, deterministic allocation

---

## 2. Values and Types

### Primitive types

| Type     | Literals                     |
|----------|------------------------------|
| `number` | `42`, `3.14`, `-7`           |
| `string` | `"hello"`, `"line\n"`        |
| `bool`   | `true`, `false`              |
| `null`   | `null`                       |

### Compound types

| Type     | Literal syntax               | Notes                          |
|----------|------------------------------|--------------------------------|
| `list`   | `[1 2 3]`, `[]`              | ordered, heterogeneous         |
| `record` | `{name: "x" age: 30}`, `{}`  | string-keyed, unordered        |

### Function type

Functions are first-class values. Pure functions are always curried (arity ≥ 1).
Commands are not functions in this sense — they are a separate callable class.

---

## 3. Syntax

### 3.1 Comments

```
; this is a comment — rest of line is ignored
```

### 3.2 Literals

Exactly as shown in §2. Whitespace separates items inside `[...]` and `{...}`.

### 3.3 Function Application

```
(f a)           ; apply f to a
(f a b)         ; curried: ((f a) b)
(f a b c)       ; (((f a) b) c)
```

Application is left-associative. There are no infix operators; `+`, `>`, `=` etc. are
ordinary functions referenced by name.

### 3.4 Special Forms

These are not functions — they affect the environment or control evaluation order.

| Form                  | Meaning                                           |
|-----------------------|---------------------------------------------------|
| `(def name val)`      | Bind `name` to `val` in the top-level environment |
| `(fn x body)`         | Anonymous function, single parameter `x`          |
| `(let x val body)`    | Bind `x` to `val` inside `body` only              |
| `(if cond then else)` | Conditional; evaluates only the taken branch      |

No other special forms. Everything else is either a function call or a command invocation.

### 3.5 Pipe Operator `|>`

```
val |> f           ; (f val)
val |> f a         ; ((f a) val)
a |> f |> g |> h   ; h (g (f a))
```

`|>` is left-associative syntactic sugar. It feeds the left-hand value into the
**last curried slot** of the right-hand expression. This is only meaningful for pure
functions; see §5 for how commands interact with pipes.

### 3.6 Command Invocation

```
cmd arg1 arg2 arg3
```

Bare-word invocation: a name not bound in scope that resolves to a registered command.
Arguments are whitespace-separated expressions. Commands are **not** wrapped in `(...)`.

```
echo "hello"
gpio set 1 high
reboot
```

Commands may appear as the rightmost stage of a pipe:

```
[1 2 3] |> map (+ 10) |> print
```

---

## 4. Pure Functions

### 4.1 Currying

Every pure function takes exactly one argument and returns either a value or another
function. Multi-parameter functions are built by nesting:

```
(def add (fn x (fn y (+ x y))))
(add 3 4)          ; 7
(def add3 (add 3)) ; partially applied
(add3 4)           ; 7
```

### 4.2 Data-last convention

The "data" parameter is always last. This makes partial application compose naturally
with `|>`:

```
; filter :: (a -> bool) -> [a] -> [a]
[1 2 3 4] |> filter (> 2)     ; [3 4]

; map :: (a -> b) -> [a] -> [b]
[1 2 3] |> map (* 2)           ; [2 4 6]
```

`(> 2)` is `(fn x (> x 2))` — the comparison operators follow data-last, so partial
application produces predicates in the expected direction.

### 4.3 Lambda shorthand (sugar)

Single-param lambda:
```
(fn x (+ x 1))
```

Multi-param sugar (expands to nested `fn`):
```
(fn [x y] (+ x y))   ; => (fn x (fn y (+ x y)))
```

### 4.4 Closures

Lambdas close over their lexical environment. The closed-over values are immutable
(captured by value, not by reference). See §8 (Memory) for allocation strategy.

### 4.5 Immutability

All values are immutable. `let` and `def` create new bindings; they never mutate
an existing binding. Rebinding the same name in an inner scope shadows the outer binding.

---

## 5. Commands

### 5.1 What commands are

Commands are firmware-registered callables. They are not functions: they are not
curried, not first-class values, and may produce effects (I/O, hardware state changes,
printing to serial). Current builtins: `echo`, `help`, `reboot`.

### 5.2 Registration

Commands are registered at firmware compile time in a static table:

```zig
// Zig side
const builtins = [_]Command{
    .{ .name = "echo",   .fn = cmd_echo   },
    .{ .name = "reboot", .fn = cmd_reboot },
    .{ .name = "gpio",   .fn = cmd_gpio   },
};
```

There is no runtime command registration (no PATH, no dynamic loading).

### 5.3 Argument passing

Commands receive a flat `[]Value` slice. Arguments are fully evaluated expressions
before dispatch.

```
echo "temp:" (adc read 0)   ; evaluates (adc read 0) first, then calls echo
```

### 5.4 Return values

Commands return a single `Value` (which may be `null` if the command is purely for
effect). The returned value participates in pipes normally:

```
adc read 0 |> format "{}" |> echo
```

### 5.5 Commands in pipelines

When a command appears mid-pipeline, the piped value is passed as the **first**
argument prepended to the argument list. When a command appears at the **end** of
a pipeline, the piped value is passed as the first argument.

```
; adc read 0   -> number
; |> echo      -> echo receives (number) as first arg

adc read 0 |> echo        ; echo <reading>
```

This is the one asymmetry with pure functions (which take the piped value **last**).
Commands always receive pipe input first because their argument order is positional
and conventional, not data-last.

---

## 6. Core Standard Library (pure functions)

Minimum viable set. All follow data-last convention.

### Arithmetic
```
(+ a b)   (- a b)   (* a b)   (/ a b)   (mod a b)   (neg x)
```

### Comparison
```
(= a b)   (< a b)   (> a b)   (<= a b)  (>= a b)
```

### Logic
```
(not x)   (and a b)   (or a b)
```

`and` / `or` are **special forms** (not functions) to preserve short-circuit
evaluation without requiring lazy evaluation.

### List operations
```
(map f xs)           ; [a] -> [b]
(filter pred xs)     ; [a] -> [a]
(fold f init xs)     ; b -> [a] -> b
(first xs)           ; [a] -> a | null
(rest xs)            ; [a] -> [a]
(count xs)           ; [a] -> number
(append xs x)        ; [a] -> a -> [a]
(concat xs ys)       ; [a] -> [a] -> [a]
(nth n xs)           ; number -> [a] -> a | null
(reverse xs)         ; [a] -> [a]
```

### Record operations
```
(get k r)            ; string -> record -> value | null
(set k v r)          ; string -> a -> record -> record   (returns new record)
(keys r)             ; record -> [string]
(values r)           ; record -> [any]
(has k r)            ; string -> record -> bool
(merge r1 r2)        ; record -> record -> record   (r2 wins on conflict)
```

### String operations
```
(str-len s)
(str-join sep xs)    ; string -> [string] -> string
(str-split sep s)    ; string -> string -> [string]
(to-str x)           ; any -> string
(to-num s)           ; string -> number | null
```

### Utility
```
(identity x)
(const x y)          ; always returns x, ignores y  (useful for map/fold)
(flip f a b)         ; calls (f b a)  — reverses arg order
(compose f g x)      ; (f (g x))
```

---

## 7. Evaluation Model

1. **Parse** input line into an AST.
2. **Evaluate** the expression in the current environment.
   - Literals evaluate to themselves.
   - Names look up the environment chain; if not found, check the command table.
   - `(f a)`: evaluate `f` and `a`, apply.
   - Special forms have their own rules (see §3.4).
   - `|>` desugars before evaluation.
3. **If the top-level result is a command invocation**, dispatch to firmware handler.
4. **Print** the result value to serial (unless `null`).
5. **Free** all heap allocations from this evaluation cycle.

The REPL resets the allocator between commands (as in current code). Scripts
(multi-line input) reset after each top-level expression.

---

## 8. Memory Model

The heap is 64 KB fixed buffer. The allocator resets between REPL evaluations.

Allocation rules:
- Strings, lists, records: heap-allocated, owned by the evaluation result.
- Closures: heap-allocated; captured environment is a reference-counted or arena-scoped
  copy of closed-over bindings.
- Intermediate values in a pipeline: freed as soon as the next stage consumes them
  (linear ownership, not GC).
- The standard library must not retain references across evaluation cycles.

**Implication**: deeply nested closures or very large lists may exhaust the heap.
The language does not guarantee tail-call optimization at this stage (see OQ-8).

---

## 9. Open Questions

---

### OQ-1: Number representation

**Status**: Undecided

**Options**:
- **A. Single `number` type (f64)** — simple, one type to reason about, JavaScript-style. Integers up to 2^53 exact.
- **B. `int` (i64) and `float` (f64) as distinct types** — more precise for hardware registers and ADC values; common in embedded contexts.
- **C. Fixed-point only** — avoids FPU dependency; RP2350 has a hardware FPU so this is unnecessary.

**Notes**: Embedded use cases (GPIO values, ADC readings, register addresses) often
need exact integers. Option B is more honest but adds a type distinction. Option A is
simpler. Lean: **B**.

---

### OQ-2: Pipe symbol

**Status**: Undecided

**Options**:
- **A. `|>`** — unambiguous, F#/Elm precedent, visually distinct from command pipe
- **B. `|`** — shell tradition, familiar; since there is no bitwise OR in this language, `|` is free

**Notes**: Since this is a shell, `|` feels natural. But `|>` is less likely to
confuse readers who know shell conventions for text pipes. Lean: **A (`|>`)**.

---

### OQ-3: Multi-param lambda sugar

**Status**: Undecided

**Options**:
- **A. No sugar** — always write `(fn x (fn y body))`; maximally explicit
- **B. `(fn [x y] body)`** — Clojure-style; expands to nested `fn`; implemented as a parse transformation
- **C. `(def f x y body)`** — shorthand at definition site only; `def` with extra names auto-curries

**Notes**: Option C is convenient for top-level definitions but doesn't help anonymous
lambdas. Option B covers both. Lean: **B**, as it makes the language feel less noisy
for multi-arg functions without adding new semantics.

---

### OQ-4: Record field access shorthand

**Status**: Undecided

**Options**:
- **A. Function only**: `(get :name r)` or `(get "name" r)` — uniform, verbose
- **B. Dot function**: `.name` is a function equivalent to `(fn r (get "name" r))`; used as `(.name r)` or `r |> .name`
- **C. Both**: `(get :name r)` for explicit use, `.name` as sugar

**Notes**: `.name` as a first-class function composes well with `map`:
```
people |> map .name
```
Option C is minimally more complex but significantly more ergonomic. Lean: **C**.

---

### OQ-5: Key syntax in record literals and `get`

**Status**: Undecided

**Options**:
- **A. Bare strings**: `{name: "alice"}`, `(get "name" r)` — no extra syntax
- **B. Keywords (colon-prefixed)**: `{name: "alice"}`, `(get :name r)` — Clojure-style, visually distinct
- **C. Strings everywhere**: `{"name": "alice"}`, `(get "name" r)` — JSON-style, unambiguous

**Notes**: Keys in record literals (`{name: ...}`) are already syntactically
unambiguous without a sigil. The question is whether `get` takes a plain string
or a keyword symbol. Option B makes key-vs-string visually clear. Lean: **B**.

---

### OQ-6: Error handling

**Status**: Undecided

**Options**:
- **A. Result record**: functions return `{ok: val}` or `{err: "msg"}`; pipeline short-circuits on `err`; stdlib provides `(unwrap r)`, `(on-err f r)`
- **B. Null propagation**: errors silently become `null`; `(or-default default val)` for recovery; simple but loses error messages
- **C. Special `err` value**: a distinct fifth primitive type (alongside null); pipelines propagate it transparently; `(catch f val)` to handle
- **D. No error handling in the language**: commands print errors to serial and return `null`; pure functions never error by contract

**Notes**: On an embedded REPL, errors mostly mean "wrong argument" or "hardware fault".
Option D is simplest and matches the current implementation. Option A is most
principled. Option C is a middle ground.
Command exit codes (success/failure) are a related concern: how does a command signal
failure to a pipeline? Lean: **C or D**. Decide before implementing `fold`/`map` over
potentially-null data.

---

### OQ-7: Command pipe input position

**Status**: Undecided — the spec currently says "first argument" (§5.5)

**Options**:
- **A. First argument**: `x |> echo` calls `echo x`; natural positional reading
- **B. Last argument**: `x |> echo` calls `echo x` (same for single arg); for multi-arg `"prefix" |> echo "label"` calls `echo "label" "prefix"`
- **C. Explicit placeholder `_`**: `"hello" |> echo _ "world"` = `echo "hello" "world"`; piped value only appears where `_` is placed; required for multi-arg commands

**Notes**: Options A and B only differ for multi-arg command pipelines. Option C is
most explicit but adds syntax. Most shell pipelines pass data as the first argument
(stdin analogue). Lean: **A**, with a note that `_` syntax may be needed later.

---

### OQ-8: Tail-call optimization

**Status**: Undecided

**Options**:
- **A. No TCO** — simpler interpreter, but recursion is depth-limited by the call stack; on RP2350 the default stack is 8 KB, allowing roughly 50–100 recursive calls
- **B. TCO for self-tail-calls only** — covers the common case (manual loops via recursion); moderate implementation complexity
- **C. Full TCO** — correct for all tail positions including mutual recursion; more complex

**Notes**: Without loops (no `while`/`for` special forms), recursion is the only
iteration mechanism. TCO or a `loop`/`recur` form is needed for non-trivial scripts.
Lean: **B or add a `loop` special form** as an alternative to full TCO.

---

### OQ-9: String interpolation

**Status**: Undecided

**Options**:
- **A. None** — use `(str-join "" [(to-str x) " items"])` or a `format` function
- **B. `(format "temp: {} deg" val)`** — explicit format function, no special string syntax
- **C. `"temp: {val} deg"`** — interpolation in string literals; requires `{}` as reserved syntax in strings

**Notes**: Option B is minimal and does not complicate the lexer. Option C is ergonomic
for the REPL but requires the parser to handle interpolated expressions.
Lean: **B**.

---

### OQ-10: Top-level sequencing

**Status**: Undecided — matters for multi-line scripts loaded from flash

**Options**:
- **A. Implicit sequence**: a script is a list of top-level expressions evaluated in order; last value is returned
- **B. Explicit `do`**: multi-expression sequences require `(do expr1 expr2 ...)` everywhere
- **C. `def`-only top level**: scripts may only contain `def` bindings at top level; execution is triggered by calling a bound name like `main`

**Notes**: Option A matches the current REPL (each line is a statement). Option C is
clean for library-style scripts but requires a naming convention for entrypoints.
Lean: **A for REPL, C for scripts** — distinguish REPL mode from script mode.

---

### OQ-11: Mutable state / configuration store

**Status**: Undecided

**Options**:
- **A. None** — the language is purely functional; all state lives in firmware (hardware registers, etc.), accessed only via commands
- **B. Single mutable `env` record** — a top-level key-value store mutated by a `set-env` command; `(get-env :key)` to read; analogous to shell environment variables
- **C. Explicit mutable cells** — `(cell val)` creates a mutable reference; `(deref c)` reads it; `(set! c val)` writes it; first-class but explicit

**Notes**: The REPL needs to persist configuration across commands (e.g. baud rate,
I2C address defaults). Option A forces all state into firmware, which is limiting.
Option B matches shell conventions and is simple. Option C is principled but heavyweight.
Lean: **B**.

---

### OQ-12: Iteration without recursion

**Status**: Undecided — depends on OQ-8 (TCO)

**Options**:
- **A. Recursion only** — requires TCO (OQ-8) for safety
- **B. `(loop bindings body)`** / `(recur ...)` — Clojure-style; explicit tail-call primitive; does not require general TCO
- **C. `(for x in xs body)`** — imperative loop sugar; simple to implement, familiar

**Notes**: For an embedded REPL, most iteration is over small lists (sensor samples,
pin lists) where recursion depth is not a concern. `map`/`filter`/`fold` cover most
cases. Option B is a clean compromise if TCO is deferred. Lean: **B or defer** until
a real use case requiring iteration beyond stdlib arises.

---

## 10. Non-goals

These are explicitly out of scope to preserve minimality:

- Macros or compile-time metaprogramming
- Type inference or static types
- Modules / namespaced imports
- Operator precedence rules
- Classes or prototype-based objects
- Exceptions / try-catch (see OQ-6)
- Pattern matching / destructuring (records and lists are accessed via stdlib functions)
- Lazy evaluation
- Concurrency primitives

---

## Appendix A: Syntax Grammar (informal)

```
program    ::= expr*
expr       ::= literal | name | list-lit | record-lit | application | special | pipeline
literal    ::= number | string | "true" | "false" | "null"
list-lit   ::= "[" expr* "]"
record-lit ::= "{" (name ":" expr)* "}"
application::= "(" expr expr* ")"
special    ::= def | fn | let | if
def        ::= "(" "def" name expr ")"
fn         ::= "(" "fn" name expr ")"        ; or (fn [name+] expr) if OQ-3B adopted
let        ::= "(" "let" name expr expr ")"
if         ::= "(" "if" expr expr expr ")"
pipeline   ::= expr ("|>" expr)+
command    ::= name expr*                    ; bare-word, name not bound in scope
name       ::= [a-zA-Z_+\-*/=<>!?][a-zA-Z0-9_+\-*/=<>!?]*
```

---

## Appendix B: Example session

```
; define a helper
(def square (fn x (* x x)))

; pipeline over a list
[1 2 3 4 5] |> filter (> 2) |> map square
; => [9 16 25]

; hardware command in a pipeline
adc read 0 |> (fn v (if (> v 512) "high" "low")) |> echo

; record access
(def pin {id: 1 mode: "output" state: false})
(get :state pin)       ; false
(set :state true pin)  ; {id: 1 mode: "output" state: true}
pin |> .state          ; false  (original unchanged)
```
