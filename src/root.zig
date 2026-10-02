const std = @import("std");

const assert = std.debug.assert;

pub const FmtTerminal = @import("fmt_terminal.zig").FmtTerminal;

/// Continuous location in the source code.
pub const Loc = packed struct {
    /// Starting byte index
    start: usize,
    /// Inclusive ending byte index
    end: usize,

    pub fn at(byte_index: usize) Loc {
        return Loc{
            .start = byte_index,
            .end = byte_index,
        };
    }

    pub fn init(start: usize, end: usize) Loc {
        std.debug.assert(start <= end);
        return Loc{
            .start = start,
            .end = end,
        };
    }

    pub fn slice_from(loc: Loc, source_code: []const u8) []const u8 {
        return source_code[loc.start..(loc.end + 1)];
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
        @"(",
        @")",
        @"[",
        @"]",
        @"{",
        @"}",
        @".",
        @":",
        @";",
        @"=",
        @",",
        @"^",
        identifier,
        kw_val,
        kw_var,
        kw_fn,
        kw_const,
        kw_struct,
        kw_return,
        integer_literal,
        string_literal,
        invalid,
        eof,
    };
};

pub const keywords_by_lexeme = std.StaticStringMap(Token.Tag).initComptime(.{
    .{ "val", Token.Tag.kw_val },
    .{ "var", Token.Tag.kw_var },
    .{ "fn", Token.Tag.kw_fn },
    .{ "const", Token.Tag.kw_const },
    .{ "struct", Token.Tag.kw_struct },
    .{ "return", Token.Tag.kw_return },
});

pub fn get_keyword(lexeme: []const u8) ?Token.Tag {
    return keywords_by_lexeme.get(lexeme);
}

pub const Lexer = struct {
    source_code: []const u8,
    next_byte_index: usize = 0,

    pub fn next_token(self: *@This()) Token {
        const eof_token = Token{ .loc = .at(self.source_code.len), .tag = .eof };
        if (self.is_at_end()) return eof_token;

        var token_start = self.next_byte_index;

        const tag: Token.Tag = loop: switch (State.start) {
            .start => switch (self.advance_byte()) {
                ' ', '\t', '\n', '\r' => {
                    token_start = self.next_byte_index;
                    if (self.is_at_end()) return eof_token;
                    continue :loop State.start;
                },

                'A'...'Z', 'a'...'z', '_' => continue :loop .lexing_identifier,

                '0'...'9' => continue :loop .lexing_integer_literal,

                '"' => continue :loop .lexing_string_literal,

                '/' => continue :loop .@"saw_/",

                '+' => break :loop .@"+",
                '-' => break :loop .@"-",
                '*' => break :loop .@"*",
                '(' => break :loop .@"(",
                ')' => break :loop .@")",
                '[' => break :loop .@"[",
                ']' => break :loop .@"]",
                '{' => break :loop .@"{",
                '}' => break :loop .@"}",

                '.' => break :loop .@".",
                ',' => break :loop .@",",
                ':' => break :loop .@":",
                ';' => break :loop .@";",

                '^' => break :loop .@"^",

                '=' => break :loop .@"=",

                else => continue :loop .lexing_invalid_token,
            },
            .lexing_string_literal => {
                if (self.is_at_end()) break :loop .invalid;
                switch (self.advance_byte()) {
                    '"' => if (self.source_code[self.next_byte_index - 2] != '\\') {
                        break :loop .string_literal;
                    } else {
                        continue :loop .lexing_string_literal;
                    },
                    '\n' => break :loop .invalid,
                    else => continue :loop .lexing_string_literal,
                }
            },
            .lexing_identifier => {
                if (self.is_at_end()) break :loop .identifier;
                switch (self.peek_byte()) {
                    '0'...'9', 'A'...'Z', 'a'...'z', '_' => {
                        _ = self.advance_byte();
                        continue :loop .lexing_identifier;
                    },
                    else => {
                        const token_text = self.source_code[token_start..self.next_byte_index];
                        if (get_keyword(token_text)) |tag| break :loop tag;
                        break :loop .identifier;
                    },
                }
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
                        if (self.is_at_end()) return eof_token;
                        token_start = self.next_byte_index;
                        continue :loop .start;
                    },
                    else => {
                        if (self.is_at_end()) return eof_token;
                        continue :loop .lexing_comment;
                    },
                }
            },
            .lexing_integer_literal => {
                if (self.is_at_end()) break :loop .integer_literal;
                switch (self.peek_byte()) {
                    '0'...'9' => {
                        _ = self.advance_byte();
                        continue :loop .lexing_integer_literal;
                    },
                    else => break :loop .integer_literal,
                }
            },
            .lexing_invalid_token => {
                if (self.is_at_end()) break :loop .invalid;
                switch (self.advance_byte()) {
                    '\n' => break :loop .invalid,
                    else => continue :loop .lexing_invalid_token,
                }
            },
        };

        const token_end: usize = self.next_byte_index - 1;

        return Token{
            .tag = tag,
            .loc = .init(token_start, token_end),
        };
    }

    inline fn is_at_end(self: @This()) bool {
        return self.next_byte_index >= self.source_code.len;
    }
    fn peek_byte(self: @This()) u8 {
        std.debug.assert(!self.is_at_end());
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
        lexing_identifier,
        lexing_string_literal,
    };
};

pub const Oom = std.mem.Allocator.Error;
pub const TokenizeError = error{
    too_many_tokens,
} || Oom;

pub fn tokenize(options: struct {
    gpa: std.mem.Allocator,
    source_code: []const u8,
}) TokenizeError![]Token {
    const gpa = options.gpa;
    const source_code = options.source_code;

    const estimated_tokens_count: usize = source_code.len / 3;
    var tokens = try std.ArrayList(Token).initCapacity(gpa, estimated_tokens_count);
    errdefer tokens.deinit(gpa);

    var lexer = Lexer{ .source_code = source_code };
    while (true) {
        if (tokens.items.len == TokenId.max_index) {
            return TokenizeError.too_many_tokens;
        }

        const token = lexer.next_token();
        try tokens.append(gpa, token);
        if (token.tag == .eof) break;

        // There should not be more tokens than ther are characters in the source code
        std.debug.assert(tokens.items.len <= source_code.len + 1); // +1 for eof
    }

    return try tokens.toOwnedSlice(gpa);
}

fn dump_tokens(w: *std.Io.Writer, tokens: []const Token) !void {
    try w.print("{d} tokens:\n", .{tokens.len});
    for (tokens, 0..) |token, index| {
        try w.print("{d:2} token: {s:5}, loc: {}\n", .{ index, @tagName(token.tag), token.loc });
    }
    try w.flush();
}

fn check_lexer(input: []const u8, expected: []const u8) !void {
    const gpa = std.testing.allocator;
    var tokens = std.ArrayList(Token).empty;
    defer tokens.deinit(gpa);

    var lexer = Lexer{ .source_code = input };
    while (true) {
        const token = lexer.next_token();
        try tokens.append(gpa, token);
        if (token.tag == .eof) break;
    }

    var allocating_writer = std.Io.Writer.Allocating.init(gpa);
    try dump_tokens(&allocating_writer.writer, tokens.items);
    defer allocating_writer.deinit();

    const actual: []const u8 = allocating_writer.written();

    try std.testing.expectEqualStrings(expected, actual);
}

test Lexer {
    try check_lexer("",
        \\1 tokens:
        \\ 0 token:   eof, loc: .{ .start = 0, .end = 0 }
        \\
    );
    try check_lexer("   ",
        \\1 tokens:
        \\ 0 token:   eof, loc: .{ .start = 3, .end = 3 }
        \\
    );
    try check_lexer("+",
        \\2 tokens:
        \\ 0 token:     +, loc: .{ .start = 0, .end = 0 }
        \\ 1 token:   eof, loc: .{ .start = 1, .end = 1 }
        \\
    );
    try check_lexer("1",
        \\2 tokens:
        \\ 0 token: integer_literal, loc: .{ .start = 0, .end = 0 }
        \\ 1 token:   eof, loc: .{ .start = 1, .end = 1 }
        \\
    );
    try check_lexer("20",
        \\2 tokens:
        \\ 0 token: integer_literal, loc: .{ .start = 0, .end = 1 }
        \\ 1 token:   eof, loc: .{ .start = 2, .end = 2 }
        \\
    );
    //               012345
    try check_lexer("30 + 10",
        \\4 tokens:
        \\ 0 token: integer_literal, loc: .{ .start = 0, .end = 1 }
        \\ 1 token:     +, loc: .{ .start = 3, .end = 3 }
        \\ 2 token: integer_literal, loc: .{ .start = 5, .end = 6 }
        \\ 3 token:   eof, loc: .{ .start = 7, .end = 7 }
        \\
    );
    //                012345678901234567
    try check_lexer("\n 1234567890*919-1",
        \\6 tokens:
        \\ 0 token: integer_literal, loc: .{ .start = 2, .end = 11 }
        \\ 1 token:     *, loc: .{ .start = 12, .end = 12 }
        \\ 2 token: integer_literal, loc: .{ .start = 13, .end = 15 }
        \\ 3 token:     -, loc: .{ .start = 16, .end = 16 }
        \\ 4 token: integer_literal, loc: .{ .start = 17, .end = 17 }
        \\ 5 token:   eof, loc: .{ .start = 18, .end = 18 }
        \\
    );
}

pub const TokenId = packed struct {
    index: IndexRepr,

    pub const IndexRepr = u32;
    pub const max_index = std.math.maxInt(IndexRepr);
};

pub const TokenSpan = packed struct {
    start: TokenId,
    /// The end is inclusive.
    end: TokenId,

    pub fn init(start: TokenId, end: TokenId) TokenSpan {
        std.debug.assert(start.index <= end.index);
        return TokenSpan{
            .start = start,
            .end = end,
        };
    }

    pub fn at(both_start_and_end: TokenId) TokenSpan {
        return TokenSpan{
            .start = both_start_and_end,
            .end = both_start_and_end,
        };
    }
};

