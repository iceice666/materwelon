const std = @import("std");
const errors = @import("errors.zig");

pub const LexError = errors.LexError;

pub const Token = union(enum) {
    // Grouping
    L_Paren, R_Paren,
    L_Bracket, R_Bracket,
    L_Brace, R_Brace,

    // Punctuation
    Colon,       // :  field access
    L_Arrow,     // <- do-block binding

    // Pipe
    Pipe_Fwd,    // |>

    // Arithmetic operators
    Plus, Minus, Multiply, Divide,
    Concat,      // ++

    // Comparison operators
    Eq,          // =
    Not_Eq,      // !=
    L_Angle,     // <
    R_Angle,     // >
    Less_Eq,     // <=
    Greater_Eq,  // >=

    // Keywords
    KW_If, KW_AND, KW_OR, KW_NOT, KW_LET, KW_DO, KW_FN, KW_DEF, KW_MOD,

    // Literal keywords
    Lit_True, Lit_False, Lit_Null,

    // End of input
    Eof,

    // Payload variants
    Lit_Int:    i64,
    Lit_Float:  f64,
    Lit_Number: []const u8, // bignum digits without N suffix; slice into source
    Lit_String: []const u8, // allocated via caller's allocator
    Ident:      []const u8, // slice into source



    pub fn free(self: Token, alloc: std.mem.Allocator) void {
        switch (self) {
            .Lit_String => |s| alloc.free(s),
            else => {},
        }
    }
};

pub fn is_ws(c: u8) bool {
    return c == ' ' or c == '\t' or c == '\r' or c == '\n';
}

/// Tokenize `line` into a slice of Tokens.
/// Caller owns the returned slice (free with `freeTokens`).
/// `Lit_String` payloads are heap-allocated; all other slices point into `line`.
pub fn tokenize(alloc: std.mem.Allocator, line: []const u8) LexError![]const Token {
    var tokens: std.ArrayList(Token) = .empty;
    errdefer {
        for (tokens.items) |tok| {
            tok.free(alloc);
        }
        tokens.deinit(alloc);
    }

    var i: usize = 0;
    while (i < line.len) {
        const c = line[i];

        if (is_ws(c)) {
            i += 1;
            continue;
        }
        if (c == ';') {
            while (i < line.len and line[i] != '\n') i += 1;
            continue;
        }

        switch (c) {
            '(' => { try tokens.append(alloc, .L_Paren);   i += 1; },
            ')' => { try tokens.append(alloc, .R_Paren);   i += 1; },
            '[' => { try tokens.append(alloc, .L_Bracket); i += 1; },
            ']' => { try tokens.append(alloc, .R_Bracket); i += 1; },
            '{' => { try tokens.append(alloc, .L_Brace);   i += 1; },
            '}' => { try tokens.append(alloc, .R_Brace);   i += 1; },
            ':' => { try tokens.append(alloc, .Colon);     i += 1; },
            '*' => { try tokens.append(alloc, .Multiply);  i += 1; },
            '/' => { try tokens.append(alloc, .Divide);    i += 1; },
            '=' => { try tokens.append(alloc, .Eq);        i += 1; },
            '+' => {
                if (nextIs(line, i, '+')) {
                    try tokens.append(alloc, .Concat); i += 2;
                } else {
                    try tokens.append(alloc, .Plus); i += 1;
                }
            },
            '-' => { try tokens.append(alloc, .Minus); i += 1; },
            '!' => {
                if (nextIs(line, i, '=')) {
                    try tokens.append(alloc, .Not_Eq); i += 2;
                } else {
                    return error.UnexpectedChar;
                }
            },
            '<' => {
                if (nextIs(line, i, '=')) {
                    try tokens.append(alloc, .Less_Eq); i += 2;
                } else if (nextIs(line, i, '-')) {
                    try tokens.append(alloc, .L_Arrow); i += 2;
                } else {
                    try tokens.append(alloc, .L_Angle); i += 1;
                }
            },
            '>' => {
                if (nextIs(line, i, '=')) {
                    try tokens.append(alloc, .Greater_Eq); i += 2;
                } else {
                    try tokens.append(alloc, .R_Angle); i += 1;
                }
            },
            '|' => {
                if (nextIs(line, i, '>')) {
                    try tokens.append(alloc, .Pipe_Fwd); i += 2;
                } else {
                    return error.UnexpectedChar;
                }
            },
            '"' => {
                const s = try lexString(alloc, line, &i);
                try tokens.append(alloc, .{ .Lit_String = s });
            },
            '0'...'9' => {
                const tok = try lexNumber(line, &i);
                try tokens.append(alloc, tok);
            },
            'a'...'z', 'A'...'Z', '_' => {
                const tok = lexIdent(line, &i);
                try tokens.append(alloc, tok);
            },
            else => return error.UnexpectedChar,
        }
    }

    try tokens.append(alloc, .Eof);
    return tokens.toOwnedSlice(alloc);
}

