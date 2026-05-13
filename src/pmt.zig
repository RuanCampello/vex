const std = @import("std");
const types = @import("types.zig");

/// A flat array of atomic u64 slots, one per page id
/// All mutations go through CAS, no locks anywhere in the file
///
/// Capacity is fixed at init time. PageIds are allocated from a monotonic counter
/// freed ids are recycled through a simple free list
pub const PageMappingTable = struct {
    slots: []std.atomic.Value(types.SlotValue),
    allocator: std.mem.Allocator,
    next: std.atomic.Value(u64),
    free_list: FreeList,
};

const FreeList = struct {
    mutex: std.Thread.Mutex,
    ids: std.ArrayList(types.PageId),

    fn init(allocator: std.mem.Allocator) FreeList {
        return .{ .mutex = .{}, .ids = std.ArrayList(types.PageId).init(allocator) };
    }

    fn deinit(self: *FreeList) void {
        self.ids.deinit();
    }

    fn push(self: *FreeList, id: types.PageId) !void {
        self.mutex.lock();
        defer self.mutex.unlock();

        try self.ids.append(id);
    }

    fn pop(self: *FreeList) ?types.PageId {
        self.mutex.lock();
        defer self.mutex.unlock();

        return self.ids.popOrNull();
    }
};

/// Sentinel for a slot that has never been written
/// Nothing should ever try to decode a null slot
pub const NULL_SLOT: types.SlotValue = 0;
