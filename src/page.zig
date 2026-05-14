const std = @import("std");
const types = @import("types.zig");

const Allocator = std.mem.Allocator;

const PageId = types.PageId;
const Lsn = types.Lsn;

/// Byte comparable owned slice key
pub const Key = []const u8;

pub const Delta = struct {
    content: Node,
    next: ?*Delta,

    pub fn newDelta(alloc: Allocator, kind: DeltaKind) !*Delta {
        const node = try alloc.create(Delta);
        node.* = .{ .content = .{ .kind = kind }, .next = null };

        return node;
    }

    pub fn newPage(alloc: Allocator, page: Page) !*Delta {
        const node = try alloc.create(Delta);
        node.* = .{ .content = .{ .page = page }, .next = null };

        return node;
    }

    pub fn getPage(self: *Delta) *Page {
        return &self.getNode().content.page;
    }

    pub fn getNode(self: *Delta) *Delta {
        var curr: *Delta = self;
        while (curr.next) |nxt| curr = nxt;
        std.debug.assert(curr.content == .page); // chain must terminate in a page

        return curr;
    }

    pub fn len(self: *const Delta) usize {
        var length: usize = 0;
        var curr: ?*const Delta = self;

        while (curr) |node| : (curr = node.next) length += 1;
        return length;
    }
};

/// Consolidated and sorted snapshot of a page's state
///
/// *Key invariants*:
///   - entries are sorted by key in ascending order, no duplicate keys
///   - every key k satisfies: low_key <= k < high_key  (B-link semantics)
///   - all entries are the same variant (record or child_pid) matching `kind`
pub const Page = struct {
    kind: PageKind,
    /// null = negative infinity (leftmost page at this level)
    low_key: ?Key,
    /// null = positive infinity (rightmost page at this level)
    high_key: ?Key,
    /// B-link pointer; null only on the rightmost page at a level
    right_sibling: ?PageId,
    entries: std.ArrayList(Entry),
    /// Highest LSN among all entries on this page after consolidation
    max_lsn: Lsn,

    pub const Entry = struct { key: Key, value: PageEntry };

    pub fn init(kind: PageKind, low_key: ?Key, high_key: ?Key, right_sibling: ?PageId) Page {
        return .{
            .kind = kind,
            .low_key = low_key,
            .high_key = high_key,
            .right_sibling = right_sibling,
            .entries = .empty,
            .max_lsn = 0,
        };
    }

    pub fn deinit(self: *Page, alloc: Allocator) void {
        if (self.low_key) |k| alloc.free(k);
        if (self.high_key) |k| alloc.free(k);
        for (self.entries.items) |*e| {
            alloc.free(e.key);
            switch (e.value) {
                .record => |v| alloc.free(v),
                .child => {},
            }
        }

        self.entries.deinit(alloc);
    }

    pub fn find(self: *Page, key: Key) struct { found: bool, index: usize } {
        var lo: usize = 0;
        var hi: usize = self.entries.items.len;

        while (lo < hi) {
            const mid = lo + (hi - lo) / 2;
            switch (std.mem.order(u8, self.entries.items[mid].key, key)) {
                .lt => lo = mid + 1,
                .gt => hi = mid,
                .eq => return .{ .found = true, .index = mid },
            }
        }

        return .{ .found = false, .index = lo };
    }

    pub fn get(self: *Page, key: Key) ?PageEntry {
        const result = self.find(key);
        if (!result.found) return null;

        return self.entries.items[result.index].value;
    }

    // panics if any invariant is broken
    pub fn validate(self: *const Page) void {
        for (self.entries.items, 0..) |*entry, idx| {
            if (idx > 0) {
                std.debug.assert(
                    std.mem.lessThan(u8, self.entries.items[idx - 1].key, entry.key),
                ); // entries must be strictly sorted, no duplicates
            }

            if (self.low_key) |lk| {
                std.debug.assert(
                    !std.mem.lessThan(u8, entry.key, lk),
                ); // key must be >= low_key
            }

            if (self.high_key) |hk| {
                std.debug.assert(
                    std.mem.lessThan(u8, entry.key, hk),
                ); // key must be < high_key (B-link: high_key belongs to right sibling)
            }
            switch (self.kind) {
                .leaf => std.debug.assert(entry.value == .record), // leaf entries must be records
                .nested => std.debug.assert(entry.value == .child), // nested entries must be child
            }
        }
    }
};

pub const PageKind = enum { leaf, nested };

/// entry value stored in a page slot
pub const PageEntry = union(enum) {
    record: []const u8,
    child: PageId,
};

/// A single node in page's delta chain
/// `next` is non-null for every node except the sentinal that wraps the
/// base page
pub const Node = union(enum) {
    kind: DeltaKind,
    page: Page,
};

