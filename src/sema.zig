const std = @import("std");
const assert = std.debug.assert;
const Oom = std.mem.Allocator.Error;

const root_module = @import("root.zig");
const frontend = root_module.frontend;

const Ast = frontend.Ast;
const Reporter = frontend.Reporter;
const TokenSpan = frontend.TokenSpan;

pub const Symbol = packed struct {
    index: IndexRepr,
    pub const IndexRepr = u64;
    pub fn from_int(int: IndexRepr) Symbol {
        return .{ .index = int };
    }
    pub fn as_int(symbol: Symbol) IndexRepr {
        return symbol.index;
    }
};
pub const SymbolManager = struct {
    gpa: std.mem.Allocator,
    mapping: std.array_hash_map.String(void) = .empty,

    /// May modify the `mapping` of the manager, if the symbol is not yet registered.
    pub fn get(manager: *SymbolManager, symbol_text: []const u8) !Symbol {
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

pub const Type = union(enum(u8)) {
    i64,
    bool,
    void,
    null,
    type,
    pointer: Pointer,
    slice: Slice,
    @"struct": Struct,
    function: Function,

    pub fn tag(info: Type) Tag {
        return std.meta.activeTag(info);
    }
    pub const Tag = std.meta.Tag(@This());

    pub const Pointer = struct {
        child: *Type,
    };
    pub const Slice = struct {
        child: *Type,
    };
    pub const Struct = struct {
        name: ?Symbol,
        members: []Member,
        pub const Member = struct {
            name: Symbol,
            type: *Type,
        };
    };
    pub const Function = struct {
        name: ?Symbol,
        parameter_types: []*Type,
        return_type: *Type,
    };
};

comptime {
    for (@typeInfo(TypeChecker).@"struct".decls) |decl| {
        _ = &@field(TypeChecker, decl.name);
    }
}

pub const LexicalContext = struct {
    scope_stack: std.ArrayList(Scope),
    gpa: std.mem.Allocator,

    pub fn init(gpa: std.mem.Allocator) LexicalContext {
        return .{ .gpa = gpa, .scope_stack = .empty };
    }

    pub fn deinit_assert_empty(context: *LexicalContext) void {
        assert(context.scope_stack.items.len == 0);
        context.scope_stack.deinit(context.gpa);
        context.* = undefined;
    }

    pub fn begin_scope(context: *LexicalContext) !ScopeGuard {
        try context.scope_stack.append(context.gpa, Scope{
            .symbols = .init(context.gpa),
        });
        return .{ .scope_index = context.scope_stack.items.len - 1, .context = context };
    }

    pub fn find_symbol(context: *LexicalContext, symbol: Symbol) ?SymbolData {
        if (context.scope_stack.items.len == 0) return null;
        var scope_index: u64 = context.scope_stack.items.len - 1;
        while (true) {
            if (context.scope_stack.items[scope_index].symbols.get(symbol)) |symbol_data| {
                return symbol_data;
            }
            if (scope_index == 0) return null;
            scope_index -= 1;
        }
    }

    pub fn register_symbol(context: *LexicalContext, symbol: Symbol, data: SymbolData) !RegisterSymbolResult {
        assert(context.scope_stack.items.len != 0);
        const scope: *Scope = &context.scope_stack.items[context.scope_stack.items.len - 1];
        const gop = try scope.symbols.getOrPut(symbol);
        if (gop.found_existing) {
            return .{ .duplicate = gop.value_ptr };
        }
        gop.value_ptr.* = data;
        return .ok;
    }

    pub const ScopeGuard = struct {
        scope_index: u64,
        context: *LexicalContext,

        pub fn end_scope(handle: *ScopeGuard) void {
            const context = handle.context;
            // If this assert fails, the handle was not for the top of the scope.
            assert(handle.scope_index + 1 == context.scope_stack.items.len);
            const scope: *Scope = &context.scope_stack.items[handle.scope_index];

            scope.symbols.deinit();
            _ = context.scope_stack.pop();
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
        type: *Type,
        /// Guaranteed to be `Ast.Declaration` or `Ast.Parameter`.
        declaration_node: ?*Ast.Node,
        comptime_value: ?ComptimeValue,
        pub fn init(typ: *Type, decl_node: ?*Ast.Node, comptime_value: ?ComptimeValue) SymbolData {
            if (decl_node) |node| switch (node.data) {
                .declaration, .parameter => {},
                else => |invalid| std.debug.panic("Invalid decl node: '{t}'", .{invalid}),
            };
            return SymbolData{
                .type = typ,
                .declaration_node = decl_node,
                .comptime_value = comptime_value,
            };
        }
    };
};

pub const ComptimeValue = union(enum) {
    void,
    integer: Integer,
    type: *Type,
    function: Function,
    boolean: bool,

    pub const Integer = i64;

    pub const Function = struct {
        /// Guaranteed to be `Ast.FunctionLiteral`
        ast: *Ast.Node,
        name: ?Symbol,
    };
};

pub const ValueKind = enum {
    lvalue,
    /// NOTE: we will probably have to change this at some point
    non_lvalue,
};

pub const TypeHashTableLookup = struct {
    pub fn hash(_: TypeHashTableLookup, t: *const Type) u32 {
        var hasher = std.hash.Wyhash.init(42);
        std.hash.autoHash(&hasher, t.tag());
        switch (t.*) {
            .@"struct" => @panic("Passed a struct type into hash"),
            .function => @panic("Passed a function type into hash"),
            .pointer => |pointer| std.hash.autoHash(&hasher, @as(usize, @intFromPtr(pointer.child))),
            .slice => |slice| std.hash.autoHash(&hasher, @as(usize, @intFromPtr(slice.child))),
            inline else => |payload, tag| {
                const PayloadType = @TypeOf(payload);
                if (@sizeOf(PayloadType) != 0) {
                    @compileError("The tag '" ++ @tagName(tag) ++ "' has non-zero sized payload type '" ++ @typeName(PayloadType) ++ "'");
                }
            },
        }
        return @truncate(hasher.final());
    }
    pub fn eql(_: TypeHashTableLookup, t1: *const Type, t2: *const Type, _: usize) bool {
        if (t1.tag() != t2.tag()) return false;
        switch (t1.*) {
            .@"struct" => @panic("Passed a struct type into eql"),
            .function => @panic("Passed a function type into hash"),
            .pointer => |t1_pointer| return t1_pointer.child == t2.pointer.child,
            .slice => |t1_slice| return t1_slice.child == t2.slice.child,
            inline else => |payload, tag| {
                const PayloadType = @TypeOf(payload);
                if (@sizeOf(PayloadType) != 0) {
                    @compileError("The tag '" ++ @tagName(tag) ++ "' has non-zero sized payload type '" ++ @typeName(PayloadType) ++ "'");
                }
                // They equal by tag and have zero-sized payload => they are equal.
                return true;
            },
        }
    }
};

pub const TypeChecker = struct {
    arena: std.mem.Allocator,

    ast: Ast,
    symbol_manager: *SymbolManager,
    lexical_context: *LexicalContext,
    reporter: *Reporter,

    types_lookup: TypeLookup = .empty,
    pub const TypeLookup = std.array_hash_map.Custom(*Type, void, TypeHashTableLookup, false);

    const InnerError = error{ already_reported, TODO };

    pub fn type_check(checker: *TypeChecker) error{ type_check, TODO }!void {
        checker.analyze(checker.ast.root) catch |err| switch (err) {
            InnerError.already_reported => return error.type_check,
            InnerError.TODO => return error.TODO,
        };
    }

    fn analyze(checker: *TypeChecker, node: *Ast.Node) InnerError!void {
        switch (node.data) {
            .root => |root| {
                var scope_guard = checker.lexical_context.begin_scope() catch |oom| oom_panic(oom);
                defer scope_guard.end_scope();

                const builtin_values: []const struct { []const u8, ComptimeValue } = &.{
                    .{ "void", .{ .type = checker.type_id(.void) } },
                    .{ "i64", .{ .type = checker.type_id(.i64) } },
                    .{ "bool", .{ .type = checker.type_id(.bool) } },
                    .{ "type", .{ .type = checker.type_id(.type) } },
                    .{ "true", .{ .boolean = true } },
                    .{ "false", .{ .boolean = false } },
                };
                for (builtin_values) |builtin_type| {
                    const identifier, const value = builtin_type;
                    const data: LexicalContext.SymbolData = switch (value) {
                        .type => .init(checker.type_id(.type), null, value),
                        .boolean => .init(checker.type_id(.bool), null, value),
                        .integer, .function, .void => unreachable,
                    };
                    const register_result = checker.lexical_context.register_symbol(
                        checker.get_symbol(identifier),
                        data,
                    ) catch |oom| oom_panic(oom);
                    assert(register_result == .ok);
                }

                for (root.declarations) |*decl| {
                    try checker.analyze(decl);
                }
            },

            // Statements
            .declaration => |declaration| try checker.analyze_declaration(node, declaration),

            // Expressions
            .integer_literal => try checker.analyze_integer_literal(node),
            .unary_op => |unary_op| try checker.analyze_unary_op(node, unary_op),
            .binary_op => |binary_op| try checker.analyze_binary_op(node, binary_op),
            .function_literal => |function_literal| try checker.analyze_function_literal(node, function_literal.*),
            .block => |block| try checker.analyze_block(node, block),
            .identifier => try checker.analyze_identifier(node),
            .pointer_to => |pointer_to| try checker.analyze_address_of(node, pointer_to),

            else => |_, tag| {
                const loc = checker.ast.loc_of(node);
                checker.reporter.err(.loc(loc), "TODO: 'analyze' of node of kind '{t}'", .{tag});
                return InnerError.already_reported;
            },
        }
    }

    fn analyze_address_of(
        checker: *TypeChecker,
        node: *Ast.Node,
        addressof: Ast.AddressOf,
    ) InnerError!void {
        assert(node.data == .pointer_to);
        try checker.analyze(addressof.child);

        switch (addressof.child.type.?.*) {
            .type => {
                var comptime_value: ?ComptimeValue = null;
                if (addressof.child.comptime_value) |child_value| {
                    const pointer_to_child: Type = .{ .pointer = .{ .child = child_value.type } };
                    comptime_value = .{ .type = checker.type_id(pointer_to_child) };
                }
                annotate(node, .{
                    .type = checker.type_id(.type),
                    .value_kind = .non_lvalue,
                    .comptime_value = comptime_value,
                });
                return;
            },
            else => {
                if (addressof.child.value_kind != .lvalue) {
                    const loc = checker.ast.loc_of(node);
                    checker.reporter.err(.loc(loc), "Cannot take address of a non-lvalue.", .{});
                    return InnerError.already_reported;
                }
                const new_type: Type = .{ .pointer = .{ .child = addressof.child.type.? } };
                annotate(node, .{
                    .type = checker.type_id(new_type),
                    .value_kind = .non_lvalue,
                    .comptime_value = null,
                });
                return;
            },
        }
    }

    fn analyze_unary_op(checker: *TypeChecker, node: *Ast.Node, unary_op: Ast.UnaryOp) InnerError!void {
        assert(node.data == .unary_op);

        try checker.analyze(unary_op.operand);

        var unary_op_value: ?ComptimeValue = null;

        switch (unary_op.kind) {
            inline .plus, .minus, .bit_negate => |arith_op_kind| {
                _ = try checker.check_type_tags(unary_op.operand, &.{.i64});

                // Compute comptime value
                if (unary_op.operand.comptime_value) |comptime_value| switch (comptime_value) {
                    .integer => |value| switch (arith_op_kind) {
                        .plus => unary_op_value = .{ .integer = value },
                        .bit_negate => unary_op_value = .{ .integer = ~value },
                        .minus => {
                            var new_value: ComptimeValue.Integer = value;
                            new_value = std.math.negate(new_value) catch {
                                const loc = checker.ast.loc_of(node);
                                checker.reporter.err(.loc(loc), "Cannot represent the value -{d} with the type '{f}'.", .{ new_value, checker.fmt_type(unary_op.operand.type.?) });
                                return InnerError.already_reported;
                            };
                            unary_op_value = .{ .integer = new_value };
                        },
                        else => comptime unreachable,
                    },
                    else => |unexpected| std.debug.panic("Unreachable case '{t}' due to checked type tag above.", .{unexpected}),
                };
            },
            .logic_not => {
                _ = try checker.check_type_tags(unary_op.operand, &.{.bool});

                if (unary_op.operand.comptime_value) |comptime_value| {
                    switch (comptime_value) {
                        .boolean => |value| unary_op_value = .{ .boolean = !value },
                        else => @panic("We checked the type is bool above"),
                    }
                }
            },
        }

        annotate(node, .{
            .type = unary_op.operand.type.?,
            .value_kind = .non_lvalue,
            .comptime_value = unary_op_value,
        });
    }

    fn analyze_identifier(checker: *TypeChecker, node: *Ast.Node) InnerError!void {
        assert(node.data == .identifier);

        const identifier: Symbol = checker.get_symbol(node);
        const symbol_data = checker.lexical_context.find_symbol(identifier) orelse {
            const loc = checker.ast.loc_of(node);
            checker.reporter.err(.loc(loc), "Unknown identifer '{s}' :(", .{checker.ast.text_at(loc)});
            return InnerError.already_reported;
        };
        annotate(node, .{
            .type = symbol_data.type,
            .value_kind = .lvalue,
            .comptime_value = symbol_data.comptime_value,
        });
    }

    fn analyze_block(checker: *TypeChecker, node: *Ast.Node, block: Ast.Block) InnerError!void {
        var scope_guard = checker.lexical_context.begin_scope() catch |oom| oom_panic(oom);
        defer scope_guard.end_scope();

        for (block.statements) |*statement| {
            try checker.analyze(statement);
        }

        var annotation = AnnotateOptions{
            .type = checker.type_id(.void),
            .value_kind = .non_lvalue,
            .comptime_value = null,
        };
        if (block.value_statement()) |value_node| {
            annotation = .{
                .type = value_node.type.?,
                .value_kind = .non_lvalue,
                .comptime_value = value_node.comptime_value,
            };
        }
        annotate(node, annotation);
    }

    fn analyze_function_literal(
        checker: *TypeChecker,
        node: *Ast.Node,
        function_literal: Ast.FunctionLiteral,
    ) InnerError!void {
        assert(node.data == .function_literal);

        var scope_guard = checker.lexical_context.begin_scope() catch |oom| oom_panic(oom);
        defer scope_guard.end_scope();

        const header = function_literal.header.data.function_header;

        const parameter_types = checker.arena.alloc(*Type, header.params.len) catch |oom| oom_panic(oom);

        for (header.params, parameter_types) |*parameter_node, *result_parameter_type| {
            const parameter = parameter_node.data.parameter;

            try checker.analyze(parameter.type);
            _ = try checker.check_type_tags(parameter.type, &.{.type});
            const parameters_type: *Type = parameter.type.comptime_value.?.type;
            result_parameter_type.* = parameters_type;

            const identifier: Symbol = checker.get_symbol(parameter.identifier);
            const data: LexicalContext.SymbolData = .init(parameters_type, parameter_node, null);
            const register_result = checker.lexical_context.register_symbol(identifier, data) catch |oom| oom_panic(oom);
            switch (register_result) {
                .ok => {},
                .duplicate => |duplicate| {
                    const identifier_text = checker.get_symbol_text(identifier);
                    if (duplicate.declaration_node) |decl_node| {
                        checker.reporter.err(.loc(checker.ast.loc_of(parameter.identifier)), "Duplicate parameter '{s}'.", .{identifier_text});
                        checker.reporter.err(.loc(checker.ast.loc_of(decl_node)), "Parameter with the identifier '{s}' has already been declared here:", .{identifier_text});
                    } else {
                        checker.reporter.err(.loc(checker.ast.loc_of(parameter.identifier)), "Parameter '{s}' shadows a builtin with the same name.", .{identifier_text});
                    }
                    return InnerError.already_reported;
                },
            }
        }

        const return_type: *Type = return_type: {
            const return_type_node: *Ast.Node = header.return_type orelse break :return_type checker.type_id(.void);
            break :return_type try checker.analyze_type(return_type_node);
        };

        // TODO: push to the context current return type here
        try checker.analyze(function_literal.body);

        const function_literal_type: *Type = checker.type_id(.{
            .function = Type.Function{
                .name = null,
                .parameter_types = parameter_types,
                .return_type = return_type,
            },
        });

        annotate(node, .{
            .type = function_literal_type,
            .value_kind = .non_lvalue,
            .comptime_value = .{ .function = ComptimeValue.Function{
                .ast = node,
                .name = null,
            } },
        });
    }

    pub fn get_symbol_text(checker: *TypeChecker, symbol: Symbol) []const u8 {
        return checker.symbol_manager.text(symbol);
    }

    pub fn get_symbol(checker: *TypeChecker, piece_of_ast_or_string: anytype) Symbol {
        const T = @TypeOf(piece_of_ast_or_string);
        var text: []const u8 = undefined;
        if (comptime T == []const u8 or T == []u8) {
            text = piece_of_ast_or_string;
        } else {
            text = checker.ast.text_at(piece_of_ast_or_string);
        }
        const symbol = checker.symbol_manager.get(text) catch |oom| oom_panic(oom);
        return symbol;
    }

    fn analyze_type(checker: *TypeChecker, node: *Ast.Node) InnerError!*Type {
        try checker.analyze(node);
        _ = try checker.check_type_tags(node, &.{.type});
        return node.comptime_value.?.type;
    }

    fn analyze_declaration(
        checker: *TypeChecker,
        node: *Ast.Node,
        declaration: Ast.Declaration,
    ) InnerError!void {
        assert(node.data == .declaration);

        const identifier = checker.get_symbol(declaration.identifier);

        var maybe_decl_type: ?*Type = null;
        if (declaration.explicit_type) |type_node| {
            maybe_decl_type = try checker.analyze_type(type_node);
        }

        var comptime_value: ?ComptimeValue = null;

        if (declaration.inital_value) |initial_value_node| {
            try checker.analyze(initial_value_node);

            // Assign names to things that expect it.
            if (initial_value_node.comptime_value) |*value| {
                comptime_value = value.*;
                switch (value.*) {
                    .void, .integer, .boolean => {
                        // Do nothing
                    },
                    .type => |typ| switch (typ.*) {
                        .@"struct" => |*struct_info| {
                            if (struct_info.name == null) struct_info.name = identifier;
                        },
                        else => {},
                    },
                    .function => |*function| {
                        if (function.name == null) function.name = identifier;
                    },
                }
            }

            // Deduce declaration type
            if (maybe_decl_type == null) maybe_decl_type = initial_value_node.type.?;
        }

        const decl_type: *Type = maybe_decl_type orelse {
            const loc = checker.ast.loc_of(declaration.identifier);
            const identifier_text = checker.get_symbol_text(identifier);
            checker.reporter.err(.loc(loc), "Could not deduce the type of '{s}', please annotate the type.", .{identifier_text});
            return InnerError.already_reported;
        };

        if (declaration.inital_value) |initial_value| {
            checker.check_implicit_typecast(decl_type, initial_value) catch |err| {
                const loc = checker.ast.loc_of(declaration.explicit_type.?);
                checker.reporter.err(.loc(loc), "Type '{f}' required from here:", .{checker.fmt_type(decl_type)});
                return err;
            };
        }

        const register_result = checker.lexical_context.register_symbol(
            identifier,
            .init(decl_type, node, comptime_value),
        ) catch |oom| oom_panic(oom);

        switch (register_result) {
            .ok => {},
            .duplicate => |duplicate| {
                const identifier_text = checker.get_symbol_text(identifier);
                const loc = checker.ast.loc_of(declaration.identifier);
                if (duplicate.declaration_node) |previous_declaration| {
                    checker.reporter.err(.loc(loc), "Duplicate definition of '{s}':", .{identifier_text});
                    checker.reporter.help(.loc(checker.ast.loc_of(previous_declaration)), "Previous definition of '{s}' is here:", .{identifier_text});
                } else {
                    checker.reporter.err(.loc(loc), "The identifier '{s}' shadows a builtin of the same name.", .{identifier_text});
                }
                return InnerError.already_reported;
            },
        }

        annotate(node, .{
            .type = checker.type_id(.void),
            .value_kind = .non_lvalue,
            .comptime_value = null,
        });
    }

    fn check_implicit_typecast(
        checker: *TypeChecker,
        destination_type: *Type,
        source: *Ast.Node,
    ) InnerError!void {
        if (destination_type == source.type.?) return;

        // TODO: We should handle different integer types with implicit casting, when possible

        const loc = checker.ast.loc_of(source);
        checker.reporter.err(.loc(loc), "Type mismatch, expected '{f}', got '{f}'.", .{
            checker.fmt_type(destination_type),
            checker.fmt_type(source.type.?),
        });
        return InnerError.already_reported;
    }

    fn analyze_binary_op(
        checker: *TypeChecker,
        node: *Ast.Node,
        binary_op: Ast.BinaryOp,
    ) InnerError!void {
        const lhs: *Ast.Node = binary_op.lhs;
        const rhs: *Ast.Node = binary_op.rhs;

        try checker.analyze(lhs);
        try checker.analyze(rhs);

        // TODO: Compute the comptime-value below
        var result_comptime_value: ?ComptimeValue = null;
        _ = &result_comptime_value;
        const result_type: *Type = get_result_type: switch (binary_op.kind) {
            .add,
            .sub,
            => {
                _ = try checker.check_type_tags(rhs, &.{.i64});
                switch (try checker.check_type_tags(lhs, &.{ .i64, .pointer })) {
                    .i64 => {
                        break :get_result_type lhs.type.?;
                    },
                    .pointer => {
                        break :get_result_type lhs.type.?;
                    },
                }
            },

            .mul,
            .div,
            .mod,
            .bit_and,
            .bit_or,
            .bit_xor,
            => {
                _ = try checker.check_type_tags(lhs, &.{.i64});
                _ = try checker.check_type_tags(rhs, &.{.i64});
                break :get_result_type lhs.type.?;
            },

            .cmp_eq,
            .cmp_neq,
            => {
                // TODO: run peer-type resolution
                checker.reporter.warn(.loc(checker.ast.loc_of(node)), "We should run peer-type resolution here.", .{});
                break :get_result_type checker.type_id(.bool);
            },

            .logic_and,
            .logic_or,
            => {
                _ = try checker.check_type_tags(lhs, &.{.bool});
                _ = try checker.check_type_tags(rhs, &.{.bool});
                break :get_result_type checker.type_id(.bool);
            },

            .cmp_lt,
            .cmp_gt,
            .cmp_lteq,
            .cmp_gteq,
            => {
                _ = try checker.check_type_tags(lhs, &.{.i64});
                _ = try checker.check_type_tags(rhs, &.{.i64});
                break :get_result_type checker.type_id(.bool);
            },

            .array_access,
            => {
                const loc = checker.ast.loc_of(node);
                return checker.todo(.loc(loc), "Analyze binary expression of kind '{t}'", .{binary_op.kind});
            },
        };

        annotate(node, .{
            .type = result_type,
            .value_kind = .non_lvalue,
            .comptime_value = result_comptime_value,
        });
    }

    fn check_type_tags(
        checker: *TypeChecker,
        node: *Ast.Node,
        comptime expected_tags: []const Type.Tag,
    ) InnerError!UnionSubsetOf(Type, expected_tags) {
        comptime assert(expected_tags.len != 0);
        const TypeInfoSubset = UnionSubsetOf(Type, expected_tags);

        const actual_type: *Type = node.type.?;
        inline for (expected_tags) |tag| {
            if (actual_type.* == tag) {
                const PayloadType = @FieldType(Type, @tagName(tag));
                const payload: PayloadType = @field(actual_type.*, @tagName(tag));
                return @unionInit(TypeInfoSubset, @tagName(tag), payload);
            }
        }

        const loc = checker.ast.loc_of(node);
        checker.reporter.err(
            .loc(loc),
            "This expression has unexpected type '{f}', expected {f}.",
            .{
                checker.fmt_type(actual_type),
                // Yummers (custom format struct to to print the expected tags)
                (struct {
                    pub fn format(_: @This(), w: *std.Io.Writer) std.Io.Writer.Error!void {
                        if (expected_tags.len > 1) {
                            try w.print("one of: ", .{});
                        }
                        for (expected_tags, 0..) |tag, idx| {
                            if (idx != 0) try w.print(", ", .{});
                            try w.print("{t}", .{tag});
                        }
                    }
                }){},
            },
        );

        return InnerError.already_reported; // Yup, "an error" has been reported xd
    }

    pub fn fmt_type(checker: *TypeChecker, typ: *Type) FmtType {
        return FmtType{ .checker = checker, .typ = typ };
    }

    pub const FmtType = struct {
        checker: *TypeChecker,
        typ: *Type,
        pub fn format(self: FmtType, w: *std.Io.Writer) std.Io.Writer.Error!void {
            switch (self.typ.*) {
                .i64,
                .void,
                .bool,
                .null,
                .type,
                => try w.print("{t}", .{self.typ.*}),
                .pointer => |pointer| {
                    try w.print("^{f}", .{self.checker.fmt_type(pointer.child)});
                },
                .function => |function| {
                    try w.print("fn(", .{});
                    for (function.parameter_types, 0..) |parameter_type, idx| {
                        if (idx != 0) try w.print(", ", .{});
                        try w.print("{f}", .{self.checker.fmt_type(parameter_type)});
                    }
                    try w.print(") {f}", .{self.checker.fmt_type(function.return_type)});
                },
                .slice => |slice| {
                    try w.print("[]{f}", .{self.checker.fmt_type(slice.child)});
                },
                .@"struct" => |@"struct"| {
                    if (@"struct".name) |name| {
                        try w.print("struct {s}", .{self.checker.get_symbol_text(name)});
                    } else {
                        try w.print("struct {{ ", .{});
                        for (@"struct".members, 0..) |member, idx| {
                            if (idx != 0) try w.print(" ", .{});
                            try w.print("{s}: {f};", .{
                                self.checker.symbol_manager.text(member.name),
                                self.checker.fmt_type(member.type),
                            });
                        }
                        try w.print(" }}", .{});
                    }
                },
            }
        }
    };

    fn type_id(checker: *TypeChecker, typ: Type) *Type {
        switch (typ) {
            .function,
            .@"struct",
            => {
                // All structs and functions are of a unique type
                const typ_ptr: *Type = checker.arena.create(Type) catch |oom| oom_panic(oom);
                typ_ptr.* = typ;
                return typ_ptr;
            },

            .i64,
            .bool,
            .void,
            .null,
            .type,
            .pointer,
            .slice,
            => {
                const gop = checker.types_lookup.getOrPut(checker.arena, @constCast(&typ)) catch |oom| oom_panic(oom);
                if (!gop.found_existing) {
                    const typ_ptr: *Type = checker.arena.create(Type) catch |oom| oom_panic(oom);
                    typ_ptr.* = typ;
                    gop.key_ptr.* = typ_ptr;
                }
                return gop.key_ptr.*;
            },
        }
    }

    fn analyze_integer_literal(checker: *TypeChecker, node: *Ast.Node) InnerError!void {
        assert(node.data.tag() == .integer_literal);

        const text: []const u8 = checker.ast.text_at(node);

        const value = std.fmt.parseInt(ComptimeValue.Integer, text, 10) catch |err| switch (err) {
            error.InvalidCharacter => std.debug.panic("The string '{s}' should not be an invalid integer literal.", .{text}),
            error.Overflow => {
                const loc = checker.ast.loc_of(node);
                checker.reporter.err(.loc(loc), "The value {s} is too big. Maximum for an integer literal is {d}.", .{ text, std.math.maxInt(ComptimeValue.Integer) });
                return InnerError.already_reported;
            },
        };

        annotate(node, .{
            .type = checker.type_id(.i64),
            .value_kind = .non_lvalue,
            .comptime_value = .{ .integer = value },
        });
    }

    fn todo(checker: *TypeChecker, where: Reporter.Where, comptime fmt: []const u8, args: anytype) InnerError {
        checker.reporter.err(where, fmt, args);
        return InnerError.TODO;
    }

    pub const AnnotateOptions = struct {
        type: *Type,
        value_kind: ValueKind,
        comptime_value: ?ComptimeValue = null,
    };
    pub fn annotate(node: *Ast.Node, options: AnnotateOptions) void {
        assert(node.type == null);
        node.type = options.type;
        node.value_kind = options.value_kind;
        node.comptime_value = options.comptime_value;
    }

    // For semantic analysis of this Zig code
    comptime {
        for (@typeInfo(TypeChecker).@"struct".decls) |decl| {
            _ = &@field(TypeChecker, decl.name);
        }
    }
};

pub fn UnionSubsetOf(
    comptime TaggedUnion: type,
    comptime tags: []const (@typeInfo(TaggedUnion).@"union".tag_type.?),
) type {
    const FullTag = @typeInfo(TaggedUnion).@"union".tag_type.?;
    const TagInt = @typeInfo(FullTag).@"enum".tag_type;

    var field_names: [tags.len][]const u8 = undefined;
    var field_types: [tags.len]type = undefined;
    var field_tag_values: [tags.len]TagInt = undefined;
    for (tags, &field_names, &field_types, &field_tag_values) |tag, *field_name, *field_type, *field_tag_value| {
        field_name.* = @tagName(tag);
        field_type.* = @FieldType(TaggedUnion, @tagName(tag));
        field_tag_value.* = @intFromEnum(tag);
    }

    const Tag = @Enum(TagInt, .exhaustive, &field_names, &field_tag_values);
    const Subset = @Union(.auto, Tag, &field_names, &field_types, &@splat(.{ .@"align" = null }));

    return Subset;
}

pub inline fn oom_panic(_: Oom) noreturn {
    @branchHint(.cold);
    @panic("RUNTIME ERROR: Ran out of memory :(");
}

test "sema snapshot tests" {
    const snap = @import("snapshot_testing.zig");
    const test_options = @import("snapshot_test_options");

    const producer = struct {
        fn producer(input: []const u8, backing_allocator: std.mem.Allocator, out: *std.Io.Writer, err_out: *std.Io.Writer) anyerror!void {
            const source_code = input;
            var arena = std.heap.ArenaAllocator.init(backing_allocator);
            defer arena.deinit();
            const gpa = arena.allocator();

            const tokens: []const frontend.Token = try frontend.tokenize(
                .{ .gpa = gpa, .source_code = source_code },
            );
            var reporter = Reporter{
                .terminal = .{ .mode = .no_color, .writer = err_out },
                .source_code = source_code,
                .filepath = null,
            };
            var parser = frontend.Parser{
                .arena = gpa,
                .next_token_id = .{ .index = 0 },
                .nodes = .empty,
                .reporter = &reporter,
                .tokens = tokens,
            };
            const ast: Ast = parser.parse() catch |err| switch (err) {
                Oom.OutOfMemory => return err,
                frontend.ParseError.invalid_syntax => {
                    try err_out.print("Failed with error: {t}\n", .{err});
                    return;
                },
            };

            var interning_manager = SymbolManager{ .gpa = gpa };
            var lexical_context = LexicalContext.init(gpa);
            defer lexical_context.deinit_assert_empty();

            var type_checker = TypeChecker{
                .arena = arena.allocator(),
                .ast = ast,
                .symbol_manager = &interning_manager,
                .lexical_context = &lexical_context,
                .reporter = &reporter,
            };

            if (type_checker.type_check()) {
                try frontend.print_ast(gpa, .{ .mode = .no_color, .writer = out }, ast, &type_checker);
            } else |err| {
                try err_out.print("\n\nEncountered error: {t}.", .{err});
            }
        }
    }.producer;

    const options = test_options;
    try snap.run_snapshot_tests(.{
        .snapshots_dir = options.snapshots_dir ++ "/sema",
        .test_inputs_dir = options.test_inputs_dir ++ "/sema",
        .test_name = "semantic analysis",
        .producer = producer,
        .be_verbose = options.be_verbose,
        .show_diff = options.show_diff,
        .accept_new_snapshots = options.accept_new_snapshots,
    });
}
