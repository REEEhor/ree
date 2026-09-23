const std = @import("std");

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
        @".",
        identifier,
        integer_literal,
        invalid,
        eof,
    };
};

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

                '/' => continue :loop .@"saw_/",

                '+' => break :loop .@"+",
                '-' => break :loop .@"-",
                '*' => break :loop .@"*",
                '(' => break :loop .@"(",
                ')' => break :loop .@")",
                '[' => break :loop .@"[",
                ']' => break :loop .@"]",

                '.' => break :loop .@".",

                else => continue :loop .lexing_invalid_token,
            },
            .lexing_identifier => {
                if (self.is_at_end()) break :loop .identifier;
                switch (self.peek_byte()) {
                    '0'...'9', 'A'...'Z', 'a'...'z', '_' => {
                        _ = self.advance_byte();
                        continue :loop .lexing_identifier;
                    },
                    else => break :loop .identifier,
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
    {
        // PERF: The `calculate_line_info` uses O(source_code.len) search.
        // It will be fine for small inputs, but for larger, it could be a problem.
        // NOTE: In such case, precalculate line beginnings and use a binary-search.
        const loc = ast.loc_of(node);
        const start = Reporter.calculate_line_info(ast.source_code, loc.start);
        const end = Reporter.calculate_line_info(ast.source_code, loc.end);
        try t.setColor(.dim);
        try w.print("[{d}:{d}-{d}:{d}]", .{ start.line, start.column, end.line, end.column });
        try t.setColor(.reset);
    }
    // Print the tag
    {
        try w.print(" ", .{});
        try t.setColor(.bold);
        try t.setColor(main_color);
        try w.print("{t}", .{node.data.tag()});
        try t.setColor(.reset);
    }

    switch (node.data) {
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
    }
}

pub const Node = struct {
    span: TokenSpan,
    data: NodeData,
};

pub const NodeData = union(enum) {
    integer_literal,
    identifier,
    binary_op: BinaryOp,
    unary_op: UnaryOp,
    parentheses: packed struct { inner: NodeId },
    field_access: FieldAccess,

    pub const Tag = std.meta.Tag(NodeData);
    pub inline fn tag(self: NodeData) Tag {
        return std.meta.activeTag(self);
    }
};

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
                .info => "info",
                .help => "help",
                .warn => "warning",
                .err => "error",
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

        // `error: expected ';' after expression`
        try t.setColor(.bold);
        try t.setColor(level.color());
        try w.writeAll(level.name());
        try t.setColor(.reset);
        try t.setColor(.bold);
        try w.writeAll(": ");
        try w.print(fmt, args);
        try t.setColor(.reset);
        try w.writeByte('\n');

        const l = switch (where) {
            .no_location => return,
            .file_scope => {
                try t.setColor(.dim);
                try w.writeAll("--> ");
                try t.setColor(.reset);
                try w.print("{s}\n", .{path});
                return;
            },
            .location => |loc| loc,
        };

        const src = self.source_code;
        const start = @min(l.start, src.len);
        const line_info = calculate_line_info(src, start);

        var num_buf: [512]u8 = undefined;
        comptime std.debug.assert(num_buf.len > std.fmt.count("{d}", .{std.math.maxInt(usize)}));
        const num = std.fmt.bufPrint(&num_buf, "{d}", .{line_info.line}) catch unreachable;

        // `  --> path/to/source/code.ree:12:15`
        try pad(w, num.len);
        try t.setColor(.dim);
        try w.writeAll("--> ");
        try t.setColor(.reset);
        try w.print("{s}:{d}:{d}\n", .{ path, line_info.line, line_info.column });

        var line_text = src[line_info.start..line_info.end];
        if (line_text.len > 0 and line_text[line_text.len - 1] == '\r') line_text.len -= 1;

        // `   |`
        // `12 |     const x = 5`
        try t.setColor(.dim);
        try pad(w, num.len + 1);
        try w.writeAll("|\n");
        try w.print("{s} | ", .{num});
        try t.setColor(.reset);
        try w.writeAll(line_text);
        try w.writeByte('\n');

        // `   |               ^~~`
        try t.setColor(.dim);
        try pad(w, num.len + 1);
        try w.writeAll("| ");
        try t.setColor(.reset);
        // Copy tabs verbatim so the carets line up with a tab-indented line.
        for (src[line_info.start..start]) |c| try w.writeByte(if (c == '\t') '\t' else ' ');

        // `end` is inclusive; clamp a multi-line span to the end of this line.
        const span_end = @min(@max(l.end +| 1, start + 1), line_info.end);
        const width = @max(span_end -| start, 1);

        try t.setColor(level.color());
        try w.writeByte('^');
        for (1..width) |_| try w.writeByte('~');
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

    pub fn parse(self: *Parser) ParseError!Ast {
        errdefer self.nodes.deinit(self.gpa);

        var root_node_ids = std.ArrayList(NodeId).empty;
        errdefer root_node_ids.deinit(self.gpa);

        while (true) {
            const node_id = self.parse_expression(.{ .min_bp = 0 }) catch |err| switch (err) {
                Reported.already_reported => return ParseError.invalid_syntax,
                Oom.OutOfMemory => return Oom.OutOfMemory,
            };
            try root_node_ids.append(self.gpa, node_id);
            if (self.advance_token().tag != .eof) {
                const unexpected = self.previous_token();
                self.reporter.err(.loc(unexpected.loc), "Expected end of file, found token '{t}'.", .{unexpected.tag});
                return ParseError.invalid_syntax;
            }
            break; // TODO: for now, we just expect a single expression
        }

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

    fn parse_expression(self: *Parser, options: struct { min_bp: BindingPower }) InnerError!NodeId {
        const min_bp = options.min_bp;

        var lhs: NodeId = parse_atom: {
            const token = self.advance_token();
            break :parse_atom switch (token.tag) {
                .integer_literal => try self.add_node(token.span(), .integer_literal),
                .identifier => try self.add_node(token.span(), .identifier),

                // Parse unary prefix operator
                inline .@"+", .@"-" => |op_token_tag| {
                    const binding_power = prefix_binding_power(comptime op_token_tag);
                    const rhs = try self.parse_expression(.{ .min_bp = binding_power.right });
                    const kind: UnaryOp.Kind = switch (comptime op_token_tag) {
                        .@"+" => .plus,
                        .@"-" => .minus,
                        else => comptime unreachable,
                    };
                    break :parse_atom try self.add_node(
                        self.span_surrounding(token, rhs),
                        .{ .unary_op = .{ .operand = rhs, .kind = kind } },
                    );
                },

                // Parse parenthesized expression
                .@"(" => {
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
                    self.reporter.err(.loc(token.loc), "Unexpected token '{t}'.", .{token.tag});
                    return InnerError.already_reported;
                },
            };
        };

        loop: while (true) {
            switch (self.peek_token().tag) {
                .eof,
                .@")",
                .@"]",
                => break :loop,

                //  NOTE: `inline` to make `op_token_tag` comptime known so we have comptime checked workings with the operators
                inline //
                .@"+",
                .@"-",
                .@"*",
                .@"/",
                .@"[",
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
                                const field_name: TokenWithId = try self.advance_token_expect(.identifier);
                                break :new_lhs try self.add_node(
                                    self.span_surrounding(lhs, field_name),
                                    .{ .field_access = .{ .lhs = lhs, .field = field_name.id } },
                                );
                            },
                            inline else => {
                                const kind: UnaryOp.Kind = switch (comptime op_token_tag) {
                                    // NOTE: Add a postfix operator here...
                                    // For example the deref operator from Zig `.*`, if we decide to implement it.
                                    inline else => |invalid| @compileError("Unexpected token tag: " ++ @tagName(invalid)),
                                };
                                _ = kind;
                            },
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
                    self.reporter.err(.loc(invalid_token.loc), "Unexpected token '{t}'.", .{invalid_token.tag});
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
            else => @compileError("Invalid token"),
        };
    }
    const PostfixBindingPower = struct {
        left: BindingPower,
    };
    fn postfix_binding_power(op: Token.Tag) ?PostfixBindingPower {
        return switch (op) {
            .@"[" => .{ .left = 40 },
            .@"." => .{ .left = 50 },
            else => null,
        };
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
            TokenSpan => {
                const span: TokenSpan = any;
                const start_loc: Loc = self.loc_of(span);
                const end_loc: Loc = self.loc_of(span.end);
                return Loc.init(start_loc.start, end_loc.end);
            },
            Node => {
                const n: Node = any;
                return self.loc_of(n.span);
            },
            NodeId => {
                const node_id: NodeId = any;
                return self.loc_of(self.node(node_id));
            },
            else => @compileError("Invalid type: " ++ @typeName(T)),
        }
    }
};

