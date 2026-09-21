const std = @import("std");

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
                    else => continue :loop .lexing_comment,
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
    };
};

pub const Oom = std.mem.Allocator.Error;

pub fn tokenize(options: struct {
    gpa: std.mem.Allocator,
    source_code: []const u8,
}) Oom![]Token {
    const gpa = options.gpa;
    const source_code = options.source_code;

    const estimated_tokens_count: usize = source_code.len / 3;
    var tokens = try std.ArrayList(Token).initCapacity(gpa, estimated_tokens_count);

    var lexer = Lexer{ .source_code = source_code };
    while (true) {
        const token = lexer.next_token();
        try tokens.append(gpa, token);
        if (token.tag == .eof) break;

        // The should not be more tokens than ther are characters in the source code
        std.debug.assert(tokens.items.len <= source_code.len);
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
    index: u32,
};

pub const TokenSpan = packed struct {
    start: TokenId,
    /// The end is inclusive.
    end: TokenId,
};

pub const Ast = struct {
    source_code: []const u8,
    filepath: ?[]const u8,

    tokens: []Token,
    nodes: []Node,

    pub fn node(self: Ast, id: NodeId) Node {
        return self.nodes[id.index];
    }

    pub fn token(self: Ast, id: TokenId) Token {
        return self.tokens[id.index];
    }

    pub inline fn loc_of(self: Ast, any: anytype) Loc {
        const T = @TypeOf(any);
        switch (T) {
            Loc => return any,
            Token => {
                const t: Token = any;
                return t.loc;
            },
            TokenId => {
                const token_id: TokenId = any;
                return self.token(token_id).loc;
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
                return self.loc_of(self.node(node_id));
            },
            else => @compileError("Invalid type: " ++ @typeName(T)),
        }
    }

    pub inline fn text_at(self: Ast, any: anytype) []const u8 {
        const loc: Loc = self.loc_of(any);
        return loc.slice_from(self.source_code);
    }
};

pub const Node = struct {
    span: TokenSpan,
    data: NodeData,
};

pub const NodeData = union(enum) {
    integer_literal,
    binary_op: BinaryOp,
};

pub const NodeId = packed struct {
    index: u32,
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