pub const Ast = struct {
    source_code: []const u8,
    filepath: ?[]const u8,

    tokens: []const Token,
    nodes: []const Node,

    root_nodes: []const NodeId,

    pub fn get_node(self: Ast, id: NodeId) Node {
        return self.nodes[id.index];
    }

    pub fn get_token(self: Ast, id: TokenId) Token {
        return self.tokens[id.index];
    }

    pub fn loc_of(self: Ast, any: anytype) Loc {
        const T = @TypeOf(any);
        switch (T) {
            Loc => return any,
            Token => {
                const t: Token = any;
                return t.loc;
            },
            TokenId => {
                const token_id: TokenId = any;
                return self.get_token(token_id).loc;
            },
            TokenSpan => {
                const span: TokenSpan = any;
                const start_loc: Loc = self.loc_of(span.start);
                const end_loc: Loc = self.loc_of(span.end);
                return Loc.init(start_loc.start, end_loc.end);
            },
            Node => {
                const n: Node = any;
                return self.loc_of(n.span);
            },
            NodeId => {
                const node_id: NodeId = any;
                return self.loc_of(self.get_node(node_id));
            },
            else => @compileError("Invalid type: " ++ @typeName(T)),
        }
    }

    pub inline fn text_at(self: Ast, any: anytype) []const u8 {
        const loc: Loc = self.loc_of(any);
        return loc.slice_from(self.source_code);
    }
};

/// Prints the AST in the following format:
///
/// AST of path/to/source-code.ree
///
/// [1:1-10:1] binary_op(sub)
/// ├─lhs: [4:4-4:8] binary_op(add)
/// │      ├─lhs: [4:4-4:8] binary_op(mul)
/// │      │      ├─lhs: [4:4-4:8] integer_literal '61'
/// │      │      └─rhs: [9:4-4:4] integer_literal '491'
/// │      └─rhs: [4:4-4:8] binary_op(mul)
/// │             ├─lhs: [4:4-4:8] integer_literal '53'
/// │             └─rhs: [4:4-4:8] integer_literal '0'
/// └─rhs: [4:4-4:8] binary_op(div)
///        ├─lhs: [4:4-4:8] integer_literal '5'
///        └─rhs: [4:4-4:8] integer_literal '1000'
///
pub fn print_ast(
    ast: Ast,
    terminal: std.Io.Terminal,
    tmp_allocator: std.mem.Allocator,
) !void {
    var prefix = try std.ArrayList(u8).initCapacity(tmp_allocator, 100);
    defer prefix.deinit(tmp_allocator);
    for (ast.root_nodes) |node_id| {
        try print_node(
            ast,
            terminal,
            node_id,
            &prefix,
            tmp_allocator,
        );
        std.debug.assert(prefix.items.len == 0);
    }
    try terminal.writer.flush();
}
fn print_node(
    ast: Ast,
    terminal: std.Io.Terminal,
    node_id: NodeId,
    prefix: *std.ArrayList(u8),
    gpa: std.mem.Allocator,
) !void {
    const w = terminal.writer;
    const t = terminal;
    const main_color = std.Io.Terminal.Color.magenta;

    const node = ast.get_node(node_id);

    // Print the location
    try print_location(t, ast, ast.loc_of(node));

    // Print the tag
    {
        try w.print(" ", .{});
        try t.setColor(.bold);
        try t.setColor(main_color);
        try w.print("{t}", .{node.data.tag()});
        try t.setColor(.reset);
    }

    print_node_data: switch (node.data) {
        inline .type_pointer, .type_slice => |info| {
            if (info.const_token) |const_token| {
                // ('const')
                try w.print(" ('", .{});
                try t.setColor(.green);
                try w.print("{s}", .{ast.text_at(const_token)});
                try t.setColor(.reset);
                try w.print("')", .{});
            }
            try w.print("\n", .{});

            const ch = try start_child(gpa, w, prefix, .last, "of", .{});
            defer ch.end_child();

            try print_node(ast, t, info.child_type, prefix, gpa);
        },
        .assignment => |info| {
            try w.print("\n", .{});
            {
                const ch = try start_child(gpa, w, prefix, .non_last, "dest", .{});
                defer ch.end_child();
                try print_node(ast, t, info.dest, prefix, gpa);
            }
            {
                const ch = try start_child(gpa, w, prefix, .last, "src", .{});
                defer ch.end_child();
                try print_node(ast, t, info.src, prefix, gpa);
            }
        },
        .return_statement => |info| {
            try w.print("\n", .{});
            const ch = try start_child(gpa, w, prefix, .last, "expr", .{});
            defer ch.end_child();
            try print_node(ast, t, info.return_value, prefix, gpa);
        },
        .integer_literal => {
            // '42'
            const text = ast.text_at(node);
            try w.print(" '", .{});
            try t.setColor(.green);
            try w.print("{s}", .{text});
            try t.setColor(.reset);
            try w.print("'", .{});
            try w.print("\n", .{});
        },
        .string_literal => {
            // '"hello :)"'
            const text = ast.text_at(node);
            try w.print(" '", .{});
            try t.setColor(.green);
            try w.print("{s}", .{text});
            try t.setColor(.reset);
            try w.print("'", .{});
            try w.print("\n", .{});
        },
        .identifier => {
            // 'someVariable'
            const text = ast.text_at(node);
            try w.print(" '", .{});
            try t.setColor(.green);
            try w.print("{s}", .{text});
            try t.setColor(.reset);
            try w.print("'", .{});
            try w.print("\n", .{});
        },
        .function_call => |info| {
            const args: []const NodeId = info.args;
            try w.print(" {d} argument{s}", .{ args.len, if (args.len == 1) "" else "s" });
            try w.print("\n", .{});

            {
                const ch = try start_child(gpa, w, prefix, .is_last(args.len == 0), "fn", .{});
                defer ch.end_child();
                try print_node(ast, t, info.function, prefix, gpa);
            }

            for (args, 0..) |arg, index| {
                const ch = try start_child(gpa, w, prefix, .is_last(index + 1 == args.len), "arg{d}", .{index});
                defer ch.end_child();
                try print_node(ast, t, arg, prefix, gpa);
            }
        },
        .field_access => |info| {
            // of 'fieldName'
            const text = ast.text_at(info.field);
            try w.print(" of '", .{});
            try t.setColor(.green);
            try w.print("{s}", .{text});
            try t.setColor(.reset);
            try w.print("'", .{});
            try w.print("\n", .{});

            try w.print("{s}", .{prefix.items});
            try w.print("└─in: ", .{});
            try prefix.appendSlice(gpa, "      ");
            try print_node(ast, t, info.lhs, prefix, gpa);
            prefix.items.len -= ("      ").len;
        },
        .binary_op => |info| {
            // (add)
            try w.print("(", .{});
            try t.setColor(.bold);
            try t.setColor(main_color);
            try w.print("{t}", .{info.kind});
            try t.setColor(.reset);
            try w.print(")", .{});

            try w.print("\n", .{});

            try w.print("{s}", .{prefix.items});
            try w.print("├─{s}: ", .{if (info.kind == .array_access) "arr" else "lhs"});
            try prefix.appendSlice(gpa, "│      ");
            try print_node(ast, t, info.lhs, prefix, gpa);
            prefix.items.len -= ("│      ").len;

            try w.print("{s}", .{prefix.items});
            try w.print("└─{s}: ", .{if (info.kind == .array_access) "idx" else "rhs"});
            try prefix.appendSlice(gpa, "       ");
            try print_node(ast, t, info.rhs, prefix, gpa);
            prefix.items.len -= ("       ").len;
        },
        .unary_op => |info| {
            // (minus)
            try w.print("(", .{});
            try t.setColor(.bold);
            try t.setColor(main_color);
            try w.print("{t}", .{info.kind});
            try t.setColor(.reset);
            try w.print(")", .{});

            try w.print("\n", .{});

            try w.print("{s}", .{prefix.items});
            try w.print("└─in: ", .{});
            try prefix.appendSlice(gpa, "      ");
            try print_node(ast, t, info.operand, prefix, gpa);
            prefix.items.len -= ("      ").len;
        },
        .parentheses => |info| {
            try w.print("\n", .{});

            try w.print("{s}", .{prefix.items});
            try w.print("└─in: ", .{});
            try prefix.appendSlice(gpa, "      ");
            try print_node(ast, t, info.inner, prefix, gpa);
            prefix.items.len -= ("      ").len;
        },
        .declaration => |info| {
            // (var)
            try w.print("(", .{});
            try t.setColor(main_color);
            try t.setColor(.bold);
            try w.print("{t}", .{info.kind});
            try t.setColor(.reset);
            try w.print(")", .{});
            // of 'identifier'
            try w.print(" of '", .{});
            try t.setColor(.green);
            try w.print("{s}", .{ast.text_at(info.identifier)});
            try t.setColor(.reset);
            try w.print("'\n", .{});

            // Type of the declaration
            try w.print("{s}", .{prefix.items});
            try w.print("├─type: ", .{});
            if (info.explicit_type) |explicit_type| {
                try prefix.appendSlice(gpa, "│       ");
                try print_node(ast, t, explicit_type, prefix, gpa);
                prefix.items.len -= "│       ".len;
            } else {
                try t.setColor(.dim);
                try w.print("(not specified)", .{});
                try t.setColor(.reset);
                try w.print("\n", .{});
            }

            // The initial value
            try w.print("{s}", .{prefix.items});
            try w.print("└─init: ", .{});
            if (info.inital_value) |initial_value| {
                try prefix.appendSlice(gpa, "        ");
                try print_node(ast, t, initial_value, prefix, gpa);
                prefix.items.len -= ("        ").len;
            } else {
                try t.setColor(.dim);
                try w.print("(not specified)", .{});
                try t.setColor(.reset);
                try w.print("\n", .{});
            }
        },
        .function_literal => |info| {
            try w.print("\n", .{});
            {
                const ch = try start_child(gpa, w, prefix, .non_last, "header", .{});
                defer ch.end_child();
                try print_node(ast, t, info.header_id, prefix, gpa);
            }
            {
                const ch = try start_child(gpa, w, prefix, .last, "body", .{});
                defer ch.end_child();
                try print_node(ast, t, info.body_id, prefix, gpa);
            }
        },
        .struct_literal => |info| {
            const fmt = FmtTerminal.from_std_terminal(t);
            try fmt.print(" with {d} field{s}\n", .{ info.initializers.len, if (info.initializers.len == 1) "" else "s" });
            {
                const ch = try start_child(gpa, w, prefix, .is_last(info.initializers.len == 0), "type", .{});
                defer ch.end_child();
                try print_node(ast, t, info.type, prefix, gpa);
            }

            for (info.initializers, 0..) |initializer, index| {
                const ch_f = try start_child(gpa, w, prefix, .is_last(index + 1 == info.initializers.len), "field{d}", .{index});
                defer ch_f.end_child();
                try print_location(t, ast, ast.loc_of(initializer.identifier));
                try fmt.print(" '{GREEN}{s}{RESET}'\n", .{ast.text_at(initializer.identifier)});

                const ch_r = try start_child(gpa, w, prefix, .last, "init", .{});
                defer ch_r.end_child();
                try print_node(ast, t, initializer.rhs, prefix, gpa);
            }
        },
        .block => |info| {
            const statements = info.statements;
            try w.print(" with {d} statement{s}", .{ statements.len, if (statements.len == 1) "" else "s" });

            if (statements.len != 0) {
                try w.print(":\n", .{});
                for (statements, 0..) |statement, index| {
                    const ch = try start_child(gpa, w, prefix, .is_last(index + 1 == statements.len), "{d}", .{index});
                    defer ch.end_child();
                    try print_node(ast, t, statement, prefix, gpa);
                }
            } else {
                try w.print("\n", .{});
            }
        },
        .type_struct => |info| {
            const fields = info.fields;

            try w.print(" with {d} field{s}\n", .{ fields.len, if (fields.len == 1) "" else "s" });
            for (fields, 0..) |field, index| {
                const f = try start_child(gpa, w, prefix, .is_last(index + 1 == fields.len), "field{d}", .{index});
                defer f.end_child();

                try print_location(t, ast, ast.loc_of(field.identifier));
                try w.print(" '", .{});
                try t.setColor(.green);
                try w.print("{s}", .{ast.text_at(field.identifier)});
                try t.setColor(.reset);
                try w.print("'\n", .{});

                const ty = try start_child(gpa, w, prefix, .last, "type", .{});
                defer ty.end_child();

                try print_node(ast, t, field.type, prefix, gpa);
            }
        },
        .type_function => |info| {
            continue :print_node_data ast.get_node(info.header).data;
        },
        .function_header => |info| {
            const params = info.params;
            try w.print(" {d} param{s}", .{ params.len, if (params.len == 1) "" else "s" });

            if (params.len != 0) {
                try w.print(":\n", .{});
                for (params, 0..) |param, index| {
                    const ch = try start_child(gpa, w, prefix, .non_last, "param{d}", .{index});
                    defer ch.end_child();
                    try print_node(ast, t, param, prefix, gpa);
                }
            } else {
                try w.print("\n", .{});
            }

            const ch = try start_child(gpa, w, prefix, .last, "return_type", .{});
            defer ch.end_child();

            if (info.return_type) |return_type| {
                try print_node(ast, t, return_type, prefix, gpa);
            } else {
                try w.print("implicit ", .{});
                try t.setColor(main_color);
                try t.setColor(.bold);
                try w.print("void", .{});
                try t.setColor(.reset);
                try w.print("\n", .{});
            }
        },
        .parameter => |info| {
            // 'someVariable'
            try w.print(" '", .{});
            try t.setColor(.green);
            try w.print("{s}", .{ast.text_at(info.identifier)});
            try t.setColor(.reset);
            try w.print("'", .{});
            try w.print("\n", .{});

            const ch = try start_child(gpa, w, prefix, .last, "type", .{});
            defer ch.end_child();

            try print_node(ast, t, info.type, prefix, gpa);
        },
    }
}
fn print_location(t: std.Io.Terminal, ast: Ast, loc: Loc) !void {
    // PERF: The `calculate_line_info` uses O(source_code.len) search.
    // It will be fine for small inputs, but for larger, it could be a problem.
    // NOTE: In such case, precalculate line beginnings and use a binary-search.
    const start = Reporter.calculate_line_info(ast.source_code, loc.start);
    const end = Reporter.calculate_line_info(ast.source_code, loc.end);
    try t.setColor(.dim);
    try t.writer.print("[{d}:{d}-{d}:{d}]", .{ start.line, start.column, end.line, end.column });
    try t.setColor(.reset);
}

