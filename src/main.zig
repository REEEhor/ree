const std = @import("std");
const Io = std.Io;

const gen = @import("gen");

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

    const tokens: []const gen.Token = try gen.tokenize(
        .{ .gpa = static_arena.allocator(), .source_code = source_code },
    );

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
        break :setup_reporter gen.Reporter{
            .terminal = stderr_terminal,
            .source_code = source_code,
            .filepath = filepath,
        };
    };
    var parser = gen.Parser{
        .gpa = static_arena.allocator(),
        .next_token_id = .{ .index = 0 },
        .nodes = .empty,
        .reporter = &reporter,
        .tokens = tokens,
    };

    const ast: gen.Ast = parser.parse() catch |err| switch (err) {
        gen.Oom.OutOfMemory => unreachable, // lol,  TODO: fix later
        gen.ParseError.invalid_syntax => return error.invalid_syntax,
    };
    try gen.print_ast(ast, stderr_terminal, gpa);
}

comptime {
    // Force static analysis
    for (std.meta.declarations(gen)) |decl| {
        _ = &@field(gen, decl.name);
    }
}

test {
    std.testing.refAllDecls(@This());
}
