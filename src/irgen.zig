const std = @import("std");
const Oom = std.mem.Allocator.Error;
const assert = std.debug.assert;

const gen = @import("root.zig");

const frontend = gen.frontend;
const Ast = frontend.Ast;
const Reporter = frontend.Reporter;
const ParseError = frontend.ParseError;
const Token = frontend.Token;
const TokenId = frontend.TokenId;
const TokenWithId = frontend.TokenWithId;

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
        const main: Ast.Node = get_main: {
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

    fn compile_statement(self: *IrGen, id: Ast.NodeId) !void {
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
