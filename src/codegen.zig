const std = @import("std");
const assert = std.debug.assert;

const Oom = std.mem.Allocator.Error;

const irgen = @import("irgen.zig");
const Ir = irgen.Ir;
const StringLiteral = irgen.StringLiteral;
const IrVar = irgen.IrVar;

pub const IrVarInfo = union(enum) {
    operand: Operand,
    // temporary: Operand.RegisterOffset,
};

pub const CommentId = packed struct {
    index: IndexRepr,
    pub const IndexRepr = u64;
};

pub const CodeGen = struct {
    gpa: std.mem.Allocator,
    instructions: std.ArrayList(Instruction),
    ir: Ir,
    ir_var_info: std.array_hash_map.Auto(IrVar, IrVarInfo),
    max_ir_var: IrVar,
    /// Represents the mapping `CommentId` -> 'text of the comment'
    comments: std.ArrayList([]const u8) = .empty,

    /// Represents the mapping 'text of a symbol' -> `Symbol.index`
    symbol_map: std.array_hash_map.String(void),

    const I = instruction_constructors;
    const symbol_print_int = Symbol{ .index = 0 };

    pub fn generate_assembly(gen: *CodeGen) !void {
        // TODO: move this initialization elsewhere
        assert(symbol_print_int == try gen.get_symbol("print_int"));

        // Store base pointer as the current stack pointer
        try gen.add_instruction(I.mov(.rbp, .rsp));

        // Allocate space for the stack
        try gen.add_instruction(I.sub(.rsp, .imm(0)));
        const allocate_stack_size_instruction_index = gen.instructions.items.len - 1;
        var stack_size: i32 = 0;
        defer {
            // Stack has to be aligned to 16 bytes (for some reason)
            // Source of this information: Claude xd
            stack_size = std.mem.alignForward(i32, stack_size, 16);
            gen.instructions.items[allocate_stack_size_instruction_index].sub.rhs.immediate = stack_size;
        }

        // TODO: We expect all types to be i32 for now
        const size_of_all_types = 4;

        // Register stack-allocated variables and constants
        {
            for (gen.ir.instructions.items) |ir_instruction| {
                switch (ir_instruction) {
                    .stack_alloc => |stack_alloc| {
                        try gen.ir_var_info.putNoClobber(gen.gpa, stack_alloc.dest, .{ .operand = Operand{
                            .register_offset = .{ .offset = -stack_size - size_of_all_types, .register = .rbp },
                        } });
                        stack_size += size_of_all_types;
                    },
                    .assign_constant => |assign_constant| {
                        try gen.ir_var_info.putNoClobber(gen.gpa, assign_constant.dest, .{ .operand = Operand{
                            .immediate = assign_constant.constant.value,
                        } });
                    },
                    else => continue,
                }
            }
        }

        // Allocate space for the rest of the temporaries
        // (as we don't do register allocation yet, we put on the stack xd)
        {
            for (0..(gen.max_ir_var.index + 1)) |ir_var_index| {
                const ir_var = IrVar{ .index = ir_var_index };
                const gop = try gen.ir_var_info.getOrPut(gen.gpa, ir_var);
                if (!gop.found_existing) {
                    gop.value_ptr.* = .{ .operand = .{ .register_offset = .{
                        .register = .rbp,
                        .offset = -stack_size - size_of_all_types,
                    } } };
                    stack_size += size_of_all_types;
                }
            }
        }

        // Okay, let's compile the code
        for (gen.ir.instructions.items) |ir_instruction| {
            switch (ir_instruction) {
                .mov => |mov| {
                    try gen.add_line_comment("mov", .{});

                    try gen.add_instruction(.{ .mov = .{
                        .src = try gen.generate_operand_from_ir_var(mov.source),
                        .dest = try gen.generate_operand_from_ir_var(mov.dest),
                    } });
                },
                .load => |load| {
                    try gen.add_line_comment("load", .{});

                    const src = try gen.generate_operand_from_ir_var(load.source_pointer);
                    const dest = try gen.generate_operand_from_ir_var(load.dest);
                    if (src.is_memory_access() and dest.is_memory_access()) {
                        const src_as_register: Operand = .rNd(8);
                        try gen.add_instruction(I.mov(src_as_register, src));
                        try gen.add_instruction(I.mov(dest, src_as_register));
                    } else {
                        try gen.add_instruction(I.mov(dest, src));
                    }
                },
                .store => |store| {
                    try gen.add_line_comment("store", .{});

                    const src = try gen.generate_operand_from_ir_var(store.source);
                    const dest = try gen.generate_operand_from_ir_var(store.dest_pointer);
                    if (src.is_memory_access() and dest.is_memory_access()) {
                        const src_as_register: Operand = .rNd(8);
                        try gen.add_instruction(I.mov(src_as_register, src));
                        try gen.add_instruction(I.mov(dest, src_as_register));
                    } else {
                        try gen.add_instruction(I.mov(dest, src));
                    }
                },
                .unary_op => |unary_op| {
                    try gen.add_line_comment("unary_op({t})", .{unary_op.kind});

                    const tmp_register: Operand = .rNd(8);
                    try gen.add_instruction(.{ .mov = .{
                        .src = try gen.generate_operand_from_ir_var(unary_op.dest),
                        .dest = tmp_register,
                    } });
                    switch (unary_op.kind) {
                        .negate => try gen.add_instruction(.{ .neg = .{
                            .operand = tmp_register,
                        } }),
                    }
                    try gen.add_instruction(.{ .mov = .{
                        .src = tmp_register,
                        .dest = try gen.generate_operand_from_ir_var(unary_op.dest),
                    } });
                },
                .binary_op => |binary_op| {
                    try gen.add_line_comment("binary_op({t})", .{binary_op.kind});

                    const lhs_reg: Operand = .rNd(8);
                    const lhs = try gen.generate_operand_from_ir_var(binary_op.lhs);
                    try gen.add_instruction(I.mov(lhs_reg, lhs));

                    const rhs_reg: Operand = .rNd(9);
                    const rhs = try gen.generate_operand_from_ir_var(binary_op.rhs);
                    try gen.add_instruction(I.mov(rhs_reg, rhs));

                    switch (binary_op.kind) {
                        .add => {
                            try gen.add_instruction(I.add(lhs_reg, rhs_reg));
                        },
                        .sub => {
                            try gen.add_instruction(I.sub(lhs_reg, rhs_reg));
                        },
                        .mul => {
                            const actual_lhs = Instruction.IMul.lhs;
                            if (!lhs_reg.eql(actual_lhs)) {
                                try gen.add_instruction(I.mov(actual_lhs, lhs_reg));
                            }
                            try gen.add_instruction(I.imul(rhs_reg));
                            if (!lhs_reg.eql(actual_lhs)) {
                                try gen.add_instruction(I.mov(lhs_reg, actual_lhs));
                            }
                        },
                        .div => {
                            const actual_lhs = Instruction.IDiv.quotient;
                            if (!lhs_reg.eql(actual_lhs)) {
                                try gen.add_instruction(I.mov(actual_lhs, lhs_reg));
                            }
                            try gen.add_instruction(I.idiv(rhs_reg));
                            if (!lhs_reg.eql(actual_lhs)) {
                                try gen.add_instruction(I.mov(lhs_reg, actual_lhs));
                            }
                        },
                    }

                    const dest: Operand = try gen.generate_operand_from_ir_var(binary_op.dest);
                    try gen.add_instruction(I.mov(dest, lhs_reg));
                },
                .print_int_call => |print_int_call| {
                    try gen.add_line_comment("print_int_call", .{});

                    const arg = try gen.generate_operand_from_ir_var(print_int_call.int_to_print);
                    try gen.add_instruction(I.mov_sign_extend(.rdi, arg));
                    try gen.add_instruction(I.call(symbol_print_int));

                    //// TODO:
                    //// 'Write' syscall
                    //try gen.add_instruction(I.mov(.rax, .imm(1))); // Syscall number 1 => `write`
                    //try gen.add_instruction(I.mov(.rdi, .imm(1))); // fd 1 = stdout
                    //// lea rsi, [rip + str]
                    //// address of the string literal
                    //try gen.add_instruction(.{ .lea = .{
                    //    .dest = .rsi,
                    //    .base = .rip,
                    //    .offset = .{ .label = str },
                    //} });
                    //try gen.add_instruction(I.mov(.rdx, .{ .string_literal_length = str })); // Length of the string
                    //try gen.add_instruction(I.syscall);
                },

                // Do nothing, we already handled this above
                .assign_constant,
                .stack_alloc,
                => {},
            }
        }

        // Generate `exit(0)`:
        try gen.add_instruction(I.mov(.rax, .imm(60)));
        try gen.add_instruction(I.mov(.rdi, .imm(0)));
        try gen.add_instruction(I.syscall);
    }

    fn get_symbol(gen: *CodeGen, symbol_text: []const u8) Oom!Symbol {
        const gop = try gen.symbol_map.getOrPut(gen.gpa, symbol_text);
        return Symbol{ .index = gop.index };
    }

    fn generate_operand_from_ir_var(gen: *CodeGen, ir_var: IrVar) !Operand {
        return gen.ir_var_info.get(ir_var).?.operand;
    }

    pub fn add_line_comment(gen: *CodeGen, comptime fmt: []const u8, args: anytype) !void {
        const comment_text = try std.fmt.allocPrint(gen.gpa, fmt, args);
        try gen.comments.append(gen.gpa, comment_text);
        const id = CommentId{ .index = gen.comments.items.len - 1 };
        try gen.add_instruction(.{ .empty_line_with_comment = .{ .comment_id = id } });
    }

    pub fn add_instruction(gen: *CodeGen, instruction: Instruction) !void {
        try gen.instructions.append(gen.gpa, instruction);
    }

    pub fn get_assembly(gen: *CodeGen, string_literals: []const []const u8) !Assembly {
        return Assembly{
            .instructions = try gen.instructions.toOwnedSlice(gen.gpa),
            .string_literals = string_literals,
            .symbol_map = gen.symbol_map,
            .comments = try gen.comments.toOwnedSlice(gen.gpa),
        };
    }

    //
};

