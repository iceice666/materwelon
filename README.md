# materwelon

A minimal functional shell language for the RP2350 (Raspberry Pi Pico 2),
running bare metal in a 64 KB heap — with a host REPL for development.
[SPEC.md](SPEC.md) is the language contract.

```
$ (def double (fn [x] (x * 2)))
$ [1 2 3] |> map double
[2 4 6]
$ (f! "reading: {}" 512)
reading: 512
$ adc read 0
{ok: 512}
$ 1 / 0
error: division by zero
```

Pipelines carry typed values, all values are immutable, pure functions are
curried and data-last, errors are `{ok: …}` / `{err: …}` result records, and
tail calls run in O(1) stack (trampolined).

## Repo layout

```
src/lang/       pure language library — no platform deps, host-testable
  lexer.zig       source line → tokens
  parser.zig      tokens → AST (Pratt parser; all desugaring happens here)
  eval.zig        tree-walk evaluator + TCO trampoline + HOFs
  ops.zig         arithmetic/comparison/concat operators
  stdlib.zig      pure stdlib + the builtin registry (names, arities)
  errors.zig      every error set + canonical user-facing messages
  env.zig         lexical frames + the mutable `env` store
  ast.zig value.zig
  eval_test.zig   black-box language tests (tokenize → parse → eval)

src/shell/      platform-agnostic REPL, driven through an Io interface
  repl.zig        line loop, def/env! persistence, result printing

src/platform/   one file per target, each implements Io + commands
  rp2350.zig      pico-sdk glue; the Zig root for firmware (exports shell_main)
  host.zig        stdin/stdout REPL for development (`zig build run`)

firmware/       CMake + pico-sdk wrapper that links the Zig object
```

Dependency direction: `lang` ← `shell` ← `platform`. The lang library never
imports platform code; platforms register hardware commands through
`lang.eval.Command` and the REPL's bare-command `Dispatch` hook.

## Quick start

```sh
nix develop            # or direnv allow — provides zig, cmake, arm toolchain, pico-sdk
zig build run          # host REPL, no hardware needed
zig build test --summary all
zig build check        # type-check everything without running
```

## Firmware

```sh
zig build firmware     # CMake + zig build-obj cross-compile → firmware/build/materwelon.uf2
zig build flash        # copies the UF2 to a mounted RP2350 BOOTSEL drive
```

`PICO_SDK_PATH` is exported by the nix shell. `flash` locates the BOOTSEL
mount with `findmnt` (Linux); on macOS, copy
`firmware/build/materwelon.uf2` onto the `RP2350` volume manually.

Serial I/O is UART (see `firmware/CMakeLists.txt` to switch to USB CDC).

## Memory model

Two fixed buffers, no general-purpose allocator (SPEC §12):

- **eval heap** (48 KB on firmware) — per-expression arena, reset before
  every REPL line. Everything an expression allocates dies with the line.
- **perm heap** (16 KB on firmware) — top-level `def` bindings, their
  closures, and `env!` keys/values. Never reset.

Because the eval arena is reset, `def` and `env!` lines are re-tokenized and
re-parsed with the perm allocator (`retokenizePerm` in repl.zig) so the AST
and string slices survive. The `env` store itself is a static buffer outside
both heaps.

## Adding a builtin (pure function or operator)

1. Register the name in `stdlib.builtins` (arity + kind) — this table is the
   single source of truth and gates REPL command dispatch.
2. Implement it: pure functions in `stdlib.applyPure`, operators in
   `ops.zig`, closure-calling HOFs in `eval.executeBuiltin`.
3. Add a black-box test in `src/lang/eval_test.zig` (and the parity test in
   stdlib.zig will remind you to keep the registry consistent).
4. Document it in SPEC.md §10.

## Adding a platform command

Two hooks, both registered in the platform file (see rp2350.zig):

- **`lang.eval.Command`** — callable from expressions, e.g. `(echo x)`;
  takes evaluated `Value`s, returns a result record.
- **`Dispatch`** — bare multi-word commands, e.g. `gpio set 1 high`;
  receives raw argv strings before the parser sees the line. Only reached
  when the first word is not a registered builtin.

## Possible follow-ups

- Convert `applyPure`/`executeBuiltin` if-chains to function-pointer tables
  in the registry (needs ~40 data-last arg-order shims; skipped as marginal
  at current scale).
- Software bignum for the `number` type (SPEC §2) — currently a stub.
- Source positions in errors (lexer/parser currently report message-only).