fn start_child(
    gpa: std.mem.Allocator,
    w: *std.Io.Writer,
    prefix: *std.ArrayList(u8),
    last: enum {
        last,
        non_last,
        pub fn is_last(l: bool) @This() {
            return if (l) .last else .non_last;
        }
    },
    comptime fmt: []const u8,
    args: anytype,
) !PrintChild {
    try w.print("{s}", .{prefix.items});

    const length_before = prefix.items.len;
    switch (last) {
        .last => {
            const full_fmt = "└─" ++ fmt ++ ": ";
            try w.print(full_fmt, args);

            const byte_count = std.fmt.count(full_fmt, args);
            const spaces_count = byte_count + ("  ".len) - ("└─".len);
            try prefix.appendNTimes(gpa, ' ', spaces_count);
        },
        .non_last => {
            const full_fmt = "├─" ++ fmt ++ ": ";
            try w.print(full_fmt, args);

            const byte_count = std.fmt.count(full_fmt, args);
            const spaces_count = byte_count + ("  ".len) - ("├─".len) - 1; // `-1` for the `│` character
            try prefix.appendSlice(gpa, "│");
            try prefix.appendNTimes(gpa, ' ', spaces_count);
        },
    }
    return PrintChild{ .prefix = prefix, .original_length = length_before };
}
const PrintChild = struct {
    prefix: *std.ArrayList(u8),
    original_length: usize,

    pub fn end_child(self: PrintChild) void {
        self.prefix.items.len = self.original_length;
    }
};

pub const Node = struct {
    span: TokenSpan,
    data: NodeData,
};

pub const NodeData = union(enum) {
    // === Expressions ===
    integer_literal,
    string_literal,
    function_literal: *const FunctionLiteral,
    struct_literal: StructLiteral,
    identifier,
    binary_op: BinaryOp,
    unary_op: UnaryOp,
    function_call: FunctionCall,
    parentheses: packed struct { inner: NodeId },
    field_access: FieldAccess,

    // === Statements ===
    declaration: Declaration,
    block: Block,
    assignment: Assignment,
    return_statement: Return,

    // === Types ===
    type_pointer: struct {
        const_token: ?TokenId,
        child_type: NodeId,
    },
    type_slice: struct {
        const_token: ?TokenId,
        child_type: NodeId,
    },
    type_function: struct {
        /// Guaranteed to be `function_header`
        header: NodeId,
    },
    type_struct: Struct,

    // === Msc ===
    function_header: *const FunctionHeader,
    parameter: Parameter,

    pub const Tag = std.meta.Tag(NodeData);
    pub inline fn tag(self: NodeData) Tag {
        return std.meta.activeTag(self);
    }
};

pub const StructLiteral = struct {
    type: NodeId,
    initializers: []const Initializer,
};
pub const Initializer = struct {
    identifier: TokenId,
    rhs: NodeId,
};

pub const Return = struct {
    return_value: NodeId,
};

pub const Struct = struct {
    fields: []const Field,
};

pub const Field = struct {
    identifier: TokenId,
    type: NodeId,
};

pub const FunctionHeader = struct {
    /// Guaranteed to represent `[]const Parameter`
    params: []const NodeId,
    return_type: ?NodeId,
};

pub const FunctionLiteral = struct {
    /// Guaranteed to be `function_header`
    header_id: NodeId,
    /// Guaranteed to be `body`
    body_id: NodeId,
};

pub const Block = struct {
    statements: []const NodeId,
};

pub const Parameter = struct {
    identifier: TokenId,
    type: NodeId,
};

pub const Assignment = struct {
    dest: NodeId,
    token_equals: TokenId,
    src: NodeId,
};

pub const Declaration = struct {
    identifier: TokenId,
    kind: Kind,
    inital_value: ?NodeId,
    explicit_type: ?NodeId,

    pub fn val_or_var_token(decl: Declaration) TokenId {
        return TokenId{ .index = decl.identifier.index - 1 };
    }

    pub const Kind = enum(u1) { val, @"var" };
};

pub const Type = union(enum) {
    int: Int,
    slice: Slice,

    pub const Int = struct {
        bits: u8,
        sign: enum(u1) { signed, unsigned },
    };
    pub const Slice = struct {
        child: TypeId,
    };
};

pub const TypeId = packed struct {
    index: u64,
};

pub const FunctionCall = struct {
    function: NodeId,
    args: []const NodeId,
};

const AlignmentOfExtra = @alignOf(u64);
pub const Extra = []align(AlignmentOfExtra) const u8;
pub const ExtraDynList = std.ArrayListAligned(u8, .fromByteUnits(AlignmentOfExtra));

pub const FieldAccess = packed struct {
    lhs: NodeId,
    field: TokenId,
};

pub const NodeId = packed struct {
    index: IndexRepr,
    pub const IndexRepr = u32;
    pub const max_index = std.math.maxInt(IndexRepr);
};

pub const UnaryOp = packed struct {
    operand: NodeId,
    kind: Kind,

    pub const Kind = enum(u8) {
        plus,
        minus,
    };
};

pub const BinaryOp = packed struct {
    lhs: NodeId,
    rhs: NodeId,
    kind: Kind,

    pub const Kind = enum(u8) {
        add,
        sub,
        mul,
        div,

        /// Example: `arr[idx]`
        /// - `lhs` is `arr`
        /// - `rhs` is `idx`
        array_access,

        /// Example: `person.age`
        /// - `lhs` is `person`
        /// - `rhs` is `age`
        field_access,
    };
};