/// Free the slice and any heap-allocated payloads within it.
pub fn freeTokens(alloc: std.mem.Allocator, tokens: []const Token) void {
    for (tokens) |tok| {
        switch (tok) {
            .Lit_String => |s| alloc.free(s),
            else => {},
        }
    }
    alloc.free(tokens);
}

fn nextIs(line: []const u8, i: usize, c: u8) bool {
    return i + 1 < line.len and line[i + 1] == c;
}

// Identifier tail chars: alpha, digit, underscore, hyphen, bang, question-mark.
// Hyphen allows kebab-case names (foo-bar). Bang/question follow Lisp convention
// for names like `env!` and `ok?`.
fn isIdentTail(c: u8) bool {
    return switch (c) {
        'a'...'z', 'A'...'Z', '0'...'9', '_', '-', '!', '?' => true,
        else => false,
    };
}

fn lexIdent(line: []const u8, i: *usize) Token {
    const start = i.*;
    while (i.* < line.len and isIdentTail(line[i.*])) i.* += 1;
    return keywordOrIdent(line[start..i.*]);
}

fn keywordOrIdent(word: []const u8) Token {
    if (std.mem.eql(u8, word, "if"))    return .KW_If;
    if (std.mem.eql(u8, word, "and"))   return .KW_AND;
    if (std.mem.eql(u8, word, "or"))    return .KW_OR;
    if (std.mem.eql(u8, word, "not"))   return .KW_NOT;
    if (std.mem.eql(u8, word, "let"))   return .KW_LET;
    if (std.mem.eql(u8, word, "do"))    return .KW_DO;
    if (std.mem.eql(u8, word, "fn"))    return .KW_FN;
    if (std.mem.eql(u8, word, "def"))   return .KW_DEF;
    if (std.mem.eql(u8, word, "mod"))   return .KW_MOD;
    if (std.mem.eql(u8, word, "true"))  return .Lit_True;
    if (std.mem.eql(u8, word, "false")) return .Lit_False;
    if (std.mem.eql(u8, word, "null"))  return .Lit_Null;
    return .{ .Ident = word };
}

fn lexNumber(line: []const u8, i: *usize) !Token {
    const start = i.*;

    while (i.* < line.len and line[i.*] >= '0' and line[i.*] <= '9') i.* += 1;

    // Float: digits '.' digits (requires at least one digit after the dot)
    const has_dot = i.* < line.len and line[i.*] == '.' and
        i.* + 1 < line.len and line[i.* + 1] >= '0' and line[i.* + 1] <= '9';
    if (has_dot) {
        i.* += 1; // consume '.'
        while (i.* < line.len and line[i.*] >= '0' and line[i.*] <= '9') i.* += 1;
    }

    // N suffix → bignum literal (slice into source, without the N)
    if (i.* < line.len and line[i.*] == 'N') {
        const digits = line[start..i.*];
        i.* += 1;
        return .{ .Lit_Number = digits };
    }

    const s = line[start..i.*];
    if (has_dot) {
        const val = std.fmt.parseFloat(f64, s) catch return error.NumberOverflow;
        return .{ .Lit_Float = val };
    } else {
        const val = std.fmt.parseInt(i64, s, 10) catch return error.NumberOverflow;
        return .{ .Lit_Int = val };
    }
}