pub const Assembly = struct {
    string_literals: []const []const u8,
    instructions: []const Instruction,
    symbol_map: std.array_hash_map.String(void),
    /// Represents the mapping `CommentId` -> 'text of the comment'
    comments: []const []const u8,
};

pub const Address = packed struct {
    index: u64,
};

pub const Symbol = packed struct {
    index: IndexRepr,
    pub const IndexRepr = u64;
    pub const max_index = std.math.maxInt(IndexRepr);
};

pub const Instruction = union(enum) {
    mov: struct { dest: Operand, src: Operand },
    /// Move sign extend
    movsxd: struct { dest: Operand, src: Operand },
    call: struct { symbol: Symbol },
    lea: Lea,
    syscall,
    add: LhsRhs,
    sub: LhsRhs,
    imul: IMul,
    idiv: IDiv,
    neg: struct { operand: Operand },
    empty_line,
    empty_line_with_comment: struct { comment_id: CommentId },

    pub const IMul = struct {
        rhs: Operand,
        pub const lhs: Operand = .eax;
    };

    pub const IDiv = struct {
        rhs: Operand,
        pub const quotient: Operand = .rax;
        pub const remainder: Operand = .edx;
    };

    pub const LhsRhs = struct {
        lhs: Operand,
        rhs: Operand,
    };

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

/// Namespace with helper functions.
pub const instruction_constructors = struct {
    pub fn add(lhs: Operand, rhs: Operand) Instruction {
        return .{ .add = .{ .lhs = lhs, .rhs = rhs } };
    }
    pub fn sub(lhs: Operand, rhs: Operand) Instruction {
        return .{ .sub = .{ .lhs = lhs, .rhs = rhs } };
    }
    pub fn imul(rhs: Operand) Instruction {
        return .{ .imul = .{ .rhs = rhs } };
    }
    pub fn idiv(rhs: Operand) Instruction {
        return .{ .idiv = .{ .rhs = rhs } };
    }
    pub fn mov(dest: Operand, src: Operand) Instruction {
        return .{ .mov = .{ .src = src, .dest = dest } };
    }
    pub fn mov_sign_extend(dest: Operand, src: Operand) Instruction {
        return .{ .movsxd = .{ .src = src, .dest = dest } };
    }
    pub fn movsxd(dest: Operand, src: Operand) Instruction {
        return mov_sign_extend(dest, src);
    }
    pub fn call(symbol: Symbol) Instruction {
        return .{ .call = .{ .symbol = symbol } };
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
    immediate: i32,
    register: Register,
    register_offset: RegisterOffset,
    string_literal_begin: StringLiteral,
    string_literal_length: StringLiteral,

    pub fn eql(left_op: Operand, right_op: Operand) bool {
        return std.meta.eql(left_op, right_op);
    }

    pub const eax = Operand{ .register = .eax };
    pub const rax = Operand{ .register = .rax };
    //
    pub const edx = Operand{ .register = .edx };
    pub const rdx = Operand{ .register = .rdx };
    //
    pub const rdi = Operand{ .register = .rdi };
    pub const rip = Operand{ .register = .rip };
    pub const rsi = Operand{ .register = .rsi };
    pub const rsp = Operand{ .register = .rsp };
    pub const rbp = Operand{ .register = .rbp };

    /// Constructor for the registers r8d ... r15d
    pub fn rNd(index: u4) Operand {
        return Operand{ .register = .rNd(index) };
    }
    pub fn imm(value: i32) Operand {
        return .{ .immediate = value };
    }
    pub fn reg(r: Register) Operand {
        return .{ .register = r };
    }

    pub fn is_memory_access(op: Operand) bool {
        return switch (op) {
            .string_literal_begin,
            .register_offset,
            => true,
            .immediate,
            .register,
            .string_literal_length,
            => false,
        };
    }

    pub const RegisterOffset = struct {
        register: Register,
        offset: i32,
    };

    pub fn format(
        op: Operand,
        writer: *std.Io.Writer,
    ) std.Io.Writer.Error!void {
        switch (op) {
            .immediate => |value| try writer.print("{d}", .{value}),
            .register => |register| try writer.print("{f}", .{register}),
            .register_offset => |register_offset| try writer.print("dword ptr [{f}{s}{d}]", .{
                register_offset.register,
                if (register_offset.offset >= 0) "+" else "-",
                @abs(register_offset.offset),
            }),
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

    pub const eax = Register{ .id = .from_int(0), .width = .@"32" };
    pub const rax = Register{ .id = .from_int(0), .width = .@"64" };
    //
    pub const edx = Register{ .id = .from_int(2), .width = .@"32" };
    pub const rdx = Register{ .id = .from_int(2), .width = .@"64" };
    //
    pub const rbp = Register{ .id = .from_int(5), .width = .@"64" };
    pub const rsp = Register{ .id = .from_int(4), .width = .@"64" };
    pub const rsi = Register{ .id = .from_int(6), .width = .@"64" };
    pub const rdi = Register{ .id = .from_int(7), .width = .@"64" };
    pub const rip = Register{ .id = .instruction_pointer, .width = .@"64" };

    /// Constructor for the registers r8d ... r15d
    pub fn rNd(index: u4) Register {
        assert(8 <= index);
        assert(index <= 15);
        return Register{
            .width = .@"32",
            .id = .from_int(index),
        };
    }

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
        print_instruction(as, instruction, w);
    }

    if (w.has_error) {
        return std.Io.Writer.Error.WriteFailed;
    }

    try w.inner.flush();
}

pub fn print_instruction(as: Assembly, instr: Instruction, w: *Writer) void {
    w.print("{INDENT}", .{});
    switch (instr) {
        .empty_line,
        .empty_line_with_comment,
        => {
            // Do nothing
        },
        else => {
            w.print("{t}", .{instr});
        },
    }
    switch (instr) {
        .mov => |mov| w.print(" {f}, {f}", .{ mov.dest, mov.src }),
        .movsxd => |mov| w.print(" {f}, {f}", .{ mov.dest, mov.src }),

        .add => |add| w.print(" {f}, {f}", .{ add.lhs, add.rhs }),
        .sub => |sub| w.print(" {f}, {f}", .{ sub.lhs, sub.rhs }),
        .imul => |imul| w.print(" {f}", .{imul.rhs}),
        .idiv => |idiv| w.print(" {f}", .{idiv.rhs}),

        .empty_line_with_comment => |comment| {
            w.print("# {s}", .{as.comments[comment.comment_id.index]});
        },
        .neg => |neg| w.print(" {f}", .{neg.operand}),
        .call => |call| {
            const symbol_text = as.symbol_map.keys()[call.symbol.index];
            w.print(" {s}", .{symbol_text});
        },
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
