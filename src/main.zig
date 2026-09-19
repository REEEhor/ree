const std = @import("std");
const Io = std.Io;

const gen = @import("gen");

pub fn main(init: std.process.Init) !void {
    const io = init.io;
    const gpa = init.gpa;
    const static_arena = init.arena;

    _ = io;
    _ = gpa;




    // Prints to stderr, unbuffered, ignoring potential errors.
    std.debug.print("All your {s} are belong to us.\n", .{"codebase"});

    // Accessing command line arguments:
    const args: []const [:0]const u8 = try init.minimal.args.toSlice(static_arena.allocator());
    _ = args;

    _ = gen.Lexer.next_token(undefined);
}
