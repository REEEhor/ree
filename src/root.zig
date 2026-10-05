const std = @import("std");
const assert = std.debug.assert;
pub const FmtTerminal = @import("fmt_terminal.zig").FmtTerminal;

pub const frontend = @import("frontend.zig");
pub const irgen = @import("irgen.zig");

test {
    std.testing.refAllDecls(@This());
}
