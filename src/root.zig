const std = @import("std");
const assert = std.debug.assert;
pub const FmtTerminal = @import("fmt_terminal.zig").FmtTerminal;

pub const frontend = @import("frontend.zig");
pub const sema = @import("sema.zig");
// pub const irgen = @import("irgen.zig");
//pub const codegen = @import("codegen.zig");

test {
    std.testing.refAllDecls(@This());
}