pub const Reporter = struct {
    source_code: []const u8,
    filepath: ?[]const u8,
    terminal: std.Io.Terminal,

    pub fn info(self: *Reporter, where: Where, comptime fmt: []const u8, args: anytype) void {
        self.report(.info, where, fmt, args);
    }
    pub fn help(self: *Reporter, where: Where, comptime fmt: []const u8, args: anytype) void {
        self.report(.help, where, fmt, args);
    }
    pub fn warn(self: *Reporter, where: Where, comptime fmt: []const u8, args: anytype) void {
        self.report(.warn, where, fmt, args);
    }
    pub fn err(self: *Reporter, where: Where, comptime fmt: []const u8, args: anytype) void {
        self.report(.err, where, fmt, args);
    }
    pub fn report(self: *Reporter, level: Level, where: Where, comptime fmt: []const u8, args: anytype) void {
        // Diagnostics are best-effort: a broken stderr must not take down the compiler.
        self.emit(level, where, fmt, args) catch {};
        self.terminal.writer.flush() catch {};
    }

    pub const Level = enum {
        info,
        help,
        warn,
        err,

        fn name(l: Level) []const u8 {
            return switch (l) {
                .info => "INFO",
                .help => "HELP",
                .warn => "WARN",
                .err => "ERROR",
            };
        }

        fn color(l: Level) std.Io.Terminal.Color {
            return switch (l) {
                .info => .bright_blue,
                .help => .bright_cyan,
                .warn => .bright_yellow,
                .err => .bright_red,
            };
        }
    };

    pub const Where = union(enum) {
        no_location,
        file_scope,
        location: Loc,

        pub fn loc(l: Loc) Where {
            return .{ .location = l };
        }
    };

    fn emit(
        self: *Reporter,
        level: Level,
        where: Where,
        comptime fmt: []const u8,
        args: anytype,
    ) !void {
        const t = &self.terminal;
        const w = self.terminal.writer;
        const path = self.filepath orelse "<source>";
        const src = self.source_code;

        const maybe_loc: ?Loc = switch (where) {
            .location => |loc| loc,
            .no_location, .file_scope => null,
        };
        const start = if (maybe_loc) |loc| @min(loc.start, src.len) else 0;
        const line_info = calculate_line_info(src, start);

        // `[ERROR at path/to/source/code.ree:12:15]`
        try t.setColor(.bold);
        try w.writeByte('[');
        try t.setColor(level.color());
        try w.writeAll(level.name());
        try t.setColor(.reset);
        try t.setColor(.bold);
        switch (where) {
            .no_location => {},
            .file_scope => try w.print(" at {s}", .{path}),
            .location => try w.print(" at {s}:{d}:{d}", .{ path, line_info.line, line_info.column }),
        }
        try w.writeAll("]");
        try t.setColor(.reset);
        try w.writeByte('\n');

        // `The error message for the programmer.`
        try w.print(fmt, args);
        try w.writeByte('\n');

        const l = maybe_loc orelse return;

        var num_buf: [512]u8 = undefined;
        comptime std.debug.assert(num_buf.len > std.fmt.count("{d}", .{std.math.maxInt(usize)}));
        const num = std.fmt.bufPrint(&num_buf, "{d}", .{line_info.line}) catch unreachable;
        // ` 2 |`, ` 12 |`: one space on each side of the line number.
        const gutter = num.len + 2;

        var line_text = src[line_info.start..line_info.end];
        if (line_text.len > 0 and line_text[line_text.len - 1] == '\r') line_text.len -= 1;

        // `end` is inclusive; clamp a multi-line span to the end of this line.
        const span_end = @min(@max(l.end +| 1, start + 1), line_info.end);
        const width = @max(span_end -| start, 1);

        // Highlighted slice of the source line (may be empty, e.g. at end of line).
        const hl_start = @min(start - line_info.start, line_text.len);
        const hl_end = @max(@min(span_end - line_info.start, line_text.len), hl_start);

        // `   |`
        try t.setColor(.dim);
        try pad(w, gutter);
        try w.writeAll("|\n");

        // ` 2 |  oh(this) is = bad;`  (with `this` colored + bold)
        try w.writeByte(' ');
        try w.writeAll(num);
        try w.writeAll(" | ");
        try t.setColor(.reset);
        try w.writeAll(line_text[0..hl_start]);
        try t.setColor(.bold);
        try t.setColor(level.color());
        try w.writeAll(line_text[hl_start..hl_end]);
        try t.setColor(.reset);
        try w.writeAll(line_text[hl_end..]);
        try w.writeByte('\n');

        // `   |      ^^^^`
        try t.setColor(.dim);
        try pad(w, gutter);
        try w.writeAll("| ");
        try t.setColor(.reset);
        // Copy tabs verbatim so the carets line up with a tab-indented line.
        for (src[line_info.start..start]) |c| try w.writeByte(if (c == '\t') '\t' else ' ');

        try t.setColor(.dim);
        try t.setColor(level.color());
        for (0..width) |_| try w.writeByte('^');
        try t.setColor(.reset);
        try w.writeByte('\n');
    }

    const LineInfo = struct {
        /// 1-based
        line: usize,
        /// 1-based, in bytes
        column: usize,
        /// Byte index of the first character of the line
        start: usize,
        /// Byte index one past the last character, excluding the newline
        end: usize,
    };

    fn calculate_line_info(source: []const u8, index: usize) LineInfo {
        var line: usize = 1;
        var line_start: usize = 0;
        for (source[0..index], 0..) |c, i| {
            if (c == '\n') {
                line += 1;
                line_start = i + 1;
            }
        }
        var line_end = line_start;
        while (line_end < source.len and source[line_end] != '\n') line_end += 1;
        return .{
            .line = line,
            .column = index - line_start + 1,
            .start = line_start,
            .end = line_end,
        };
    }

    fn pad(w: *std.Io.Writer, n: usize) !void {
        for (0..n) |_| try w.writeByte(' ');
    }
};

pub const TokenWithId = packed struct {
    loc: Loc,
    tag: Token.Tag,
    id: TokenId,

    pub fn init(token: Token, id: TokenId) TokenWithId {
        return TokenWithId{
            .loc = token.loc,
            .tag = token.tag,
            .id = id,
        };
    }

    pub fn span(self: TokenWithId) TokenSpan {
        return .at(self.id);
    }

    pub fn as_token(self: TokenWithId) Token {
        return Token{
            .loc = self.loc,
            .tag = self.tag,
        };
    }
};

pub const ParseError = error{
    invalid_syntax,
} || Oom;

