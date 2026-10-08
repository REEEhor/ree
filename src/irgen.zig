const std = @import("std");
const Oom = std.mem.Allocator.Error;
const assert = std.debug.assert;

const gen = @import("root.zig");

const FmtTerminal = @import("fmt_terminal.zig").FmtTerminal;

const frontend = gen.frontend;
const Ast = frontend.Ast;
const Reporter = frontend.Reporter;
const ParseError = frontend.ParseError;
const Token = frontend.Token;
const TokenId = frontend.TokenId;
const TokenWithId = frontend.TokenWithId;
const TokenSpan = frontend.TokenSpan;

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

pub const TypeInfo = union(enum) {
    integer_i32,

    pub fn alignment(t: TypeInfo) u64 {
        return switch (t) {
            .integer_i32 => 32 / 8,
        };
    }

    pub fn size(t: TypeInfo) u64 {
        return switch (t) {
            .integer_i32 => 32 / 8,
        };
    }
};

pub const TypeId = packed struct {
    index: IndexRepr,

    pub fn from_int(int: IndexRepr) TypeId {
        return .{ .index = int };
    }
    pub fn as_int(id: TypeId) IndexRepr {
        return id.index;
    }
    pub const IndexRepr = u64;
};

pub const ScopeStack = struct {
    scopes: std.ArrayList(Scope),
    gpa: std.mem.Allocator,

    pub fn init(gpa: std.mem.Allocator) ScopeStack {
        return .{ .gpa = gpa, .scopes = .empty };
    }

    pub fn deinit_assert_empty(stack: *ScopeStack) void {
        assert(stack.scopes.items.len == 0);
        stack.scopes.deinit(stack.gpa);
        stack.* = undefined;
    }

    pub fn begin_scope(stack: *ScopeStack) !ScopeGuard {
        try stack.scopes.append(stack.gpa, Scope{
            .symbols = .init(stack.gpa),
        });
        return .{ .scope_index = stack.scopes.items.len - 1, .stack = stack };
    }

    pub fn find_symbol(stack: *ScopeStack, symbol: Symbol) ?SymbolData {
        if (stack.scopes.items.len == 0) return null;
        var scope_index: u64 = stack.scopes.items.len - 1;
        while (true) {
            if (stack.scopes.items[scope_index].symbols.get(symbol)) |symbol_data| {
                return symbol_data;
            }
            if (scope_index == 0) return null;
            scope_index -= 1;
        }
    }

    pub fn register_symbol(stack: *ScopeStack, symbol: Symbol, data: SymbolData) !RegisterSymbolResult {
        assert(stack.scopes.items.len != 0);
        const scope: *Scope = &stack.scopes.items[stack.scopes.items.len - 1];
        const gop = try scope.symbols.getOrPut(symbol);
        if (gop.found_existing) {
            return .{ .duplicate = gop.value_ptr };
        }
        gop.value_ptr.* = data;
        return .ok;
    }

    pub const ScopeGuard = struct {
        scope_index: u64,
        stack: *ScopeStack,

        pub fn end_scope(handle: *ScopeGuard) void {
            const stack = handle.stack;
            // If this assert fails, the handle was not for the top of the scope.
            assert(handle.scope_index + 1 == stack.scopes.items.len);
            const scope: *Scope = &stack.scopes.items[handle.scope_index];

            scope.symbols.deinit();
            _ = stack.scopes.pop();
        }
    };

    pub const RegisterSymbolResult = union(enum) {
        ok,
        duplicate: *const SymbolData,
    };

    pub const Scope = struct {
        symbols: std.AutoHashMap(Symbol, SymbolData),
    };

    pub const SymbolData = struct {
        /// TODO: this `ir_var` will probably have be more complex in the future,
        ///       as this does not express globals and such
        ir_var_ptr: IrVar,
        type: TypeId,
        definition_location: TokenSpan,
    };
};

/// TODO: make this into a tagged union
pub const Constant = packed struct {
    value: i32,
};

pub const InstructionId = packed struct {
    index: IndexRepr,
    pub const IndexRepr = u64;
};

//pub const OldIrVar = union(enum) {
//    tmp: InstructionId,
//    constant: Constant,
//    symbol: Symbol,
//
//    /// For empty instructions with only one argument
//    none,
//
//    pub fn is_equal(lhs: IrVar, rhs: IrVar) bool {
//        return std.meta.eql(lhs, rhs);
//    }
//};

pub const IrVar = packed struct {
    index: IndexRepr,
    pub const IndexRepr = u64;
};

