// Lexer / tokenizer — will grow into a full token-typed lexer as the parser lands.
const std = @import("std");

pub const Token = []const u8;

/// Tokenize a shell command line into argv, handling single and double quotes.
/// Caller owns the returned slice (allocated with `alloc`).
pub fn tokenize(alloc: std.mem.Allocator, line: []const u8) ![]const Token {
    var tokens: std.ArrayList(Token) = .empty;
    var i: usize = 0;

    while (i < line.len) {
        while (i < line.len and (line[i] == ' ' or line[i] == '\t')) : (i += 1) {}
        if (i >= line.len) break;

        var buf: std.ArrayList(u8) = .empty;
        const start_ch = line[i];

        if (start_ch == '\'' or start_ch == '"') {
            i += 1;
            while (i < line.len and line[i] != start_ch) : (i += 1) {
                if (start_ch == '"' and line[i] == '\\' and i + 1 < line.len) {
                    i += 1;
                    try buf.append(alloc, line[i]);
                } else {
                    try buf.append(alloc, line[i]);
                }
            }
            if (i < line.len) i += 1;
        } else {
            while (i < line.len and line[i] != ' ' and line[i] != '\t') : (i += 1) {
                try buf.append(alloc, line[i]);
            }
        }

        try tokens.append(alloc, try buf.toOwnedSlice(alloc));
    }

    return tokens.toOwnedSlice(alloc);
}

test "basic tokenize" {
    const alloc = std.testing.allocator;
    const result = try tokenize(alloc, "echo hello world");
    defer {
        for (result) |t| alloc.free(t);
        alloc.free(result);
    }
    try std.testing.expectEqual(@as(usize, 3), result.len);
    try std.testing.expectEqualStrings("echo", result[0]);
    try std.testing.expectEqualStrings("hello", result[1]);
    try std.testing.expectEqualStrings("world", result[2]);
}

test "quoted tokenize" {
    const alloc = std.testing.allocator;
    const result = try tokenize(alloc, "echo \"hello world\" 'foo bar'");
    defer {
        for (result) |t| alloc.free(t);
        alloc.free(result);
    }
    try std.testing.expectEqual(@as(usize, 3), result.len);
    try std.testing.expectEqualStrings("echo", result[0]);
    try std.testing.expectEqualStrings("hello world", result[1]);
    try std.testing.expectEqualStrings("foo bar", result[2]);
}