pub const Parser = struct {
    reporter: *Reporter,
    gpa: std.mem.Allocator,
    tokens: []const Token,
    next_token_id: TokenId,
    nodes: std.ArrayList(Node),
    is_parsing_return_type: bool = false,

    pub fn parse(self: *Parser) ParseError!Ast {
        errdefer self.nodes.deinit(self.gpa);

        var root_node_ids = std.ArrayList(NodeId).empty;
        errdefer root_node_ids.deinit(self.gpa);

        while (self.peek_token().tag != .eof) {
            const decl: NodeId = self.parse_declaration() catch |err| switch (err) {
                Reported.already_reported => return ParseError.invalid_syntax,
                Oom.OutOfMemory => return Oom.OutOfMemory,
            };
            try root_node_ids.append(self.gpa, decl);

            if (self.advance_token().tag != .@";") {
                const unexpected = self.previous_token();
                self.reporter.err(.loc(unexpected.loc), "Expected ';' after a declaration, found '{t}'.", .{unexpected.tag});
                return ParseError.invalid_syntax;
            }
        }
        std.debug.assert(self.advance_token().tag == .eof);

        const finalized_nodes: []const Node = try self.nodes.toOwnedSlice(self.gpa);
        const finalized_roots: []const NodeId = try root_node_ids.toOwnedSlice(self.gpa);

        return Ast{
            .source_code = self.reporter.source_code,
            .filepath = self.reporter.filepath,
            .tokens = self.tokens,
            .nodes = finalized_nodes,
            .root_nodes = finalized_roots,
        };
    }

    const Reported = error{already_reported};
    const InnerError = Oom || Reported;

    /// ```
    /// ('val'|'var') (':' Type)? '=' Expression
    /// ```
    /// Note that `Type` is the same as `Expression`
    fn parse_declaration(self: *Parser) InnerError!NodeId {
        const val_var_token = self.advance_token();
        const kind: Declaration.Kind = switch (val_var_token.tag) {
            .kw_val => .val,
            .kw_var => .@"var",
            else => {
                const unexpected = val_var_token;
                self.reporter.err(.loc(unexpected.loc), "Expected a declaration starting with `val` or `var`. Found '{t}'.", .{unexpected.tag});
                return Reported.already_reported;
            },
        };

        const identifier_token: TokenWithId = try self.advance_token_expect(.identifier);

        const explicit_type: ?NodeId = if (self.eat_token(.@":") != null) blk: {
            break :blk try self.parse_expression(.{ .min_bp = 0 });
        } else null;

        _ = try self.advance_token_expect(.@"=");

        const init_expression: NodeId = try self.parse_expression(.{ .min_bp = 0 });

        return try self.add_node(
            self.span_surrounding(val_var_token, init_expression),
            .{ .declaration = Declaration{
                .explicit_type = explicit_type,
                .identifier = identifier_token.id,
                .inital_value = init_expression,
                .kind = kind,
            } },
        );
    }

    fn parse_function_header(self: *Parser, options: struct { min_bp: BindingPower }) InnerError!NodeId {
        const fn_token = try self.advance_token_expect(.kw_fn);
        const params: []const NodeId = try self.parse_parameter_list();

        var header_end_token = self.previous_token().id;
        var maybe_return_type: ?NodeId = null;

        var expecting_explicit_return_type: bool = false;
        if (self.peek_token().tag == .@"^") expecting_explicit_return_type = true;
        if (self.peek_token().tag == .@"[") expecting_explicit_return_type = true;
        if (self.peek_token().tag == .@"(") expecting_explicit_return_type = true;
        if (self.peek_token().tag == .kw_fn) expecting_explicit_return_type = true;
        if (self.peek_token().tag == .identifier) expecting_explicit_return_type = true;

        if (expecting_explicit_return_type) {
            const was_parsing_return_type = self.is_parsing_return_type;
            defer self.is_parsing_return_type = was_parsing_return_type;
            self.is_parsing_return_type = true;
            //
            const return_type = self.parse_expression(.{ .min_bp = options.min_bp }) catch |err| {
                if (err == Reported.already_reported) {
                    const span = self.span_surrounding(fn_token, header_end_token);
                    self.reporter.info(.loc(self.loc_of(span)), "Error occured while trying to parse the return type for this function:", .{});
                }
                return err;
            };
            header_end_token = self.span_of(return_type).end;
            maybe_return_type = return_type;
        }

        const header_data = try self.gpa.create(FunctionHeader);
        header_data.* = FunctionHeader{ .params = params, .return_type = maybe_return_type };

        return try self.add_node(
            self.span_surrounding(fn_token, header_end_token),
            .{ .function_header = header_data },
        );
    }

    ///```
    /// '('  ( Identifier ':' Expr ),*  ','? ')'
    ///```
    fn parse_parameter_list(self: *Parser) InnerError![]const NodeId {
        var params = std.ArrayList(NodeId).empty;
        defer params.deinit(self.gpa);

        _ = try self.advance_token_expect(.@"(");

        var first_iter: bool = true;
        while (self.peek_token().tag != .@")") : (first_iter = false) {
            if (!first_iter) {
                _ = try self.advance_token_expect(.@",");
                if (self.peek_token().tag == .@")") break; // Trailing comma detected
            }
            const identifier = try self.advance_token_expect(.identifier);
            _ = try self.advance_token_expect(.@":");
            const type_expr: NodeId = try self.parse_expression(.{ .min_bp = 0 });

            const param = try self.add_node(self.span_surrounding(identifier, type_expr), .{
                .parameter = Parameter{ .identifier = identifier.id, .type = type_expr },
            });
            try params.append(self.gpa, param);
        }
        std.debug.assert(self.advance_token().tag == .@")");

        return try params.toOwnedSlice(self.gpa);
    }

    ///```
    ///
    ///  '{'
    ///      (
    ///         (Declaration ';')   |   (Expr (= Expr)? ';')   |   Block
    ///      )*
    ///  '}'
    ///
    ///```
    fn parse_block(self: *Parser) InnerError!NodeId {
        var statements = std.ArrayList(NodeId).empty;
        defer statements.deinit(self.gpa);

        const opening_brace = try self.advance_token_expect(.@"{");

        while (self.peek_token().tag != .@"}") {
            var expececting_semicolon = true;
            const statement: NodeId = parse_statement: switch (self.peek_token().tag) {
                .kw_val, .kw_var => try self.parse_declaration(),
                .kw_return => {
                    const return_keyword = self.advance_token();
                    const return_value: NodeId = try self.parse_expression(.{ .min_bp = 0 });
                    //
                    const span = self.span_surrounding(return_keyword, return_value);
                    break :parse_statement try self.add_node(span, .{ .return_statement = .{ .return_value = return_value } });
                },
                .@"{" => {
                    expececting_semicolon = false;
                    break :parse_statement try self.parse_block();
                },
                else => {
                    // Expecting an expression.
                    const expr: NodeId = try self.parse_expression(.{ .min_bp = 0 });
                    const token_equals = self.eat_token(.@"=") orelse break :parse_statement expr;

                    const rhs: NodeId = try self.parse_expression(.{ .min_bp = 0 });
                    break :parse_statement try self.add_node(self.span_surrounding(expr, rhs), .{
                        .assignment = .{ .dest = expr, .src = rhs, .token_equals = token_equals.id },
                    });
                },
            };
            try statements.append(self.gpa, statement);

            if (expececting_semicolon) {
                if (self.advance_token().tag != .@";") {
                    const unexpected = self.previous_token();
                    self.reporter.err(.loc(unexpected.loc), "Expected a ';' after a statement, found '{t}'.", .{unexpected.tag});
                    self.reporter.help(.loc(self.loc_of(statement)), "Try putting a ';' after this statement:", .{});
                    return Reported.already_reported;
                }
            } else {
                if (self.peek_token().tag == .@";") {
                    const semicolon = self.peek_token();
                    self.reporter.err(.loc(semicolon.loc), "Found a semicolon where it should not be.", .{});
                    return Reported.already_reported;
                }
            }
        }
        const closing_brace = self.advance_token();
        std.debug.assert(closing_brace.tag == .@"}");

        const finalized_statements: []const NodeId = try statements.toOwnedSlice(self.gpa);
        return try self.add_node(
            self.span_surrounding(opening_brace, closing_brace),
            .{ .block = Block{ .statements = finalized_statements } },
        );
    }

    ///```
    ///  'struct' '{'
    ///       ( Identifier ':' Expr ';' )*
    ///  '}'
    ///```
    fn parse_struct(self: *Parser) InnerError!NodeId {
        const struct_keyword: TokenWithId = try self.advance_token_expect(.kw_struct);
        _ = try self.advance_token_expect(.@"{");

        var fields = std.ArrayList(Field).empty;
        defer fields.deinit(self.gpa);

        while (self.peek_token().tag != .@"}") {
            const identifier = try self.advance_token_expect(.identifier);
            _ = try self.advance_token_expect(.@":");
            const type_expr: NodeId = try self.parse_expression(.{ .min_bp = 0 });
            _ = try self.advance_token_expect(.@";");

            try fields.append(self.gpa, Field{ .identifier = identifier.id, .type = type_expr });
        }

        const closing_brace = self.advance_token();
        std.debug.assert(closing_brace.tag == .@"}");

        const span = self.span_surrounding(struct_keyword, closing_brace);
        const finalized_fields = try fields.toOwnedSlice(self.gpa);
        return try self.add_node(span, .{ .type_struct = .{ .fields = finalized_fields } });
    }

    ///```
    ///  ( '.' Identifier '=' Expr ';' )*
    ///```
    fn parse_initializers(self: *Parser) InnerError![]const Initializer {
        var initializers = std.ArrayList(Initializer).empty;
        defer initializers.deinit(self.gpa);

        while (self.peek_token().tag == .@".") {
            _ = self.advance_token();
            const identfier = try self.advance_token_expect(.identifier);
            _ = try self.advance_token_expect(.@"=");
            const init_expr: NodeId = try self.parse_expression(.{ .min_bp = 0 });
            _ = try self.advance_token_expect(.@";");

            try initializers.append(self.gpa, .{ .identifier = identfier.id, .rhs = init_expr });
        }

        return try initializers.toOwnedSlice(self.gpa);
    }

    fn parse_expression(self: *Parser, options: struct { min_bp: BindingPower }) InnerError!NodeId {
        const min_bp = options.min_bp;

        var lhs: NodeId = parse_atom: {
            const token = self.advance_token();
            break :parse_atom switch (token.tag) {
                .integer_literal => try self.add_node(token.span(), .integer_literal),
                .string_literal => try self.add_node(token.span(), .string_literal),
                .identifier => try self.add_node(token.span(), .identifier),
                .kw_struct => {
                    self.unget_token();
                    break :parse_atom try self.parse_struct();
                },
                .kw_fn => parse_fn_type_or_fn_literal: {
                    self.unget_token();
                    const header: NodeId = try self.parse_function_header(.{ .min_bp = min_bp });

                    var should_parse_body = true;
                    if (self.is_parsing_return_type) should_parse_body = false;
                    if (self.peek_token().tag != .@"{") should_parse_body = false;

                    if (!should_parse_body) {
                        const fn_type = NodeData{ .type_function = .{ .header = header } };
                        break :parse_fn_type_or_fn_literal try self.add_node(self.span_of(header), fn_type);
                    }

                    const body: NodeId = try self.parse_block();
                    const function_literal = try self.gpa.create(FunctionLiteral);
                    function_literal.* = .{
                        .body_id = body,
                        .header_id = header,
                    };
                    break :parse_fn_type_or_fn_literal try self.add_node(
                        self.span_surrounding(token, body),
                        .{ .function_literal = function_literal },
                    );
                },

                // Parse unary prefix operator
                inline .@"+", .@"-" => |op_token_tag| {
                    const binding_power = prefix_binding_power(comptime op_token_tag);
                    const rhs = try self.parse_expression(.{ .min_bp = binding_power.right });
                    const kind: UnaryOp.Kind = switch (comptime op_token_tag) {
                        .@"+" => .plus,
                        .@"-" => .minus,
                        else => |unexpected| @compileError("Unexpected token tag: " ++ @tagName(unexpected)),
                    };
                    break :parse_atom try self.add_node(
                        self.span_surrounding(token, rhs),
                        .{ .unary_op = .{ .operand = rhs, .kind = kind } },
                    );
                },
                // Parse unary prefix operator for types (such as `[]u8` or `^const f32`)
                inline .@"[", .@"^" => |op_token_tag| {
                    if (op_token_tag == .@"[") {
                        _ = try self.advance_token_expect(.@"]");
                    }
                    const const_token: ?TokenId = if (self.eat_token(.kw_const)) |tok| tok.id else null;
                    const binding_power = prefix_binding_power(comptime op_token_tag);
                    const child_type: NodeId = try self.parse_expression(.{ .min_bp = binding_power.right });
                    const span = self.span_surrounding(token, child_type);
                    break :parse_atom switch (comptime op_token_tag) {
                        .@"[" => try self.add_node(span, .{ .type_slice = .{ .child_type = child_type, .const_token = const_token } }),
                        .@"^" => try self.add_node(span, .{ .type_pointer = .{ .child_type = child_type, .const_token = const_token } }),
                        else => |unexpected| @compileError("Unexpected token tag: " ++ @tagName(unexpected)),
                    };
                },

                // Parse parenthesized expression
                .@"(" => {
                    const was_parsing_return_type = self.is_parsing_return_type;
                    defer self.is_parsing_return_type = was_parsing_return_type;
                    self.is_parsing_return_type = false;

                    const inner: NodeId = try self.parse_expression(.{ .min_bp = 0 });
                    const closing_parenthesis = self.advance_token();
                    if (closing_parenthesis.tag != .@")") {
                        const unexpected = closing_parenthesis;
                        self.reporter.err(.loc(unexpected.loc), "Expected ')', found '{t}'.", .{unexpected.tag});
                        return InnerError.already_reported;
                    }
                    break :parse_atom try self.add_node(
                        self.span_surrounding(token, closing_parenthesis),
                        .{ .parentheses = .{ .inner = inner } },
                    );
                },

                else => {
                    self.reporter.err(.loc(token.loc), "Expected an expression, found '{t}'.", .{token.tag});
                    return InnerError.already_reported;
                },
            };
        };

        loop: while (true) {
            switch (self.peek_token().tag) {
                .eof,
                .@")",
                .@"]",
                .@"}",
                .@"{",
                .@",",
                .@"=",
                .@";",
                => break :loop,

                //  NOTE: `inline` to make `op_token_tag` comptime known so we have comptime checked workings with the operators
                inline //
                .@"+",
                .@"-",
                .@"*",
                .@"/",
                .@"[",
                .@"(",
                .@".",
                => |op_token_tag| {
                    if (comptime postfix_binding_power(op_token_tag)) |binding_power| {
                        if (binding_power.left < min_bp) {
                            break :loop;
                        }
                        _ = self.advance_token(); // Consume the operator token

                        lhs = new_lhs: switch (comptime op_token_tag) {
                            .@"[" => {
                                const index_expr: NodeId = try self.parse_expression(.{ .min_bp = 0 });
                                const closing_bracket = try self.advance_token_expect(.@"]");
                                break :new_lhs try self.add_node(
                                    self.span_surrounding(lhs, closing_bracket),
                                    .{ .binary_op = .{ .lhs = lhs, .rhs = index_expr, .kind = .array_access } },
                                );
                            },
                            .@"." => {
                                switch (self.peek_token().tag) {
                                    .@"{" => {
                                        _ = self.advance_token();
                                        const inits: []const Initializer = try self.parse_initializers();
                                        const closing_brace = try self.advance_token_expect(.@"}");
                                        break :new_lhs try self.add_node(
                                            self.span_surrounding(lhs, closing_brace),
                                            .{ .struct_literal = .{ .initializers = inits, .type = lhs } },
                                        );
                                    },
                                    .identifier => {
                                        const field_name = self.advance_token();
                                        break :new_lhs try self.add_node(
                                            self.span_surrounding(lhs, field_name),
                                            .{ .field_access = .{ .lhs = lhs, .field = field_name.id } },
                                        );
                                    },
                                    else => {
                                        const unexpected = self.advance_token();
                                        self.reporter.err(.loc(unexpected.loc), "Expected either a field access or struct initialization, found '{t}'.", .{unexpected.tag});
                                        return Reported.already_reported;
                                    },
                                }
                            },
                            .@"(" => {
                                var args = std.ArrayList(NodeId).empty;
                                defer args.deinit(self.gpa);
                                parse_arguments: while (true) {
                                    if (self.peek_token().tag == .@")") {
                                        _ = self.advance_token();
                                        // Edge case for zero arguments (x)or trailing comma (which caused another iteration)
                                        break :parse_arguments;
                                    }
                                    const argument: NodeId = try self.parse_expression(.{ .min_bp = 0 });
                                    try args.append(self.gpa, argument);
                                    const next_token = self.advance_token();
                                    switch (next_token.tag) {
                                        .@"," => continue :parse_arguments,
                                        .@")" => break :parse_arguments,
                                        else => {
                                            self.reporter.err(.loc(next_token.loc), "Unexpected token '{t}' while parsing arguments of a function call, expected either a ',' or ')'.", .{next_token.tag});
                                            return Reported.already_reported;
                                        },
                                    }
                                }

                                const finalized_args = try args.toOwnedSlice(self.gpa);
                                const closing_parenthesis = self.previous_token();

                                break :new_lhs try self.add_node(
                                    self.span_surrounding(lhs, closing_parenthesis),
                                    .{ .function_call = .{ .function = lhs, .args = finalized_args } },
                                );
                            },
                            inline else => |invalid| @compileError("Unexpected token tag: " ++ @tagName(invalid)),
                        };
                        continue :loop;
                    }

                    if (comptime infix_binding_power(op_token_tag)) |binding_power| {
                        if (binding_power.left < min_bp) {
                            break :loop;
                        }
                        _ = self.advance_token(); // Consume the operator token

                        const rhs = try self.parse_expression(.{ .min_bp = binding_power.right });
                        const op_kind: BinaryOp.Kind = switch (comptime op_token_tag) {
                            .@"+" => .add,
                            .@"-" => .sub,
                            .@"*" => .mul,
                            .@"/" => .div,
                            else => |invalid| @compileError("Unexpected token tag: " ++ @tagName(invalid)),
                        };

                        lhs = try self.add_node(self.span_surrounding(lhs, rhs), .{ .binary_op = .{
                            .lhs = lhs,
                            .rhs = rhs,
                            .kind = op_kind,
                        } });
                        continue :loop;
                    }

                    break :loop;
                },

                else => {
                    const invalid_token = self.peek_token();
                    self.reporter.err(.loc(invalid_token.loc), "Expected a continuation of an expression, found '{t}'.", .{invalid_token.tag});
                    return InnerError.already_reported;
                },
            }
        }

        return lhs;
    }

    const BindingPower = u8;

    const InfixBindingPower = struct {
        left: BindingPower,
        right: BindingPower,
    };
    fn infix_binding_power(op: Token.Tag) ?InfixBindingPower {
        return switch (op) {
            // zig fmt: off
            .@"+", .@"-" => .{ .left = 10, .right = 11 },
            .@"*", .@"/" => .{ .left = 20, .right = 21 },
            // zig fmt: on
            else => null,
        };
    }
    const PrefixBindingPower = struct {
        right: BindingPower,
    };
    fn prefix_binding_power(comptime op: Token.Tag) PrefixBindingPower {
        return switch (op) {
            .@"-", .@"+" => .{ .right = 30 },

            // Prefix operators for types, such as '[]const u8' or '^i32'
            .@"[", .@"^" => .{ .right = 40 },
            else => @compileError("Invalid token"),
        };
    }
    const PostfixBindingPower = struct {
        left: BindingPower,
    };
    fn postfix_binding_power(op: Token.Tag) ?PostfixBindingPower {
        return switch (op) {
            .@"[" => .{ .left = 50 },
            .@"." => .{ .left = 60 },
            .@"(" => .{ .left = 70 },
            else => null,
        };
    }

    fn eat_token(self: *Parser, expected_tag: Token.Tag) ?TokenWithId {
        const token = self.peek_token();
        if (token.tag == expected_tag) {
            _ = self.advance_token();
            return token;
        }
        return null;
    }
    fn unget_token(self: *Parser) void {
        self.next_token_id.index -= 1;
    }
    fn peek_token(self: Parser) TokenWithId {
        return self.get_token(self.next_token_id);
    }
    fn advance_token(self: *Parser) TokenWithId {
        const token = self.peek_token();
        self.next_token_id.index += 1;
        return token;
    }
    fn advance_token_expect(self: *Parser, expected_tag: Token.Tag) Reported!TokenWithId {
        const actual_token = self.advance_token();
        if (actual_token.tag != expected_tag) {
            self.reporter.err(.loc(actual_token.loc), "Expected '{t}', but found '{t}'.", .{ expected_tag, actual_token.tag });
            return Reported.already_reported;
        }
        return actual_token;
    }
    fn previous_token(self: Parser) TokenWithId {
        std.debug.assert(self.next_token_id.index != 0);
        const id = TokenId{ .index = self.next_token_id.index - 1 };
        return self.get_token(id);
    }
    fn get_token(self: Parser, id: TokenId) TokenWithId {
        const token = self.tokens[id.index];
        return TokenWithId.init(token, id);
    }
    fn get_node(self: Parser, id: NodeId) Node {
        return self.nodes.items[id.index];
    }
    fn text_at(self: Parser, any: anytype) []const u8 {
        return self.loc_of(any).slice_from(self.reporter.source_code);
    }

    fn add_node(self: *Parser, span: TokenSpan, data: NodeData) InnerError!NodeId {
        const new_node_index: NodeId.IndexRepr = new_node_id: {
            const index = std.math.cast(NodeId.IndexRepr, self.nodes.items.len) orelse {
                self.reporter.err(.file_scope, "The AST contains too many nodes (maximum is {d}).", .{NodeId.max_index});
                self.reporter.help(.loc(self.loc_of(span)), "This is the first problematic AST node:", .{});
                return Reported.already_reported;
            };
            break :new_node_id index;
        };
        const new_node = Node{ .span = span, .data = data };
        try self.nodes.append(self.gpa, new_node);
        return NodeId{ .index = new_node_index };
    }

    fn span_of(self: Parser, any: anytype) TokenSpan {
        const T = @TypeOf(any);
        return switch (T) {
            TokenWithId => {
                const token_with_id: TokenWithId = any;
                return token_with_id.span();
            },
            TokenId => {
                const id: TokenId = any;
                return TokenSpan.at(id);
            },
            Node => {
                const node: Node = any;
                return node.span;
            },
            NodeId => {
                const id: NodeId = any;
                const node: Node = self.get_node(id);
                return node.span;
            },
            else => @compileError("Invalid type: " ++ @typeName(T)),
        };
    }

    fn span_surrounding(self: Parser, start_any: anytype, end_any: anytype) TokenSpan {
        const start: TokenSpan = self.span_of(start_any);
        const end: TokenSpan = self.span_of(end_any);
        return TokenSpan.init(start.start, end.end);
    }

    fn loc_of(self: Parser, any: anytype) Loc {
        const T = @TypeOf(any);
        switch (T) {
            Loc => return any,
            Token => {
                const t: Token = any;
                return t.loc;
            },
            TokenId => {
                const token_id: TokenId = any;
                return self.get_token(token_id).loc;
            },
            TokenWithId => {
                const token_with_id: TokenWithId = any;
                return token_with_id.loc;
            },
            TokenSpan => {
                const span: TokenSpan = any;
                const start_loc: Loc = self.loc_of(span.start);
                const end_loc: Loc = self.loc_of(span.end);
                return Loc.init(start_loc.start, end_loc.end);
            },
            Node => {
                const n: Node = any;
                return self.loc_of(n.span);
            },
            NodeId => {
                const node_id: NodeId = any;
                return self.loc_of(self.get_node(node_id));
            },
            else => @compileError("Invalid type: " ++ @typeName(T)),
        }
    }
};

