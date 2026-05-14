const std = @import("std");
const types = @import("types.zig");

const PageId = types.PageId;
const SlotValue = types.SlotValue;

const Allocator = std.mem.Allocator;

/// Sentinel for a slot that has never been written
/// Nothing should ever try to decode a null slot
pub const NULL_SLOT: SlotValue = 0;

/// A flat array of atomic u64 slots, one per page id
/// All mutations go through CAS, no locks anywhere in the file
///
/// Capacity is fixed at init time. PageIds are allocated from a monotonic counter
/// freed ids are recycled through a simple free list
pub const PageMappingTable = struct {
    slots: []std.atomic.Value(SlotValue),
    allocator: Allocator,
    next: std.atomic.Value(u64),
    /// PageIds waiting to be recycled
    /// Caller must only push a PageId here after the epoch taht could have seen it drained
    free_list: FreeList,

    pub fn init(allocator: Allocator, capacity: usize) !PageMappingTable {
        const slots = try allocator.alloc(std.atomic.Value(SlotValue), capacity);
        for (slots) |*slot| slot.store(NULL_SLOT, .monotonic);

        return PageMappingTable{
            .slots = slots,
            .allocator = allocator,
            .next = std.atomic.Value(u64).init(0),
            .free_list = FreeList.init(),
        };
    }

    pub fn deinit(self: *PageMappingTable) void {
        self.free_list.deinit(self.allocator);
        self.allocator.free(self.slots);
    }

    pub fn alloc(self: *PageMappingTable) !PageId {
        if (self.free_list.pop()) |page_id| return page_id;

        const page_id = self.next.fetchAdd(1, .monotonic);
        if (page_id >= self.slots.len) return error.OutOfPageIds;

        return page_id;
    }

    pub fn free(self: *PageMappingTable, id: PageId) !void {
        std.debug.assert(id != types.INVALID_PAGE_ID); // page id must be valid
        self.slots[id].store(NULL_SLOT, .release);

        try self.free_list.push(id);
    }

    pub fn load(self: *const PageMappingTable, id: PageId) SlotValue {
        std.debug.assert(id < self.slots.len); // must have a slot

        return self.slots[id].load(.acquire);
    }

    pub fn store(self: *PageMappingTable, id: PageId, slot: SlotValue) void {
        std.debug.assert(id < self.slots.len); // must have a slot

        return self.slots[id].store(slot, .release);
    }

    /// CAS a slot from `expected` to `desired`
    pub const CasResult = union(enum) {
        ok,
        contention: SlotValue,
    };

    pub fn cas(self: *PageMappingTable, id: PageId, expected: SlotValue, desired: SlotValue) CasResult {
        std.debug.assert(id < self.slots.len); // must have a slot
        const result = self.slots[id].cmpxchgWeak(expected, desired, .acq_rel, .acquire);

        return if (result == null) .ok else .{ .contention = result.? };
    }
};

// TODO: this will be probably replaced by a lock-free queue
const FreeList = struct {
    mutex: std.atomic.Mutex,
    ids: std.ArrayList(PageId),

    fn init() FreeList {
        return .{
            .mutex = .unlocked,
            .ids = .empty,
        };
    }

    fn deinit(self: *FreeList, alloc: Allocator) void {
        self.ids.deinit(alloc);
    }

    fn push(self: *FreeList, alloc: Allocator, id: PageId) !void {
        while (!self.mutex.tryLock()) {}
        defer self.mutex.unlock();

        try self.ids.append(alloc, id);
    }

    fn pop(self: *FreeList) ?PageId {
        while (!self.mutex.tryLock()) {}
        defer self.mutex.unlock();

        return self.ids.pop();
    }
};

test "alloc hands out sequential PageIds" {
    var pmt = try PageMappingTable.init(std.testing.allocator, 16);
    defer pmt.deinit();

    const a = try pmt.alloc();
    const b = try pmt.alloc();
    const c = try pmt.alloc();

    try std.testing.expectEqual(@as(PageId, 0), a);
    try std.testing.expectEqual(@as(PageId, 1), b);
    try std.testing.expectEqual(@as(PageId, 2), c);
}

test "cas succeeds when expected matches" {
    var pmt = try PageMappingTable.init(std.testing.allocator, 16);
    defer pmt.deinit();

    const pid = try pmt.alloc();
    const old = types.encodeDisk(1);
    const new = types.encodeDisk(2);

    pmt.store(pid, old);

    const result = pmt.cas(pid, old, new);

    try std.testing.expectEqual(PageMappingTable.CasResult.ok, result);
    try std.testing.expectEqual(new, pmt.load(pid));
}

test "cas fails when expected does not match" {
    var pmt = try PageMappingTable.init(std.testing.allocator, 16);
    defer pmt.deinit();

    const pid = try pmt.alloc();
    const actual = types.encodeDisk(99);
    const wrong_expected = types.encodeDisk(1);
    const new = types.encodeDisk(2);
    pmt.store(pid, actual);

    const result = pmt.cas(pid, wrong_expected, new);
    switch (result) {
        .ok => return error.ExpectedContention,
        .contention => |seen| try std.testing.expectEqual(actual, seen),
    }

    try std.testing.expectEqual(actual, pmt.load(pid));
}

test "capacity exhaustion returns error" {
    var pmt = try PageMappingTable.init(std.testing.allocator, 2);
    defer pmt.deinit();

    _ = try pmt.alloc();
    _ = try pmt.alloc();
    try std.testing.expectError(error.OutOfPageIds, pmt.alloc());
}

test "concurrent cas: only one writer wins per slot" {
    const thread_count = 8;
    const Ctx = struct {
        pmt: *PageMappingTable,
        pid: PageId,
        wins: std.atomic.Value(u32),

        fn run(ctx: *@This()) void {
            const desired = types.encodeDisk(0xBEEF);
            const result = ctx.pmt.cas(ctx.pid, NULL_SLOT, desired);
            if (result == .ok) {
                _ = ctx.wins.fetchAdd(1, .monotonic);
            }
        }
    };

    var pmt = try PageMappingTable.init(std.testing.allocator, 16);
    defer pmt.deinit();
    const pid = try pmt.alloc();

    var ctx = Ctx{
        .pmt = &pmt,
        .pid = pid,
        .wins = std.atomic.Value(u32).init(0),
    };

    var threads: [thread_count]std.Thread = undefined;
    for (&threads) |*t| t.* = try std.Thread.spawn(.{}, Ctx.run, .{&ctx});
    for (&threads) |*t| t.join();

    try std.testing.expectEqual(@as(u32, 1), ctx.wins.load(.monotonic));
}