pub const IrInstruction = union(enum) {
    mov: Mov,
    load: Load,
    store: Store,
    unary_op: UnaryOp,
    binary_op: BinaryOp,
    stack_alloc: StackAlloc,
    print_int_call: PrintIntCall,
    assign_constant: AssignConstant,

    pub const AssignConstant = packed struct {
        dest: IrVar,
        /// NOTE: If we get an error here when we make `Constant` into a tagged union,
        ///       we can make this into `ConstantId`, so this sturct can stayed as `packed`.
        constant: Constant,
    };

    pub const PrintIntCall = packed struct {
        int_to_print: IrVar,
    };

    pub const StackAlloc = packed struct {
        dest: IrVar,
        type_id: TypeId,
    };

    pub const Mov = packed struct {
        dest: IrVar,
        source: IrVar,
    };

    pub const Store = packed struct {
        dest_pointer: IrVar,
        source: IrVar,
    };

    pub const Load = packed struct {
        dest: IrVar,
        source_pointer: IrVar,
    };

    pub const UnaryOp = packed struct {
        dest: IrVar,
        operand: IrVar,
        kind: Kind,
        pub const Kind = enum(u8) {
            negate,
        };
    };

    pub const BinaryOp = packed struct {
        dest: IrVar,
        lhs: IrVar,
        rhs: IrVar,
        kind: Kind,
        pub const Kind = enum(u8) {
            add,
            sub,
            mul,
            div,
        };
    };
};

pub const IrOperand = union(enum) {
    constant: i32,
    offset_from_base_ptr: i64,
};