const snap = @import("snapshot_testing.zig");
const test_options = @import("snapshot_test_options");

pub const SnapOptions = struct {
    test_dir_filepath: []const u8,
    snapshot_dir_filepath: []const u8,
    stderr: std.Io.Terminal,
};

comptime {
    _ = &snap.run_snapshot_tests;
}

test "parser snapshot tests" {
    const producer = struct {
        fn producer(input: []const u8, backing_allocator: std.mem.Allocator, out: *std.Io.Writer, err_out: *std.Io.Writer) anyerror!void {
            const source_code = input;
            var arena = std.heap.ArenaAllocator.init(backing_allocator);
            defer arena.deinit();
            const gpa = arena.allocator();

            const tokens: []const Token = try tokenize(
                .{ .gpa = gpa, .source_code = source_code },
            );
            var reporter = Reporter{
                .terminal = .{ .mode = .no_color, .writer = err_out },
                .source_code = source_code,
                .filepath = null,
            };
            var parser = Parser{
                .gpa = gpa,
                .next_token_id = .{ .index = 0 },
                .nodes = .empty,
                .reporter = &reporter,
                .tokens = tokens,
            };
            const ast: Ast = parser.parse() catch |err| switch (err) {
                Oom.OutOfMemory => return err,
                ParseError.invalid_syntax => {
                    try err_out.print("Failed with error: {t}\n", .{err});
                    return;
                },
            };
            try print_ast(ast, .{ .mode = .no_color, .writer = out }, gpa);
        }
    }.producer;

    const options = test_options;
    try snap.run_snapshot_tests(.{
        .snapshots_dir = options.snapshots_dir ++ "/parser",
        .test_inputs_dir = options.test_inputs_dir ++ "/parser",
        .test_name = "parser",
        .producer = producer,
        .be_verbose = options.be_verbose,
        .show_diff = options.show_diff,
        .accept_new_snapshots = options.accept_new_snapshots,
    });
}

