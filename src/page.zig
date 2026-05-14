const std = @import("std");
const types = @import("types.zig");

const Allocator = std.mem.Allocator;

const PageId = types.PageId;
const Lsn = types.Lsn;

/// Byte comparable owned slice key
pub const Key = []const u8;

pub const Delta = union(enum) {
    insert: struct { key: Key, value: []const u8, lsn: Lsn },
    update: struct { key: Key, value: []const u8, lsn: Lsn },
    delete: struct { key: Key, lsn: Lsn },

    /// posted to leaf during a split
    split_child: struct { separator: Key, new_sibling: PageId, lsn: Lsn },

    index_entry: struct {
        separator_high: Key,
        separator_low: Key,
        child: PageId,
        lsn: Lsn,
    },
    index_entry_delete: struct {
        separator: Key,
        merged: PageId,
        new_key: Key,
        lsn: Lsn,
    },

    /// posted to the page being removed by the merge
    remove_node: struct { lsn: Lsn },

    /// posted to the left sibling absorving a merge
    merge: struct { right: PageId, separator: Key, lsn: Lsn },

    /// posted by the flush/eviction path when the page was written to disk
    flush: struct { disk_offset: u64, max_flushed_lsn: Lsn },

    pub fn lsn(self: Delta) ?Lsn {
        return switch (self) {
            .insert => |d| d.lsn,
            .update => |d| d.lsn,
            .delete => |d| d.lsn,
            .split_child => |d| d.lsn,
            .index_entry => |d| d.lsn,
            .index_entry_delete => |d| d.lsn,
            .remove_node => |d| d.lsn,
            .merge => |d| d.lsn,
            .flush => null,
        };
    }
};

pub fn keyOrder(a: Key, b: Key) std.math.Order {
    return std.mem.order(u8, a, b);
}

pub fn keyCmp(a: Key, b: Key) bool {
    return std.mem.lessThan(u8, a, b);
}