pub const IrGen = struct {
    gpa: std.mem.Allocator,
    ast: Ast,
    reporter: *Reporter,
    symbols: *SymbolManager,
    scope_stack: ScopeStack,

    /// TODO: This will be a list tree in the future of this strucuture:
    /// functions
    ///     |--- basic_blocks
    ///             |---instructions
    ///             |---ir_vars
    instructions: std.ArrayList(IrInstruction),
    /// Represents the mapping `IrVar` -> `TypeId` of that `IrVar`
    ir_vars: std.ArrayList(TypeId),

    /// Represents the mapping `TypeId` -> `TypeInfo`
    types: std.ArrayList(TypeInfo),

    string_literals: std.array_hash_map.String(void),

    const integer_i32_id = TypeId{ .index = 0 };

    // cg: *CodeGen,
    // const I = instruction_constructors;

    pub fn compile_ast(self: *IrGen) !void {
        try self.types.append(self.gpa, .integer_i32);

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

        var scope_of_main = try self.scope_stack.begin_scope();
        defer scope_of_main.end_scope();

        const body = self.ast.get_node(main.data.function_literal.body_id);
        for (body.data.block.statements) |statement_id| {
            try self.compile_statement(statement_id);
        }

        // TODO: CONTINUE HERE
        // TODO: Do some printing to the stdout or the IR

        // We don't need these right now, these insturctions will be moved to codegen
        //try self.cg.add_instruction(I.mov(.rax, .imm(60)));
        //try self.cg.add_instruction(I.mov(.rdi, .imm(0)));
        //try self.cg.add_instruction(I.syscall);
    }

    fn compile_statement(self: *IrGen, id: Ast.NodeId) !void {
        const statement = self.ast.get_node(id);
        switch (statement.data) {
            .declaration => |decl| {
                const symbol = try self.get_symbol(decl.identifier);
                if (decl.kind == .val) {
                    return self.todo(.loc(self.ast.loc_of(statement)), "Compiling `val`ues :D", .{});
                }

                // TODO: compile or deduce the type here
                const symbol_type_id: TypeId = integer_i32_id;

                const symbol_ptr: IrVar = try self.new_ir_var(symbol_type_id);

                const symbol_data: ScopeStack.SymbolData = .{
                    .type = symbol_type_id,
                    .definition_location = TokenSpan.at(decl.identifier),
                    .ir_var_ptr = symbol_ptr,
                };
                switch (try self.scope_stack.register_symbol(symbol, symbol_data)) {
                    .ok => {},
                    .duplicate => |previous_declaration| {
                        const previous_loc = self.ast.loc_of(previous_declaration.definition_location);
                        const identifier = self.ast.text_at(decl.identifier);
                        self.reporter.err(.loc(self.ast.loc_of(decl.identifier)), "Tried to define the identifier '{s}' for the second time here:", .{identifier});
                        self.reporter.help(.loc(previous_loc), "The identifier '{s}' was defined previously here:", .{identifier});
                        return error.already_reported;
                    },
                }

                try self.emit_instruction(.{ .stack_alloc = .{ .dest = symbol_ptr, .type_id = symbol_type_id } });

                const init_expr: Ast.NodeId = decl.inital_value orelse {
                    self.reporter.err(.loc(self.ast.loc_of(statement)), "Expected an inilializing value.", .{});
                    return error.already_reported;
                };
                const init_value: IrVar = try self.compile_expression(init_expr);

                try self.emit_instruction(.{ .store = .{
                    .dest_pointer = symbol_ptr,
                    .source = init_value,
                } });
            },

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
                const arg: IrVar = try self.compile_expression(fn_call.args[0]);
                try self.emit_instruction(.{ .print_int_call = .{ .int_to_print = arg } });

                //// 'Write' syscall
                //try self.cg.add_instruction(I.mov(.rax, .imm(1))); // Syscall number 1 => `write`
                //try self.cg.add_instruction(I.mov(.rdi, .imm(1))); // fd 1 = stdout
                //// lea rsi, [rip + str]
                //// address of the string literal
                //try self.cg.add_instruction(.{ .lea = .{
                //    .dest = .rsi,
                //    .base = .rip,
                //    .offset = .{ .label = str },
                //} });
                //try self.cg.add_instruction(I.mov(.rdx, .{ .string_literal_length = str })); // Length of the string
                //try self.cg.add_instruction(I.syscall);
            },
            else => return self.todo(.loc(self.ast.loc_of(id)), "Compilation of the statement '{t}'.", .{statement.data}),
        }
    }

    fn compile_expression(self: *IrGen, expr_id: Ast.NodeId) !IrVar {
        const expr = self.ast.get_node(expr_id);
        switch (expr.data) {
            .identifier => {
                assert(expr.span.start == expr.span.end);
                const symbol = try self.get_symbol(expr.span.start);
                const symbol_data = self.scope_stack.find_symbol(symbol) orelse {
                    const loc = self.ast.loc_of(expr);
                    const identifier = self.ast.text_at(loc);
                    self.reporter.err(.loc(loc), "Unkown identifier '{s}' :(", .{identifier});
                    return error.already_reported;
                };
                // TODO:: symbol_info has to store in which IrVar the pointer to the heap is stored
                if (symbol_data.type != integer_i32_id) {
                    // TODO: different datatypes
                    const loc = self.ast.loc_of(expr);
                    return self.todo(.loc(loc), "non integer_i32 types", .{});
                }
                const dest = try self.new_ir_var(symbol_data.type);
                try self.emit_instruction(.{ .load = .{
                    .dest = dest,
                    .source_pointer = symbol_data.ir_var_ptr,
                } });
                return dest;
            },
            .integer_literal => {
                // TODO: More integer types
                const lexeme = self.ast.text_at(expr);
                const raw_value = try parse_integer_literal(self.gpa, lexeme);
                const constant = raw_value.toInt(i32) catch |err| switch (err) {
                    std.math.big.int.Const.ConvertError.NegativeIntoUnsigned => @panic("INTERNAL LOGIC ERROR: we are converting to i32"),
                    std.math.big.int.Const.ConvertError.TargetTooSmall => {
                        const loc = self.ast.loc_of(expr);
                        self.reporter.err(.loc(loc), "Integer literal too big to fit into i32.", .{});
                        return error.already_reported;
                    },
                };
                const dest: IrVar = try self.new_ir_var(integer_i32_id);
                try self.emit_instruction(.{ .assign_constant = .{
                    .dest = dest,
                    .constant = Constant{ .value = constant },
                } });
                return dest;
            },
            .binary_op => |op| {
                const lhs: IrVar = try self.compile_expression(op.lhs);
                const rhs: IrVar = try self.compile_expression(op.rhs);

                // TODO: Do some kind of type-resolution here
                const dest_type: TypeId = integer_i32_id;

                const dest: IrVar = try self.new_ir_var(dest_type);
                try self.emit_instruction(.{ .binary_op = .{
                    .dest = dest,
                    .lhs = lhs,
                    .rhs = rhs,
                    .kind = switch (op.kind) {
                        .add => .add,
                        .sub => .sub,
                        .mul => .mul,
                        .div => .div,
                        .array_access => {
                            const loc = self.ast.loc_of(expr_id);
                            return self.todo(.loc(loc), "Array access expressions.", .{});
                        },
                    },
                } });
                return dest;
            },
            else => {
                return self.todo(.loc(self.ast.loc_of(expr)), "Compilation of the '{t}' expression.", .{expr.data.tag()});
            },
        }
    }

    fn new_ir_var(self: *IrGen, type_id: TypeId) Oom!IrVar {
        try self.ir_vars.append(self.gpa, type_id);
        return IrVar{ .index = self.ir_vars.items.len - 1 };
    }
    fn typeof_ir_var(self: *IrGen, ir_var: IrVar) TypeId {
        return self.ir_vars.items[ir_var.index];
    }

    fn get_type_info(self: *IrGen, type_id: TypeId) TypeInfo {
        return self.types.items[type_id.as_int()];
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

    fn emit_instruction(self: *IrGen, instruction: IrInstruction) !void {
        try self.instructions.append(self.gpa, instruction);
    }
};