pub const DeltaKind = union(enum) {
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

    pub fn lsn(self: DeltaKind) ?Lsn {
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

pub fn freeChain(alloc: Allocator, head: *Delta) void {
    var curr: ?*Delta = head;

    while (curr) |node| {
        const nxt = node.next;
        switch (node.content) {
            .kind => |*d| freeDeltaKindKeys(alloc, d),
            .page => |*b| b.deinit(alloc),
        }

        alloc.destroy(node);
        curr = nxt;
    }
}

pub fn freeDeltaKindKeys(alloc: Allocator, d: *const DeltaKind) void {
    switch (d.*) {
        .insert => |v| {
            alloc.free(v.key);
            alloc.free(v.value);
        },
        .update => |v| {
            alloc.free(v.key);
            alloc.free(v.value);
        },
        .delete => |v| alloc.free(v.key),
        .split_child => |v| alloc.free(v.separator),
        .index_entry => |v| {
            alloc.free(v.separator_low);
            alloc.free(v.separator_high);
        },
        .index_entry_delete => |v| {
            alloc.free(v.separator);
            alloc.free(v.new_key);
        },
        .remove_node => {},
        .merge => |v| alloc.free(v.separator),
        .flush => {},
    }
}

fn dupeKey(alloc: Allocator, k: []const u8) !Key {
    return alloc.dupe(u8, k);
}

fn dupeVal(alloc: Allocator, v: []const u8) ![]const u8 {
    return alloc.dupe(u8, v);
}

test "Delta: single base page chain" {
    const alloc = std.testing.allocator;

    const base = Page.init(.leaf, null, null, null);
    const head = try Delta.newPage(alloc, base);
    defer freeChain(alloc, head);

    try std.testing.expectEqual(@as(usize, 1), head.len());
    try std.testing.expect(head.content == .page);
    try std.testing.expectEqual(head, head.getNode());
}

test "Delta: prepend deltas and walk chain" {
    const alloc = std.testing.allocator;

    const base = Page.init(.leaf, null, null, null);
    const terminal = try Delta.newPage(alloc, base);

    const d1 = try Delta.newDelta(alloc, .{
        .insert = .{
            .key = try dupeKey(alloc, "apple"),
            .value = try dupeVal(alloc, "1"),
            .lsn = 1,
        },
    });
    d1.next = terminal;

    const d2 = try Delta.newDelta(alloc, .{
        .insert = .{
            .key = try dupeKey(alloc, "banana"),
            .value = try dupeVal(alloc, "2"),
            .lsn = 2,
        },
    });
    d2.next = d1;

    defer freeChain(alloc, d2);

    try std.testing.expectEqual(@as(usize, 3), d2.len());
    try std.testing.expectEqual(terminal, d2.getNode());
    try std.testing.expect(d2.content == .kind);
}

test "Delta: lsn accessor covers all delta variants" {
    const alloc = std.testing.allocator;

    const cases = [_]DeltaKind{
        .{ .insert = .{ .key = "k", .value = "v", .lsn = 10 } },
        .{ .update = .{ .key = "k", .value = "v", .lsn = 20 } },
        .{ .delete = .{ .key = "k", .lsn = 30 } },
        .{ .remove_node = .{ .lsn = 40 } },
        .{ .flush = .{ .disk_offset = 0, .max_flushed_lsn = 0 } },
    };

    const expected_lsns = [_]?Lsn{ 10, 20, 30, 40, null };

    for (cases, expected_lsns) |c, exp| {
        const node = try Delta.newDelta(alloc, c);
        alloc.destroy(node); // keys are not owned here (stack literals) so just destroy
        try std.testing.expectEqual(exp, c.lsn());
    }
}

test "Page: get returns correct entry" {
    const alloc = std.testing.allocator;

    var base = Page.init(.leaf, null, null, null);
    defer base.deinit(alloc);

    try base.entries.append(alloc, .{
        .key = try dupeKey(alloc, "cat"),
        .value = .{ .record = try dupeVal(alloc, "meow") },
    });
    try base.entries.append(alloc, .{
        .key = try dupeKey(alloc, "dog"),
        .value = .{ .record = try dupeVal(alloc, "woof") },
    });

    const found = base.get("dog");
    try std.testing.expect(found != null);
    try std.testing.expectEqualSlices(u8, "woof", found.?.record);

    try std.testing.expect(base.get("fish") == null);
}

test "Page: find insertion point" {
    const alloc = std.testing.allocator;

    var base = Page.init(.leaf, null, null, null);
    defer base.deinit(alloc);

    try base.entries.append(alloc, .{
        .key = try dupeKey(alloc, "a"),
        .value = .{ .record = try dupeVal(alloc, "1") },
    });
    try base.entries.append(alloc, .{
        .key = try dupeKey(alloc, "c"),
        .value = .{ .record = try dupeVal(alloc, "3") },
    });

    const r = base.find("b");
    try std.testing.expect(!r.found);
    try std.testing.expectEqual(@as(usize, 1), r.index); // 'b' slots in between a and c
}

test "Page: validate passes on well-formed leaf page" {
    const alloc = std.testing.allocator;

    var base = Page.init(.leaf, null, null, null);
    defer base.deinit(alloc);

    try base.entries.append(alloc, .{
        .key = try dupeKey(alloc, "apple"),
        .value = .{ .record = try dupeVal(alloc, "v1") },
    });
    try base.entries.append(alloc, .{
        .key = try dupeKey(alloc, "mango"),
        .value = .{ .record = try dupeVal(alloc, "v2") },
    });
    try base.entries.append(alloc, .{
        .key = try dupeKey(alloc, "zebra"),
        .value = .{ .record = try dupeVal(alloc, "v3") },
    });

    base.validate(); // must not panic
}
