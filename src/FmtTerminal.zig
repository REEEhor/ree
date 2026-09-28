const std = @import("std");
const FmtTerminal = @This();

writer: *std.Io.Writer,
mode: std.Io.Terminal.Mode,

pub fn from_std_terminal(std_terminal: std.Io.Terminal) FmtTerminal {
    return .{ .mode = std_terminal.mode, .writer = std_terminal.writer };
}
pub fn as_std_terminal(self: FmtTerminal) std.Io.Terminal {
    return .{ .mode = self.mode, .writer = self.writer };
}
pub fn set_color(t: FmtTerminal, color: std.Io.Terminal.Color) !void {
    try t.as_std_terminal().setColor(color);
}

/// Usage:
/// ```zig
///     const num: i32 = 3;
///     try t.print("Hello, this message has {BOLD}{RED}c{GREEN}o{BLUE}l{YELLOW}o{MAGENTA}r{CYAN}s{RESET} :D\n", .{});
///     try t.print("Number: {GREEN}{d:02}{RESET}\n", .{num});
///
///     const color_blue = std.Io.Terminal.Color.blue;
///     try t.print("Number: {%}{d}{RESET}\n", .{color_blue, num});
///```
/// When using a color literal, such as `{RED}`, its lower-case version must be a case of `std.Io.Terminal.Color`.
pub fn print(t: FmtTerminal, comptime fmt: []const u8, args: anytype) !void {
    @setEvalBranchQuota(100000);
    const Color = std.Io.Terminal.Color;

    comptime var idx = 0;
    comptime var current_fmt_start = 0;
    comptime var args_start = 0;
    comptime var args_end = 0;
    main_loop: inline while (true) {
        comptime while (idx < fmt.len and fmt[idx] != '{') {
            idx += 1;
        };
        idx += 1;
        if (comptime idx >= fmt.len) break :main_loop;
        comptime if (fmt[idx] == '{') {
            // Double braces `{{` are left alone - they represent a single escaped brace.
            idx += 1;
            continue :main_loop;
        };

        const color_start = comptime idx;
        comptime while (idx < fmt.len and fmt[idx] != '}') {
            idx += 1;
        };
        if (comptime idx >= fmt.len) break :main_loop;

        const color_text = fmt[color_start..idx];
        idx += 1;

        inline for (color_text) |c| if (comptime std.ascii.isLower(c)) {
            // This was just a regular argument to `writer.print`
            args_end += 1;
            continue :main_loop;
        };

        comptime var next_args_start = args_end;
        const color: Color = color: {
            if (comptime std.mem.eql(u8, color_text, "%")) {
                const color = args[args_end];
                next_args_start = args_end + 1;
                break :color color;
            }

            comptime var color_str: [color_text.len]u8 = undefined;
            const res = comptime std.ascii.lowerString(&color_str, color_text);
            comptime std.debug.assert(res.len == color_str.len);
            break :color (comptime std.meta.stringToEnum(Color, res)) orelse {
                // Could not parse the color => treat this as just a regular argument to `writer.print`
                args_end += 1;
                continue :main_loop;
            };
        };

        //@compileLog(std.fmt.comptimePrint("printing: >{s}< with args: {}", .{
        //    fmt[current_fmt_start..(color_start - 1)],
        //    TupleSlice(@TypeOf(args), args_start, args_end),
        //}));

        // Print the fmt up to the color
        try t.writer.print(fmt[current_fmt_start..(color_start - 1)], tuple_slice(args, args_start, args_end));
        current_fmt_start = idx;
        args_start = next_args_start;
        args_end = next_args_start;

        // Print the color
        try t.set_color(color);
    }

    // Print the rest of the original message
    args_end = @typeInfo(@TypeOf(args)).@"struct".fields.len;
    //@compileLog(std.fmt.comptimePrint("FINISHING printing: >{s}< with args: {}", .{
    //    fmt[current_fmt_start..],
    //    TupleSlice(@TypeOf(args), args_start, args_end),
    //}));
    try t.writer.print(fmt[current_fmt_start..], tuple_slice(args, args_start, args_end));
}

pub fn TupleSlice(comptime Tuple: type, comptime start_idx: comptime_int, comptime end_idx: comptime_int) type {
    comptime {
        std.debug.assert(@typeInfo(Tuple).@"struct".is_tuple);

        const len = end_idx - start_idx;
        std.debug.assert(len >= 0);
        var types: [len]type = undefined;

        for (start_idx..end_idx) |source_idx| {
            const dest_idx = source_idx - start_idx;
            types[dest_idx] = @typeInfo(Tuple).@"struct".fields[source_idx].type;
        }

        return @Tuple(&types);
    }
}
pub fn tuple_slice(tuple: anytype, comptime start_idx: comptime_int, comptime end_idx: comptime_int) TupleSlice(@TypeOf(tuple), start_idx, end_idx) {
    const Tuple = @TypeOf(tuple);
    const Slice = TupleSlice(Tuple, start_idx, end_idx);

    var slice: Slice = undefined;

    inline for (start_idx..end_idx) |source_idx| {
        const dest_idx = source_idx - start_idx;
        slice[dest_idx] = tuple[source_idx];
    }

    return slice;
}