fn lexString(alloc: std.mem.Allocator, line: []const u8, i: *usize) ![]const u8 {
    i.* += 1; // consume opening "

    var buf: std.ArrayList(u8) = .empty;
    errdefer buf.deinit(alloc);

    while (i.* < line.len) {
        const c = line[i.*];
        if (c == '"') {
            i.* += 1;
            return buf.toOwnedSlice(alloc);
        }
        if (c == '\\') {
            i.* += 1;
            if (i.* >= line.len) return error.UnterminatedString;
            const ch: u8 = switch (line[i.*]) {
                'n'  => '\n',
                't'  => '\t',
                'r'  => '\r',
                '\\' => '\\',
                '"'  => '"',
                '0'  => 0,
                else => return error.InvalidEscape,
            };
            try buf.append(alloc, ch);
        } else {
            try buf.append(alloc, c);
        }
        i.* += 1;
    }
    return error.UnterminatedString;
}

// ─── Tests ───────────────────────────────────────────────────────────────────

const testing = std.testing;

test "empty input yields only Eof" {
    const alloc = testing.allocator;
    const tokens = try tokenize(alloc, "");
    defer freeTokens(alloc, tokens);
    try testing.expectEqual(@as(usize, 1), tokens.len);
    try testing.expectEqual(Token.Eof, tokens[0]);
}

test "whitespace only yields only Eof" {
    const alloc = testing.allocator;
    const tokens = try tokenize(alloc, "   \t\r\n  ");
    defer freeTokens(alloc, tokens);
    try testing.expectEqual(@as(usize, 1), tokens.len);
    try testing.expectEqual(Token.Eof, tokens[0]);
}

test "grouping tokens" {
    const alloc = testing.allocator;
    const tokens = try tokenize(alloc, "()[]{}");
    defer freeTokens(alloc, tokens);
    try testing.expectEqual(@as(usize, 7), tokens.len);
    try testing.expectEqual(Token.L_Paren,   tokens[0]);
    try testing.expectEqual(Token.R_Paren,   tokens[1]);
    try testing.expectEqual(Token.L_Bracket, tokens[2]);
    try testing.expectEqual(Token.R_Bracket, tokens[3]);
    try testing.expectEqual(Token.L_Brace,   tokens[4]);
    try testing.expectEqual(Token.R_Brace,   tokens[5]);
    try testing.expectEqual(Token.Eof,       tokens[6]);
}

test "colon token" {
    const alloc = testing.allocator;
    const tokens = try tokenize(alloc, ":");
    defer freeTokens(alloc, tokens);
    try testing.expectEqual(Token.Colon, tokens[0]);
    try testing.expectEqual(Token.Eof,   tokens[1]);
}

test "arithmetic operators" {
    const alloc = testing.allocator;
    const tokens = try tokenize(alloc, "+ - * /");
    defer freeTokens(alloc, tokens);
    try testing.expectEqual(@as(usize, 5), tokens.len);
    try testing.expectEqual(Token.Plus,     tokens[0]);
    try testing.expectEqual(Token.Minus,    tokens[1]);
    try testing.expectEqual(Token.Multiply, tokens[2]);
    try testing.expectEqual(Token.Divide,   tokens[3]);
    try testing.expectEqual(Token.Eof,      tokens[4]);
}

test "concat operator" {
    const alloc = testing.allocator;
    const tokens = try tokenize(alloc, "++");
    defer freeTokens(alloc, tokens);
    try testing.expectEqual(@as(usize, 2), tokens.len);
    try testing.expectEqual(Token.Concat, tokens[0]);
    try testing.expectEqual(Token.Eof,    tokens[1]);
}

test "plus does not absorb a following non-plus" {
    const alloc = testing.allocator;
    const tokens = try tokenize(alloc, "+1");
    defer freeTokens(alloc, tokens);
    try testing.expectEqual(Token.Plus, tokens[0]);
    try testing.expectEqual(@as(i64, 1), tokens[1].Lit_Int);
}

test "comparison operators" {
    const alloc = testing.allocator;
    const tokens = try tokenize(alloc, "= != < > <= >=");
    defer freeTokens(alloc, tokens);
    try testing.expectEqual(@as(usize, 7), tokens.len);
    try testing.expectEqual(Token.Eq,         tokens[0]);
    try testing.expectEqual(Token.Not_Eq,     tokens[1]);
    try testing.expectEqual(Token.L_Angle,    tokens[2]);
    try testing.expectEqual(Token.R_Angle,    tokens[3]);
    try testing.expectEqual(Token.Less_Eq,    tokens[4]);
    try testing.expectEqual(Token.Greater_Eq, tokens[5]);
    try testing.expectEqual(Token.Eof,        tokens[6]);
}