pub const Sign = enum(u1) {
    signed,
    unsigned,
};

pub const IntConstant = std.math.big.int.Const;

fn parse_integer_literal(gpa: std.mem.Allocator, lexeme: []const u8) Oom!IntConstant {
    var result = std.math.big.int.Managed{
        .allocator = gpa,
        .limbs = &.{},
        .metadata = 0,
    };
    result.setString(10, lexeme) catch |err| switch (err) {
        error.InvalidBase => std.debug.panic("INNER LOGIC ERROR: '10' should be a valid base", .{}),
        error.OutOfMemory => return Oom.OutOfMemory,
        error.InvalidCharacter => std.debug.panic("INNER LOGIC ERROR: Not a valid integer lexeme: >{s}<", .{lexeme}),
    };
    return result.toConst();
}

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

pub const Ir = struct {
    instructions: std.ArrayList(IrInstruction),
    /// Represents the mapping `TypeId` -> `TypeInfo`.
    types: []const TypeInfo,
};

pub fn print_ir(ir: Ir, terminal: std.Io.Terminal) !void {
    const fmt = FmtTerminal.from_std_terminal(terminal);
    const instructions = ir.instructions.items;
    for (instructions) |instr| {
        switch (instr) {
            inline else => |info, tag| {
                _ = tag;
                if (comptime @hasField(@TypeOf(info), "dest")) {
                    try fmt.print("{CYAN}{f}{RESET} = ", .{fmt_ir_var(info.dest)});
                } else {
                    try fmt.print("      ", .{});
                }
            },
        }
        switch (instr) {
            .mov => |mov| {
                try fmt.print("{BOLD}{MAGENTA}mov{RESET} {CYAN}{f}{RESET}", .{fmt_ir_var(mov.source)});
            },
            .load => |load| {
                try fmt.print("{BOLD}{MAGENTA}load{RESET} {DIM}from ptr{RESET} {CYAN}{f}{RESET}", .{fmt_ir_var(load.source_pointer)});
            },
            .store => |store| {
                try fmt.print("{BOLD}{MAGENTA}store{RESET} {CYAN}{f}{RESET} {DIM}into ptr{RESET} {CYAN}{f}{RESET}", .{ fmt_ir_var(store.source), fmt_ir_var(store.dest_pointer) });
            },
            .unary_op => |unary_op| {
                try fmt.print("{BOLD}{MAGENTA}{t}{RESET} {CYAN}{f}{RESET}", .{ unary_op.kind, fmt_ir_var(unary_op.operand) });
            },
            .binary_op => |binary_op| {
                try fmt.print("{BOLD}{MAGENTA}{t}{RESET} {CYAN}{f}{RESET} {CYAN}{f}{RESET}", .{ binary_op.kind, fmt_ir_var(binary_op.lhs), fmt_ir_var(binary_op.rhs) });
            },
            .stack_alloc => |stack_alloc| {
                try fmt.print("{BOLD}{MAGENTA}stack_alloc{RESET} type{d}", .{stack_alloc.type_id.index});
            },
            .print_int_call => |print_int_call| {
                try fmt.print("{BOLD}{MAGENTA}print_int{RESET} {CYAN}{f}{RESET}", .{fmt_ir_var(print_int_call.int_to_print)});
            },
            .assign_constant => |assign_constant| {
                try fmt.print("{BOLD}{MAGENTA}constant{RESET} {DIM}(i32){RESET} {d}", .{assign_constant.constant.value});
            },
        }
        try fmt.print("\n", .{});
        try fmt.writer.flush();
    }
}

pub fn fmt_ir_var(ir_var: IrVar) FmtIrVar {
    return FmtIrVar{ .ir_var = ir_var };
}

pub const FmtIrVar = struct {
    ir_var: IrVar,
    pub fn format(self: @This(), writer: *std.Io.Writer) std.Io.Writer.Error!void {
        try writer.print("r{d:02}", .{self.ir_var.index});
    }
};

pub const codegen = struct {
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
};
