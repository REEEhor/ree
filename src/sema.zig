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
    mapping: std.array_hash_map.String(void),

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

pub const TypeInfo = union(enum(u8)) {
    /// Presumming 32 bits for now
    int,
    compile_int,
    bool,
    void,
    null,
    type,
    pointer: Pointer,
    slice: Slice,
    @"struct": Struct,

    pub fn tag(info: TypeInfo) Tag {
        return std.meta.activeTag(info);
    }
    pub const Tag = std.meta.Tag(@This());

    pub const Pointer = packed struct {
        child: TypeId,
    };
    pub const Slice = packed struct {
        child: TypeId,
    };
    pub const Struct = struct {
        name: ?Symbol,
        members: []const Member,
        pub const Member = struct {
            name: Symbol,
            type: TypeId,
        };
    };

    pub fn compress(type_info: TypeInfo) Compressed {
        switch (type_info) {
            .@"struct" => @panic("Tried to pass 'struct' type info into the 'compress' function"),
            inline else => |payload, t| {
                const PayloadType: type = @FieldType(TypeInfo, @tagName(t));
                comptime assert(is_compressable(t));
                if (PayloadType == void) {
                    return Compressed{ .t = t, .raw_payload = 0 };
                } else {
                    const BackingIntType: type = @typeInfo(PayloadType).@"struct".backing_integer.?;
                    const payload_as_int: BackingIntType = @bitCast(payload);

                    // If you get an error here, it means the backing int of the payload is too big
                    const raw_payload: Compressed.RawPayload = payload_as_int;
                    return Compressed{ .t = t, .raw_payload = raw_payload };
                }
            },
        }
    }

    pub fn is_compressable(t: TypeInfo.Tag) bool {
        return switch (t) {
            .int,
            .compile_int,
            .bool,
            .void,
            .null,
            .type,
            .pointer,
            .slice,
            => true,
            //
            .@"struct" => false,
        };
    }

    pub const Compressed = packed struct {
        t: Tag,
        raw_payload: RawPayload,

        pub const RawPayload = @Int(.unsigned, (3 * 64) - 8);

        comptime {
            assert(@bitSizeOf(Tag) == 8);
            assert(@bitSizeOf(Compressed) == 3 * 64);
        }

        pub fn decompress(compressed: Compressed) TypeInfo {
            switch (compressed) {
                .@"struct" => unreachable,
                inline else => |t| {
                    const PayloadType: type = @FieldType(TypeInfo, @tagName(t));
                    if (PayloadType == void) {
                        return @unionInit(TypeInfo, @tagName(t), {});
                    } else {
                        const BackingIntType: type = @typeInfo(PayloadType).@"struct".backing_integer.?;
                        const backing_int: BackingIntType = @truncate(compressed.raw_payload);
                        assert(backing_int == compressed.raw_payload);
                        const payload: PayloadType = @bitCast(backing_int);
                        return @unionInit(TypeInfo, @tagName(t), payload);
                    }
                },
            }
        }
    };
};

pub const TypeId = packed struct {
    index: IndexRepr,
    pub const IndexRepr = u64;
    pub fn from_int(int: IndexRepr) TypeId {
        return .{ .index = int };
    }
    pub fn as_int(id: TypeId) IndexRepr {
        return id.index;
    }
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
        type: TypeId,
        /// Guaranteed to be `Ast.Declaration`.
        declaration_node: Ast.NodeId,
        comptime_value: ?ComptimeValue,
    };
};

pub const ComptimeValue = union(enum) {
    integer: std.math.big.int.Const,
};

pub const ValueKind = enum {
    lvalue,
    /// NOTE: we will probably have to change this at some point
    non_lvalue,
};

pub const Annotation = struct {
    type: TypeId,
    value_kind: ValueKind,
    comptime_value: ?ComptimeValue = null,
};

