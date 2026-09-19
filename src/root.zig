//! By convention, root.zig is the root source file when making a package.
const std = @import("std");

pub const Loc = packed struct {
    /// Starting byte index
    start: usize,
    /// Length in bytes
    len: usize,

    pub fn at(byte_index: usize) Loc {
        return Loc{
            .start = byte_index,
            .len = 1,
        };
    }
};

pub const Token = packed struct {
    loc: Loc,
    tag: Tag,

    pub const Tag = enum(u8) {
        @"+",
        @"-",
        @"*",
        @"/",
        integer_literal,
        invalid,
        eof,
    };
};

pub const Lexer = struct {
    source_code: []const u8,
    next_byte_index: usize,

    pub fn next_token(self: *@This()) Token {
        const eof_token = Token{ .loc = .at(self.source_code.len), .tag = .eof };
        if (self.is_at_end()) return eof_token;

        var token_start = self.next_byte_index;

        const tag: Token.Tag = loop: switch (State.start) {
            .start => switch (self.advance_byte()) {
                ' ', '\t', '\n', '\r' => {
                    token_start += self.next_byte_index;
                    continue :loop State.start;
                },

                '0'...'9' => continue :loop .lexing_integer_literal,

                '/' => continue :loop .@"saw_/",

                '+' => break :loop .@"+",
                '-' => break :loop .@"-",
                '*' => break :loop .@"*",

                else => continue :loop .lexing_invalid_token,
            },
            .@"saw_/" => {
                if (self.is_at_end()) break :loop .invalid;
                switch (self.peek_byte()) {
                    '/' => {
                        _ = self.advance_byte();
                        continue :loop .lexing_comment;
                    },
                    else => break :loop .@"/",
                }
            },
            .lexing_comment => {
                if (self.is_at_end()) return eof_token;
                switch (self.advance_byte()) {
                    '\n' => {
                        token_start = self.next_byte_index;
                        continue :loop .start;
                    },
                }
            },
            .lexing_integer_literal => {
                // TODO
            },
            .lexing_invalid_token => {
                // TODO
            },
        };
    }

    fn is_at_end(self: @This()) bool {
        return self.next_byte_index >= self.source_code.len;
    }
    fn peek_byte(self: @This()) u8 {
        std.debug.assert(self.next_byte_index < self.source_code.len);
        return self.source_code[self.next_byte_index];
    }

    fn advance_byte(self: *@This()) u8 {
        const byte = self.peek_byte();
        self.next_byte_index += 1;
        return byte;
    }

    pub const State = enum {
        start,
        @"saw_/",
        lexing_comment,
        lexing_integer_literal,
        lexing_invalid_token,
    };
};
