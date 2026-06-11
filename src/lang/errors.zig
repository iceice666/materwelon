//! Single source of truth for every error the language pipeline can produce,
//! and the canonical user-facing message for each. Modules alias their error
//! sets from here; the REPL maps any of them to text via `message()`.

/// Lexer errors (tokenize).
pub const LexError = error{
    UnexpectedChar,
    UnterminatedString,
    InvalidEscape,
    NumberOverflow,
    OutOfMemory,
};

/// Parser errors (parse).
pub const ParseError = error{
    UnexpectedToken,
    UnexpectedEof,
    ExpectedIdent,
    EmptyFnParams,
    OutOfMemory,
};

/// Errors pure stdlib/operator functions can produce (no name resolution).
pub const PureError = error{
    TypeError,
    DivisionByZero,
    OutOfMemory,
};

/// Full evaluator error set. PureError coerces into this implicitly.
pub const RuntimeError = PureError || error{UnboundName};

/// Mutable env store errors (env! writes).
pub const StoreError = error{
    KeyTooLong,
    StoreFull,
};

/// Everything the REPL can encounter in one input cycle.
pub const Error = LexError || ParseError || RuntimeError || StoreError;

/// Canonical message, sans the "error: " prefix the REPL adds.
/// Exhaustive: adding an error variant anywhere is a compile error here
/// instead of a missed branch in the REPL.
pub fn message(err: Error) []const u8 {
    return switch (err) {
        error.UnexpectedChar     => "unexpected character",
        error.UnterminatedString => "unterminated string",
        error.InvalidEscape      => "invalid escape sequence",
        error.NumberOverflow     => "number out of range",
        error.UnexpectedToken    => "unexpected token",
        error.UnexpectedEof      => "unexpected end of input",
        error.ExpectedIdent      => "expected identifier",
        error.EmptyFnParams      => "empty fn params",
        error.UnboundName        => "unbound name",
        error.TypeError          => "type error",
        error.DivisionByZero     => "division by zero",
        error.KeyTooLong         => "env key too long",
        error.StoreFull          => "env store full",
        error.OutOfMemory        => "out of memory",
    };
}

test "message covers every variant" {
    const std = @import("std");
    // Exhaustiveness is enforced by the switch; spot-check strings the REPL
    // tests assert byte-for-byte.
    try std.testing.expectEqualStrings("division by zero", message(error.DivisionByZero));
    try std.testing.expectEqualStrings("unbound name", message(error.UnboundName));
    try std.testing.expectEqualStrings("out of memory", message(error.OutOfMemory));
}
