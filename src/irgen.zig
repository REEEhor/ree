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
