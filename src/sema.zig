const std = @import("std");

const root_module = @import("root.zig");
const frontend = root_module.frontend;

const Ast = frontend.Ast;
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
    @"struct": Struct,

    pub fn tag(info: TypeInfo) Tag {
        return std.meta.activeTag(info);
    }
    pub const Tag = std.meta.Tag(@This());
    pub const Pointer = packed struct {
        child: TypeId,
    };
    pub const Struct = struct {
        // name: ?Symbol,
        members: []const Member,
        pub const Member = struct {
            name: Symbol,
            type: TypeId,
        };
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

pub const TypeChecker = struct {
    gpa: std.mem.Allocator,

    ast: Ast,
    symbol_manager: *SymbolManager,

    /// Represents the mapping 'TypeId.index' -> 'TypeInfo'
    type_info_by_id: std.ArrayList(TypeInfo),
    type_id_lookup: std.array_hash_map.Auto(u64, void),

    //pub fn type_id_for(self: *TypeChecker, info: TypeInfo) TypeId {}
};
