const std = @import("std");

const gen = @import("gen");

const frontend = gen.frontend;
const sema = gen.sema;
//const irgen = gen.irgen;
//const codegen_module = gen.codegen;

const FmtTerminal = gen.FmtTerminal;

pub fn main(init: std.process.Init) !void {
    const io = init.io;
    const gpa = init.gpa;
    const static_arena = init.arena;

    std.debug.print("===== This is the REE compiler =====\n", .{});

    // Accessing command line arguments:
    const args: []const [:0]const u8 = try init.minimal.args.toSlice(static_arena.allocator());

    if (args.len == 1) {
        std.debug.print("Expected a filepath as an argument.\n", .{});
        return error.filepath_not_provided;
    }

    const filepath = args[1];
    const source_code = try std.Io.Dir.cwd().readFileAlloc(io, filepath, static_arena.allocator(), .unlimited);

    const tokens: []const frontend.Token = try frontend.tokenize(
        .{ .gpa = static_arena.allocator(), .source_code = source_code },
    );

    var stdout_buffer: [512]u8 = undefined;
    var stdout_writer = std.Io.File.stdout().writer(io, &stdout_buffer);
    const stdout: *std.Io.Writer = &stdout_writer.interface;

    const stdout_terminal = setup_terminal: {
        const no_color: bool = false;
        const cli_color_force: bool = false;
        const color_mode = std.Io.Terminal.Mode.detect(io, std.Io.File.stdout(), no_color, cli_color_force) catch .no_color;
        break :setup_terminal std.Io.Terminal{
            .mode = color_mode,
            .writer = stdout,
        };
    };
    _ = &stdout_terminal;

    var stderr_buffer: [512]u8 = undefined;
    var stderr_writer = std.Io.File.stderr().writer(io, &stderr_buffer);
    const stderr: *std.Io.Writer = &stderr_writer.interface;

    const stderr_terminal = setup_terminal: {
        const no_color: bool = false;
        const cli_color_force: bool = false;
        const color_mode = std.Io.Terminal.Mode.detect(io, std.Io.File.stderr(), no_color, cli_color_force) catch .no_color;
        break :setup_terminal std.Io.Terminal{
            .mode = color_mode,
            .writer = stderr,
        };
    };

    var reporter = setup_reporter: {
        break :setup_reporter frontend.Reporter{
            .terminal = stderr_terminal,
            .source_code = source_code,
            .filepath = filepath,
        };
    };
    var parser = frontend.Parser{
        .arena = static_arena.allocator(),
        .next_token_id = .{ .index = 0 },
        .nodes = .empty,
        .reporter = &reporter,
        .tokens = tokens,
    };

    const ast: frontend.Ast = parser.parse() catch |err| switch (err) {
        frontend.Oom.OutOfMemory => @panic("oom"), // lol,  TODO: fix later
        frontend.ParseError.invalid_syntax => return error.invalid_syntax,
    };
    try frontend.print_ast(ast, stderr_terminal, gpa);

    var interning_manager = sema.SymbolManager{
        .gpa = static_arena.allocator(),
    };

    var lexical_context = sema.LexicalContext.init(static_arena.allocator());
    defer lexical_context.deinit_assert_empty();

    var type_checker = sema.TypeChecker{
        .arena = static_arena.allocator(),
        .ast = ast,
        .symbol_manager = &interning_manager,
        .lexical_context = &lexical_context,
        .reporter = &reporter,
    };

    try type_checker.type_check();

    // var symbols_manager = irgen.SymbolManager{
    //     .gpa = static_arena.allocator(),
    //     .mapping = .empty,
    // };
    //
    // var ir_gen = irgen.IrGen{
    //     .ast = ast,
    //     .scope_stack = .init(static_arena.allocator()),
    //     .instructions = .empty,
    //     .ir_vars = .empty,
    //     .types = .empty,
    //     .gpa = static_arena.allocator(),
    //     .reporter = &reporter,
    //     .string_literals = .empty,
    //     .symbols = &symbols_manager,
    // };
    //
    // try ir_gen.compile_ast();
    //
    // const ir = irgen.Ir{
    //     .instructions = ir_gen.instructions,
    //     .types = ir_gen.types.items,
    // };
    //
    // try stderr_terminal.writer.print("\n\n\n=========================\n\n\n", .{});
    //
    // try irgen.print_ir(ir, stderr_terminal);
    //
    // try stderr_terminal.writer.print("\n\n\n=========================\n\n\n", .{});
    // try stderr_terminal.writer.flush();

    // var codegen = codegen_module.CodeGen{
    //     .gpa = static_arena.allocator(),
    //     .instructions = .empty,
    //     .ir = ir,
    //     .ir_var_info = .empty,
    //     .max_ir_var = .{ .index = ir_gen.ir_vars.items.len },
    //     .symbol_map = .empty,
    // };
    //
    // try codegen.generate_assembly();
    // // codegen_module.print_assembly();
    //
    // const assembly = try codegen.get_assembly(ir_gen.string_literals.keys());
    // var w = codegen_module.Writer{
    //     .has_error = false,
    //     .indent = "    ",
    //     .inner = stdout_terminal.writer,
    // };
    // try codegen_module.print_assembly(assembly, &w);
    // try w.inner.print("\n\n{s}", .{@embedFile("ree_stdlib.s")});
    // try w.inner.flush();
}

comptime {
    // Force static analysis
    for (std.meta.declarations(gen)) |decl| {
        _ = &@field(gen, decl.name);
    }
}

test {
    std.testing.refAllDecls(@This());
    _ = frontend;
}