pub const Assembly = struct {
    string_literals: []const []const u8,
    instructions: []const Instruction,
};

pub const Address = packed struct {
    index: u64,
};

pub const Instruction = union(enum) {
    mov: struct { src: Operand, dest: Operand },
    lea: Lea,
    syscall,

    /// Represents
    /// ` lea dest, [base + index*scale + offset] `
    pub const Lea = struct {
        dest: Register,
        base: ?Register = null,
        /// Cannot be the stack pointer.
        index: ?Register = null,
        /// Must be one of 1, 2, 4, 8.
        scale: u4 = 1,
        offset: Offset = .{},

        pub const Offset = struct {
            number: u32 = 0,
            label: ?StringLiteral = null,
        };
    };
};

pub const instruction_constructors = struct {
    pub fn mov(dest: Operand, src: Operand) Instruction {
        return .{ .mov = .{ .src = src, .dest = dest } };
    }
    pub const syscall = Instruction.syscall;
};

pub fn write_string_literal_begin(str: StringLiteral, w: *std.Io.Writer) !void {
    return try w.print("strlit{d}", .{str.index});
}
pub fn write_string_literal_length(str: StringLiteral, w: *std.Io.Writer) !void {
    return try w.print("strlit{d}_len", .{str.index});
}

pub const Operand = union(enum) {
    immediate: u64,
    register: Register,
    string_literal_begin: StringLiteral,
    string_literal_length: StringLiteral,

    pub const rdi = Operand{ .register = .rdi };
    pub const rax = Operand{ .register = .rax };
    pub const rip = Operand{ .register = .rip };
    pub const rsi = Operand{ .register = .rsi };
    pub const rdx = Operand{ .register = .rdx };

    pub fn imm(value: u64) Operand {
        return .{ .immediate = value };
    }
    pub fn reg(r: Register) Operand {
        return .{ .register = r };
    }

    pub fn format(
        op: Operand,
        writer: *std.Io.Writer,
    ) std.Io.Writer.Error!void {
        switch (op) {
            .immediate => |value| try writer.print("{d}", .{value}),
            .register => |register| try writer.print("{f}", .{register}),
            .string_literal_begin => |strlit| try write_string_literal_begin(strlit, writer),
            .string_literal_length => |strlit| try write_string_literal_length(strlit, writer),
        }
    }
};

pub const RegisterId = packed struct {
    index: u5,
    pub fn from_int(x: u4) RegisterId {
        return .{ .index = x };
    }
    pub fn as_int(id: RegisterId) u4 {
        return id.index;
    }
    pub const instruction_pointer: RegisterId = .{ .index = 16 };
};

pub const Register = struct {
    id: RegisterId,
    width: enum(u8) {
        @"8" = 8,
        @"16" = 16,
        @"32" = 32,
        @"64" = 64,
    },

    pub const rax = Register{ .id = .from_int(0), .width = .@"64" };
    pub const rdx = Register{ .id = .from_int(2), .width = .@"64" };
    pub const rsi = Register{ .id = .from_int(6), .width = .@"64" };
    pub const rdi = Register{ .id = .from_int(7), .width = .@"64" };
    pub const rip = Register{ .id = .instruction_pointer, .width = .@"64" };

    pub fn format(self: Register, writer: *std.Io.Writer) std.Io.Writer.Error!void {
        const i = self.id.index;

        // r8–r15: numbered names with a size suffix
        if (8 <= i and i < RegisterId.instruction_pointer.index) {
            const suffix = switch (self.width) {
                .@"8" => "b",
                .@"16" => "w",
                .@"32" => "d",
                .@"64" => "",
            };
            return writer.print("r{d}{s}", .{ i, suffix });
        }

        // the original eight, in encoding order
        const legacy = [8][]const u8{ "ax", "cx", "dx", "bx", "sp", "bp", "si", "di" };
        const base = if (self.id == RegisterId.instruction_pointer) "ip" else legacy[i];

        return switch (self.width) {
            .@"64" => writer.print("r{s}", .{base}),
            .@"32" => writer.print("e{s}", .{base}),
            .@"16" => writer.writeAll(base),
            // al, cl, dl, bl  /  spl, bpl, sil, dil
            .@"8" => if (i < 4)
                writer.print("{c}l", .{base[0]})
            else
                writer.print("{s}l", .{base}),
        };
    }
};

pub const Symbol = packed struct {
    index: u32,
};

pub const SymbolManager = struct {
    gpa: std.mem.Allocator,
    mapping: std.array_hash_map.String(void),

    /// May modify the `mapping` of the manager, if the symbol is not yet registered.
    pub fn symbol(manager: *SymbolManager, symbol_text: []const u8) !Symbol {
        const gop = try manager.mapping.getOrPut(manager.gpa, symbol_text);
        if (gop.found_existing) {
            return Symbol{ .index = @intCast(gop.index) };
        }
        gop.key_ptr.* = try manager.gpa.dupe(u8, symbol_text);
        return Symbol{ .index = @intCast(gop.index) };
    }
    pub fn text(manager: *SymbolManager, s: Symbol) []const u8 {
        return manager.mapping.keys()[s.index];
    }
};

pub const StringLiteral = packed struct {
    index: IndexRepr,
    pub const IndexRepr = u32;
    pub const max_index = std.math.maxInt(IndexRepr);
};