/// Intermediate representation
pub const Ir = struct {
    functions_by_name: FunctionsByName,

    pub const FunctionsByName = std.array_hash_map.Custom(
        Function,
        void,
        struct {
            const String = std.array_hash_map.StringContext;
            pub fn hash(_: @This(), function: Function) u32 {
                return String.hash(.{}, function.name);
            }
            pub fn eql(_: @This(), f1: Function, f2: Function, idx: usize) bool {
                return String.eql(.{}, f1.name, f2.name, idx);
            }
        },
        true, // <- Store hash set to true, we are hashing strings
    );
};

pub const Function = struct {
    name: []const u8,
    bb_list: std.ArrayList(BasicBlock),
};

pub const BasicBlock = struct {
    instrs: std.ArrayList(Instruction),
};

pub const Instruction = union(enum) {
    bin_op: BinOp,
    load_constant: struct {
        dest: Register,
        constant: Constant,
    },
    load: struct {
        dest: Register,
        src: Address,
    },
    store: struct {
        src: Register,
        dest: Address,
    },
    alloca: struct {
        dest: Register,
    },

    pub const BinOp = packed struct {
        dest: Register,
        lhs: Register,
        rhs: Register,
        kind: Kind,

        pub const Kind = enum(u8) {
            add,
            sub,
            mul,
            div,
        };
    };
};

pub const Constant = union(enum) {
    //
};

pub const Address = packed struct {
    value: u64,
};

pub const Register = packed struct {
    index: u64,
};