test "l_arrow operator" {
    const alloc = testing.allocator;
    const tokens = try tokenize(alloc, "<-");
    defer freeTokens(alloc, tokens);
    try testing.expectEqual(Token.L_Arrow, tokens[0]);
    try testing.expectEqual(Token.Eof,     tokens[1]);
}

test "pipe_fwd operator" {
    const alloc = testing.allocator;
    const tokens = try tokenize(alloc, "|>");
    defer freeTokens(alloc, tokens);
    try testing.expectEqual(Token.Pipe_Fwd, tokens[0]);
    try testing.expectEqual(Token.Eof,      tokens[1]);
}

test "keywords" {
    const alloc = testing.allocator;
    const tokens = try tokenize(alloc, "if and or not let do fn def mod");
    defer freeTokens(alloc, tokens);
    try testing.expectEqual(@as(usize, 10), tokens.len);
    try testing.expectEqual(Token.KW_If,  tokens[0]);
    try testing.expectEqual(Token.KW_AND, tokens[1]);
    try testing.expectEqual(Token.KW_OR,  tokens[2]);
    try testing.expectEqual(Token.KW_NOT, tokens[3]);
    try testing.expectEqual(Token.KW_LET, tokens[4]);
    try testing.expectEqual(Token.KW_DO,  tokens[5]);
    try testing.expectEqual(Token.KW_FN,  tokens[6]);
    try testing.expectEqual(Token.KW_DEF, tokens[7]);
    try testing.expectEqual(Token.KW_MOD, tokens[8]);
    try testing.expectEqual(Token.Eof,    tokens[9]);
}

test "literal keywords" {
    const alloc = testing.allocator;
    const tokens = try tokenize(alloc, "true false null");
    defer freeTokens(alloc, tokens);
    try testing.expectEqual(@as(usize, 4), tokens.len);
    try testing.expectEqual(Token.Lit_True,  tokens[0]);
    try testing.expectEqual(Token.Lit_False, tokens[1]);
    try testing.expectEqual(Token.Lit_Null,  tokens[2]);
    try testing.expectEqual(Token.Eof,       tokens[3]);
}

test "keyword prefix is still an identifier" {
    const alloc = testing.allocator;
    // "ifx" must not be split into KW_If + Ident("x")
    const tokens = try tokenize(alloc, "ifx");
    defer freeTokens(alloc, tokens);
    try testing.expectEqual(@as(usize, 2), tokens.len);
    try testing.expectEqualStrings("ifx", tokens[0].Ident);
    try testing.expectEqual(Token.Eof, tokens[1]);
}

test "integer literals" {
    const alloc = testing.allocator;
    {
        const tokens = try tokenize(alloc, "0");
        defer freeTokens(alloc, tokens);
        try testing.expectEqual(@as(i64, 0), tokens[0].Lit_Int);
    }
    {
        const tokens = try tokenize(alloc, "42");
        defer freeTokens(alloc, tokens);
        try testing.expectEqual(@as(i64, 42), tokens[0].Lit_Int);
    }
    {
        // max i64
        const tokens = try tokenize(alloc, "9223372036854775807");
        defer freeTokens(alloc, tokens);
        try testing.expectEqual(@as(i64, std.math.maxInt(i64)), tokens[0].Lit_Int);
    }
}

test "float literals" {
    const alloc = testing.allocator;
    {
        const tokens = try tokenize(alloc, "3.14");
        defer freeTokens(alloc, tokens);
        try testing.expectEqual(@as(f64, 3.14), tokens[0].Lit_Float);
    }
    {
        const tokens = try tokenize(alloc, "0.5");
        defer freeTokens(alloc, tokens);
        try testing.expectEqual(@as(f64, 0.5), tokens[0].Lit_Float);
    }
    {
        const tokens = try tokenize(alloc, "1.0");
        defer freeTokens(alloc, tokens);
        try testing.expectEqual(@as(f64, 1.0), tokens[0].Lit_Float);
    }
}

test "float requires digit after dot" {
    // "1." — dot has no following digit, so lexNumber returns Lit_Int(1),
    // then '.' hits the unrecognised-char path.
    const alloc = testing.allocator;
    try testing.expectError(error.UnexpectedChar, tokenize(alloc, "1."));
}