pub const IrGen = struct {
    gpa: std.mem.Allocator,
    ast: Ast,
    reporter: *Reporter,
    symbols: *SymbolManager,

    string_literals: std.array_hash_map.String(void),

    cg: *CodeGen,

    const I = instruction_constructors;

    pub fn compile_ast(self: *IrGen) !void {
        const main: Node = get_main: {
            for (self.ast.root_nodes) |node| {
                const decl = self.ast.get_node(node);
                const main_symbol = try self.get_symbol(@as([]const u8, "main"));
                if (try self.get_symbol(decl.data.declaration.identifier) == main_symbol) {
                    const function = self.ast.get_node(decl.data.declaration.inital_value.?);
                    if (function.data != .function_literal) {
                        self.reporter.err(.loc(self.ast.loc_of(function)), "Main should be a function, not a '{t}'.", .{function.data});
                        return error.semantic;
                    }
                    break :get_main function;
                }
            }
            self.reporter.err(.file_scope, "Did not find the symbol 'main', where would your program start? :(", .{});
            return error.semantic;
        };
        const body = self.ast.get_node(main.data.function_literal.body_id);
        for (body.data.block.statements) |statement_id| {
            try self.compile_statement(statement_id);
        }

        try self.cg.add_instruction(I.mov(.rax, .imm(60)));
        try self.cg.add_instruction(I.mov(.rdi, .imm(0)));
        try self.cg.add_instruction(I.syscall);
    }

    fn compile_statement(self: *IrGen, id: NodeId) !void {
        const statement = self.ast.get_node(id);
        switch (statement.data) {
            .function_call => |fn_call| {
                const function: Symbol = f: {
                    const node = self.ast.get_node(fn_call.function);
                    if (node.data != .identifier) {
                        return self.todo(.loc(self.ast.loc_of(node)), "Compilation of functions '{t}'.", .{node.data});
                    }
                    std.debug.assert(node.span.start == node.span.end);
                    break :f try self.get_symbol(node.span.start);
                };
                if (function != try self.get_symbol(@as([]const u8, "print"))) {
                    return self.todo(.loc(self.ast.loc_of(id)), "Compilation of non-`print` functions :D.", .{});
                }

                if (fn_call.args.len != 1) {
                    return self.todo(.loc(self.ast.loc_of(id)), "Compilation of functions with more than one argument.", .{});
                }
                const arg = self.ast.get_node(fn_call.args[0]);
                if (arg.data != .string_literal) {
                    return self.todo(.loc(self.ast.loc_of(arg)), "Non string-literal args :D", .{});
                }
                assert(arg.span.start == arg.span.end);
                const str: StringLiteral = try self.make_string_literal(arg.span.start);

                // 'Write' syscall
                try self.cg.add_instruction(I.mov(.rax, .imm(1))); // Syscall number 1 => `write`
                try self.cg.add_instruction(I.mov(.rdi, .imm(1))); // fd 1 = stdout
                // lea rsi, [rip + str]
                // address of the string literal
                try self.cg.add_instruction(.{ .lea = .{
                    .dest = .rsi,
                    .base = .rip,
                    .offset = .{ .label = str },
                } });
                try self.cg.add_instruction(I.mov(.rdx, .{ .string_literal_length = str })); // Length of the string
                try self.cg.add_instruction(I.syscall);
            },
            else => return self.todo(.loc(self.ast.loc_of(id)), "Compilation of the statement '{t}'.", .{statement.data}),
        }
    }

    pub fn make_string_literal(self: *IrGen, token: TokenId) !StringLiteral {
        assert(self.ast.get_token(token).tag == .string_literal);
        const lexeme = self.ast.text_at(token);
        var error_msg: ?[]const u8 = null;
        const string_bytes: []const u8 = parse_string_literal(self.gpa, lexeme, &error_msg) catch |err| switch (err) {
            Oom.OutOfMemory => return err,
            error.invalid_string_literal => {
                const loc = self.ast.loc_of(token);
                self.reporter.err(.loc(loc), "{s}", .{error_msg orelse "Invalid string literal."});
                return ParseError.invalid_syntax;
            },
        };
        const gop = try self.string_literals.getOrPut(self.gpa, string_bytes);
        if (gop.index > StringLiteral.max_index) {
            const loc = self.ast.loc_of(token);
            self.reporter.err(.loc(loc), "There are too many string literals.", .{});
            return error.already_reported;
        }
        return StringLiteral{ .index = @intCast(gop.index) };
    }

    pub fn get_symbol(self: *IrGen, any: anytype) !Symbol {
        const text = get_text: {
            const T = @TypeOf(any);
            switch (T) {
                []const u8, []u8 => break :get_text any,
                Token, TokenId, TokenWithId => break :get_text self.ast.text_at(any),
                else => @compileError(
                    "Unexpected type '" ++ @typeName(T) ++ "'. Consider whether it makes sense for this type to be a symbol.",
                ),
            }
        };
        return self.symbols.symbol(text);
    }

    pub fn not_supported(self: *IrGen, where: Reporter.Where, comptime fmt: []const u8, args: anytype) error{feature_not_supported} {
        self.reporter.err(where, "[NOT SUPPORTED] " ++ fmt, args);
        return error.feature_not_supported;
    }

    pub fn todo(self: *IrGen, where: Reporter.Where, comptime fmt: []const u8, args: anytype) error{TODO} {
        self.reporter.err(where, "[TODO] " ++ fmt, args);
        return error.TODO;
    }
};

fn parse_string_literal(gpa: std.mem.Allocator, lexeme: []const u8, err: *?[]const u8) (Oom || error{invalid_string_literal})![]const u8 {
    assert(lexeme.len >= 2);
    assert(lexeme[0] == '"');
    assert(lexeme[lexeme.len - 1] == '"');
    if (lexeme.len >= 3) assert(lexeme[lexeme.len - 2] != '\\');

    const in = lexeme[1..(lexeme.len - 1)];
    var out = try std.ArrayList(u8).initCapacity(gpa, in.len);

    var i: usize = 0;
    while (i < in.len) {
        if (in[i] != '\\') {
            try out.append(gpa, in[i]);
            i += 1;
            continue;
        }
        i += 1;
        assert(i < in.len);

        const escaped_char: u8 = switch (in[i]) {
            '\\' => '\\',
            '"' => '"',
            'n' => '\n',
            'r' => '\r',
            't' => '\t',
            'x' => hex_value: {
                i += 2;
                const error_msg = "The '\\x' in this string literal must contain two hex digits right after it.";
                if (i >= in.len) {
                    err.* = error_msg;
                    return error.invalid_string_literal;
                }
                const value_slice = in[i - 1 .. i + 1];
                if (std.mem.findScalar(u8, value_slice, '_') != null) {
                    err.* = error_msg;
                    return error.invalid_string_literal;
                }
                const byte: u8 = std.fmt.parseInt(u8, in[i - 1 .. i + 1], 16) catch |parse_error| switch (parse_error) {
                    std.fmt.ParseIntError.Overflow => unreachable,
                    std.fmt.ParseIntError.InvalidCharacter => {
                        err.* = error_msg;
                        return error.invalid_string_literal;
                    },
                };
                break :hex_value byte;
            },
            else => {
                err.* = "Invalid escaped character in this string. Valid characters to escape are: `\\`, `\"`, `\\n`, `\\r`, `\\x<two hex digits>`.";
                return error.invalid_string_literal;
            },
        };
        try out.append(gpa, escaped_char);
        i += 1;
    }

    return out.toOwnedSlice(gpa);
}

pub fn print_string_literal_with_escaped_chars(bytes: []const u8, w: *std.Io.Writer) !void {
    for (bytes) |chr| {
        switch (chr) {
            '\\' => try w.print("\\\\", .{}),
            '\"' => try w.print("\\\"", .{}),
            '\'' => try w.print("\\'", .{}),
            '\r' => try w.print("\\r", .{}),
            '\n' => try w.print("\\n", .{}),
            '\t' => try w.print("\\t", .{}),
            else => {
                if (std.ascii.isPrint(chr)) {
                    try w.print("{c}", .{chr});
                } else {
                    try w.print("\\{o:03}", .{chr});
                }
            },
        }
    }
}

pub const CodeGen = struct {
    gpa: std.mem.Allocator,
    instructions: std.ArrayList(Instruction),

    pub fn add_instruction(cg: *CodeGen, instruction: Instruction) !void {
        try cg.instructions.append(cg.gpa, instruction);
    }

    pub fn get_assembly(cg: *CodeGen, string_literals: []const []const u8) !Assembly {
        return Assembly{
            .instructions = try cg.instructions.toOwnedSlice(cg.gpa),
            .string_literals = string_literals,
        };
    }
};

pub fn assemble(
    gpa: std.mem.Allocator,
    ast: Ast,
    reporter: *Reporter,
) !Assembly {
    var instructions = std.ArrayList(Instruction).empty;
    errdefer instructions.deinit(gpa);

    _ = ast;
    _ = reporter;

    const I = instruction_constructors;

    try instructions.append(
        gpa,
        I.mov(.{ .register = .rax }, .{ .immediate = 60 }),
    );

    try instructions.append(
        gpa,
        I.mov(.{ .register = .rdi }, .{ .immediate = 97 }),
    );

    try instructions.append(
        gpa,
        I.syscall,
    );

    const finalized_instructions = try instructions.toOwnedSlice(gpa);
    return Assembly{
        .string_literals = &.{},
        .instructions = finalized_instructions,
    };
}

pub const Writer = struct {
    inner: *std.Io.Writer,
    has_error: bool,
    indent: []const u8 = "",

    pub fn print(w: *Writer, comptime fmt: []const u8, args: anytype) void {
        if (comptime std.mem.cutPrefix(u8, fmt, "{INDENT}")) |new_fmt| {
            w.inner.print("{s}" ++ new_fmt, .{w.indent} ++ args) catch {
                w.has_error = true;
            };
        } else {
            w.inner.print(fmt, args) catch {
                w.has_error = true;
            };
        }
    }
    pub fn println(w: *Writer, comptime fmt: []const u8, args: anytype) void {
        w.print(fmt ++ "\n", args);
    }
};

pub fn print_assembly(as: Assembly, w: *Writer) !void {
    w.print(
        \\{s}.intel_syntax noprefix
        \\{s}.global _start
        \\
        \\{s}.section .rodata
        \\
    , .{ w.indent, w.indent, w.indent });

    for (as.string_literals, 0..) |literal_bytes, index| {
        const string_literal = StringLiteral{ .index = @intCast(index) };
        const label = std.fmt.Alt(StringLiteral, write_string_literal_begin){ .data = string_literal };
        w.print(
            \\{f}:
            \\{s}.ascii "{f}"
            \\{s}.set {f}, . - {f}
            \\
            \\
        , .{
            label,
            w.indent,
            std.fmt.Alt([]const u8, print_string_literal_with_escaped_chars){ .data = literal_bytes },
            w.indent,
            std.fmt.Alt(StringLiteral, write_string_literal_length){ .data = string_literal },
            label,
        });
    }

    w.print(
        \\
        \\{s}.text
        \\_start:
        \\
    , .{w.indent});

    for (as.instructions) |instruction| {
        print_instruction(instruction, w);
    }

    if (w.has_error) {
        return std.Io.Writer.Error.WriteFailed;
    }

    try w.inner.flush();
}

pub fn print_instruction(instr: Instruction, w: *Writer) void {
    w.print("{INDENT}{t}", .{instr});
    switch (instr) {
        .mov => |mov| w.print(" {f}, {f}", .{ mov.dest, mov.src }),
        .lea => |lea| {
            // ` lea dest, [base + index*scale + offset] `
            w.print(" {f}, [", .{lea.dest});
            var printed = false;

            if (lea.base) |base| {
                printed = true;
                w.print("{f}", .{base});
            }
            if (lea.index) |index| {
                if (printed) w.print(" + ", .{});
                printed = true;
                w.print("{f}", .{index});
                if (lea.scale != 1) w.print("*{d}", .{lea.scale});
            }
            if (lea.offset.label) |label| {
                if (printed) w.print(" + ", .{});
                printed = true;
                write_string_literal_begin(label, w.inner) catch {
                    w.has_error = true;
                };
            }
            if (lea.offset.number != 0) {
                if (printed) w.print(" + ", .{});
                printed = true;
                w.print("{d}", .{lea.offset.number});
            }

            w.print("]", .{});
        },
        inline else => |payload, tag| {
            const Payload = @TypeOf(payload);
            if (comptime Payload != void) {
                @compileError(
                    std.fmt.comptimePrint("The instruction '{t}' has non-void payload '{s}'.", .{ tag, @typeName(Payload) }),
                );
            }
        },
    }
    w.println("", .{});
}