pub const TypeChecker = struct {
    arena: std.mem.Allocator,

    ast: Ast,
    symbol_manager: *SymbolManager,
    lexical_context: *LexicalContext,
    reporter: *Reporter,

    /// Represents the mapping 'TypeId.index' -> 'TypeInfo'
    id_to_info: std.ArrayList(TypeInfo),

    compressed_info_to_id: std.array_hash_map.Auto(TypeInfo.Compressed, TypeId),

    annotations: std.AutoHashMapUnmanaged(Ast.NodeId, Annotation),

    const InnerError = error{ already_reported, TODO };

    fn analyze(checker: *TypeChecker, node_id: Ast.NodeId) InnerError!Annotation {
        const node = checker.ast.get_node(node_id);
        switch (node.data) {
            .integer_literal => return checker.analyze_integer_literal(node_id),
            .binary_op => |binary_op| return checker.analyze_binary_op(node_id, binary_op),
            else => |_, tag| {
                const loc = checker.ast.loc_of(node);
                checker.reporter.err(.loc(loc), "TODO: 'check' of node of kind '{t}'", .{tag});
                return InnerError.already_reported;
            },
        }
    }

    fn analyze_binary_op(
        checker: *TypeChecker,
        node_id: Ast.NodeId,
        binary_op: Ast.BinaryOp,
    ) InnerError!Annotation {
        _ = checker;
        _ = node_id;
        _ = binary_op;

        // const lhs: Annotation = try checker.analyze(binary_op.lhs);
        // const rhs: Annotation = try checker.analyze(binary_op.rhs);
        //
        // const result_type: TypeInfo = switch (binary_op.kind) {
        //     .add,
        //     .sub,
        //     => {
        //         // try checker.check_type_tags(binary_op.lhs, &.{});
        //     },
        //
        //     .mul,
        //     .div,
        //     .mod,
        //     => {
        //         _ = try checker.check_type_tags(binary_op.lhs, &.{ .int, .compile_int });
        //         _ = try checker.check_type_tags(binary_op.rhs, &.{ .int, .compile_int });
        //     },
        //
        //     .bit_and,
        //     .bit_or,
        //     .bit_xor,
        //     //
        //     .cmp_lt,
        //     .cmp_gt,
        //     .cmp_eq,
        //     .cmp_neq,
        //     .cmp_lteq,
        //     .cmp_gteq,
        //     //
        //     .logic_and,
        //     .logic_or,
        //     .array_access,
        //     => {
        //         const loc = checker.ast.loc_of(node_id);
        //         return checker.todo(.loc(loc), "Check of binary expression of kind '{t}'", .{binary_op.kind});
        //     },
        // };
        //
        // if (lhs.comptime_value) |lhs_value| if (rhs.comptime_value) |rhs_value| {
        //     var result = std.math.big.int.Managed.init(checker.arena) catch |oom| oom_panic(oom);
        //     // switch () {}
        // };
    }

    fn check_type_tags(
        checker: *TypeChecker,
        node_id: Ast.NodeId,
        comptime expected_tags: []const TypeInfo.Tag,
    ) InnerError!UnionSubsetOf(TypeInfo, expected_tags) {
        comptime assert(expected_tags.len != 0);
        const TypeInfoSubset = UnionSubsetOf(TypeInfo, expected_tags);

        const annotation = checker.annotations.get(node_id).?;
        const actual_type = checker.get_type_info(annotation.type);
        inline for (expected_tags) |tag| {
            if (actual_type == tag) {
                const PayloadType = @FieldType(actual_type, @tagName(tag));
                const payload: PayloadType = @field(actual_type, @tagName(tag));
                return @unionInit(TypeInfoSubset, @tagName(tag), payload);
            }
        }

        const loc = checker.ast.loc_of(node_id);
        checker.reporter.err(
            .loc(loc),
            "Invalid type '{f}', expected {f}.",
            .{
                checker.fmt_type(annotation.type),
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

    pub fn fmt_type(checker: *TypeChecker, type_id_or_info: anytype) FmtType {
        const T = @TypeOf(type_id_or_info);
        const type_info: TypeInfo = switch (T) {
            TypeId => checker.get_type_info(type_id_or_info),
            TypeInfo => type_id_or_info,
            else => @compileError("Invalid type '" ++ @typeName(T) ++ "'"),
        };
        return FmtType{ .checker = checker, .type_info = type_info };
    }

    pub const FmtType = struct {
        checker: *TypeChecker,
        type_info: TypeInfo,
        pub fn format(self: FmtType, w: *std.Io.Writer) std.Io.Writer.Error!void {
            switch (self.type_info) {
                .int,
                => try w.print("i32", .{}),
                .compile_int,
                .bool,
                .void,
                .null,
                .type,
                => try w.print("{t}", .{self.type_info}),
                .pointer => |pointer| {
                    try w.print("^{f}", .{self.checker.fmt_type(pointer.child)});
                },
                .slice => |slice| {
                    try w.print("[]{f}", .{self.checker.fmt_type(slice.child)});
                },
                .@"struct" => |@"struct"| {
                    if (@"struct".name) |name| {
                        try w.print("struct {s}", .{self.checker.symbol_manager.text(name)});
                    } else {
                        try w.print("struct { ", .{});
                        for (@"struct".members, 0..) |member, idx| {
                            if (idx != 0) try w.print(" ", .{});
                            try w.print("{s}: {f};", .{
                                self.checker.symbol_manager.text(member.name),
                                self.checker.fmt_type(member.type),
                            });
                        }
                        try w.print(" }", .{});
                    }
                },
            }
        }
    };

    fn get_type_info(checker: *TypeChecker, type_id: TypeId) TypeInfo {
        return checker.id_to_info.items[type_id.as_int()];
    }

    fn analyze_integer_literal(checker: *TypeChecker, node_id: Ast.NodeId) InnerError!Annotation {
        assert(checker.ast.get_node(node_id).data.tag() == .integer_literal);

        const text: []const u8 = checker.ast.text_at(node_id);
        var big_int = std.math.big.int.Managed.init(checker.arena) catch |oom| oom_panic(oom);

        big_int.setString(10, text) catch |err| switch (err) {
            Oom.OutOfMemory => |oom| oom_panic(oom),
            error.InvalidCharacter => std.debug.panic("The string '{s}' should not be an invalid integer literal.", .{text}),
            error.InvalidBase => @panic("The base is chosen by the literal '10' in the code - should be a valid base."),
        };
        const value = big_int.toMutable().toConst();

        return checker.create_annotation(node_id, .{
            .type = checker.get_type_id(.compile_int),
            .value_kind = .non_lvalue,
            .comptime_value = .{ .integer = value },
        });
    }

    fn todo(checker: *TypeChecker, where: Reporter.Where, comptime fmt: []const u8, args: anytype) InnerError {
        checker.reporter.err(where, fmt, args);
        return InnerError.TODO;
    }

    pub fn create_annotation(checker: *TypeChecker, node_id: Ast.NodeId, annotation: Annotation) Annotation {
        checker.annotations.putNoClobber(checker.arena, node_id, annotation) catch |oom| oom_panic(oom);
        return annotation;
    }

    pub fn get_type_id(checker: *TypeChecker, type_info: TypeInfo) TypeId {
        switch (type_info) {
            .@"struct" => {
                // All structs are unique types
                checker.id_to_info.append(checker.arena, type_info) catch |oom| oom_panic(oom);
                return TypeId.from_int(checker.id_to_info.items.len - 1);
            },
            inline else => |_, tag| {
                comptime assert(TypeInfo.is_compressable(tag));
                const compressed_type_info: TypeInfo.Compressed = type_info.compress();
                const gop = checker.compressed_info_to_id.getOrPut(checker.arena, compressed_type_info) catch |oom| oom_panic(oom);
                if (gop.found_existing) {
                    return gop.value_ptr.*;
                }
                checker.id_to_info.append(checker.arena, type_info) catch |oom| oom_panic(oom);
                const type_id = TypeId.from_int(checker.id_to_info.items.len - 1);
                gop.value_ptr.* = type_id;
                return type_id;
            },
        }
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
    const Tag = @typeInfo(TaggedUnion).@"union".tag_type.?;

    const field_names: [tags.len][]const u8 = undefined;
    const field_types: [tags.len][]std.builtin.Type = undefined;
    for (tags, field_names, field_types) |tag, *field_name, field_type| {
        field_name.* = @tagName(tag);
        field_type.* = @FieldType(TaggedUnion, @tagName(tag));
    }
    return @Union(.auto, Tag, field_names, field_types, @splat(.{ .@"align" = null }));
}

pub inline fn oom_panic(_: Oom) noreturn {
    @branchHint(.cold);
    @panic("RUNTIME ERROR: Ran out of memory :(");
}