test "bignum literals" {
    const alloc = testing.allocator;
    {
        const tokens = try tokenize(alloc, "42N");
        defer freeTokens(alloc, tokens);
        try testing.expectEqualStrings("42", tokens[0].Lit_Number);
        try testing.expectEqual(Token.Eof, tokens[1]);
    }
    {
        const tokens = try tokenize(alloc, "0N");
        defer freeTokens(alloc, tokens);
        try testing.expectEqualStrings("0", tokens[0].Lit_Number);
    }
    {
        // digits too large for i64, but fine as bignum
        const tokens = try tokenize(alloc, "99999999999999999999N");
        defer freeTokens(alloc, tokens);
        try testing.expectEqualStrings("99999999999999999999", tokens[0].Lit_Number);
    }
}

test "bignum with decimal notation" {
    const alloc = testing.allocator;
    const tokens = try tokenize(alloc, "3.14N");
    defer freeTokens(alloc, tokens);
    try testing.expectEqualStrings("3.14", tokens[0].Lit_Number);
    try testing.expectEqual(Token.Eof, tokens[1]);
}

test "string literal basic" {
    const alloc = testing.allocator;
    const tokens = try tokenize(alloc, "\"hello\"");
    defer freeTokens(alloc, tokens);
    try testing.expectEqualStrings("hello", tokens[0].Lit_String);
    try testing.expectEqual(Token.Eof, tokens[1]);
}

test "string literal empty" {
    const alloc = testing.allocator;
    const tokens = try tokenize(alloc, "\"\"");
    defer freeTokens(alloc, tokens);
    try testing.expectEqualStrings("", tokens[0].Lit_String);
    try testing.expectEqual(Token.Eof, tokens[1]);
}

test "string escape sequences" {
    const alloc = testing.allocator;
    // source: "\n\t\r\\\"\0"
    const tokens = try tokenize(alloc, "\"\\n\\t\\r\\\\\\\"\\0\"");
    defer freeTokens(alloc, tokens);
    try testing.expectEqualStrings("\n\t\r\\\"\x00", tokens[0].Lit_String);
}

test "identifier basic" {
    const alloc = testing.allocator;
    const tokens = try tokenize(alloc, "foo");
    defer freeTokens(alloc, tokens);
    try testing.expectEqualStrings("foo", tokens[0].Ident);
    try testing.expectEqual(Token.Eof, tokens[1]);
}

test "identifier kebab-case" {
    const alloc = testing.allocator;
    const tokens = try tokenize(alloc, "foo-bar");
    defer freeTokens(alloc, tokens);
    try testing.expectEqualStrings("foo-bar", tokens[0].Ident);
    try testing.expectEqual(Token.Eof, tokens[1]);
}

test "identifier with bang suffix" {
    const alloc = testing.allocator;
    const tokens = try tokenize(alloc, "env!");
    defer freeTokens(alloc, tokens);
    try testing.expectEqualStrings("env!", tokens[0].Ident);
    try testing.expectEqual(Token.Eof, tokens[1]);
}

test "identifier with question-mark suffix" {
    const alloc = testing.allocator;
    const tokens = try tokenize(alloc, "ok?");
    defer freeTokens(alloc, tokens);
    try testing.expectEqualStrings("ok?", tokens[0].Ident);
    try testing.expectEqual(Token.Eof, tokens[1]);
}

test "identifier with underscore prefix" {
    const alloc = testing.allocator;
    const tokens = try tokenize(alloc, "_private");
    defer freeTokens(alloc, tokens);
    try testing.expectEqualStrings("_private", tokens[0].Ident);
}

test "identifier uppercase" {
    const alloc = testing.allocator;
    const tokens = try tokenize(alloc, "MyModule");
    defer freeTokens(alloc, tokens);
    try testing.expectEqualStrings("MyModule", tokens[0].Ident);
}

test "comment skips to end of line" {
    const alloc = testing.allocator;
    const tokens = try tokenize(alloc, "; this is a comment\nfoo");
    defer freeTokens(alloc, tokens);
    try testing.expectEqual(@as(usize, 2), tokens.len);
    try testing.expectEqualStrings("foo", tokens[0].Ident);
    try testing.expectEqual(Token.Eof, tokens[1]);
}

test "inline comment after tokens" {
    const alloc = testing.allocator;
    const tokens = try tokenize(alloc, "42 ; the answer");
    defer freeTokens(alloc, tokens);
    try testing.expectEqual(@as(usize, 2), tokens.len);
    try testing.expectEqual(@as(i64, 42), tokens[0].Lit_Int);
    try testing.expectEqual(Token.Eof, tokens[1]);
}

test "full-line comment yields only Eof" {
    const alloc = testing.allocator;
    const tokens = try tokenize(alloc, "; everything ignored");
    defer freeTokens(alloc, tokens);
    try testing.expectEqual(@as(usize, 1), tokens.len);
    try testing.expectEqual(Token.Eof, tokens[0]);
}

test "do-block binding arrow" {
    const alloc = testing.allocator;
    const tokens = try tokenize(alloc, "x <- 42");
    defer freeTokens(alloc, tokens);
    try testing.expectEqual(@as(usize, 4), tokens.len);
    try testing.expectEqualStrings("x", tokens[0].Ident);
    try testing.expectEqual(Token.L_Arrow,  tokens[1]);
    try testing.expectEqual(@as(i64, 42),   tokens[2].Lit_Int);
    try testing.expectEqual(Token.Eof,      tokens[3]);
}

test "complex expression: let binding with pipe" {
    const alloc = testing.allocator;
    const tokens = try tokenize(alloc, "let x = 42 |> foo");
    defer freeTokens(alloc, tokens);
    try testing.expectEqual(@as(usize, 7), tokens.len);
    try testing.expectEqual(Token.KW_LET,   tokens[0]);
    try testing.expectEqualStrings("x",     tokens[1].Ident);
    try testing.expectEqual(Token.Eq,       tokens[2]);
    try testing.expectEqual(@as(i64, 42),   tokens[3].Lit_Int);
    try testing.expectEqual(Token.Pipe_Fwd, tokens[4]);
    try testing.expectEqualStrings("foo",   tokens[5].Ident);
    try testing.expectEqual(Token.Eof,      tokens[6]);
}

test "complex expression: record field access" {
    const alloc = testing.allocator;
    const tokens = try tokenize(alloc, "rec:field");
    defer freeTokens(alloc, tokens);
    try testing.expectEqual(@as(usize, 4), tokens.len);
    try testing.expectEqualStrings("rec",   tokens[0].Ident);
    try testing.expectEqual(Token.Colon,    tokens[1]);
    try testing.expectEqualStrings("field", tokens[2].Ident);
    try testing.expectEqual(Token.Eof,      tokens[3]);
}

test "multiple strings in one line" {
    const alloc = testing.allocator;
    const tokens = try tokenize(alloc, "\"foo\" \"bar\"");
    defer freeTokens(alloc, tokens);
    try testing.expectEqual(@as(usize, 3), tokens.len);
    try testing.expectEqualStrings("foo", tokens[0].Lit_String);
    try testing.expectEqualStrings("bar", tokens[1].Lit_String);
    try testing.expectEqual(Token.Eof, tokens[2]);
}

// ─── Error cases ─────────────────────────────────────────────────────────────

test "error: bare ! is UnexpectedChar" {
    const alloc = testing.allocator;
    try testing.expectError(error.UnexpectedChar, tokenize(alloc, "!"));
}

test "error: bare | is UnexpectedChar" {
    const alloc = testing.allocator;
    try testing.expectError(error.UnexpectedChar, tokenize(alloc, "|"));
}

test "error: unknown character is UnexpectedChar" {
    const alloc = testing.allocator;
    try testing.expectError(error.UnexpectedChar, tokenize(alloc, "@"));
}

test "error: dot alone is UnexpectedChar" {
    const alloc = testing.allocator;
    try testing.expectError(error.UnexpectedChar, tokenize(alloc, "."));
}

test "error: unterminated string" {
    const alloc = testing.allocator;
    try testing.expectError(error.UnterminatedString, tokenize(alloc, "\"hello"));
}

test "error: unterminated string ending with backslash" {
    const alloc = testing.allocator;
    try testing.expectError(error.UnterminatedString, tokenize(alloc, "\"\\"));
}

test "error: invalid escape sequence" {
    const alloc = testing.allocator;
    try testing.expectError(error.InvalidEscape, tokenize(alloc, "\"\\x\""));
}

test "error: integer overflow" {
    // maxInt(i64) + 1 overflows i64
    const alloc = testing.allocator;
    try testing.expectError(error.NumberOverflow, tokenize(alloc, "9223372036854775808"));
}
