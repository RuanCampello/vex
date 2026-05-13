const std = @import("std");

pub const PageId = u64;
pub const Lsn = u64;

/// A mapping-table value
/// encodes either a live in heap pointer or a disk offset
///
/// Layout (64 bits):
///   bit 63 = 0  ->  memory pointer  (bits 62..0 = address)
///   bit 63 = 1  ->  disk offset     (bits 62..0 = byte offset in LSS)
pub const SlotValue = u64;

pub const PhysicalLocation = enum { memory, disk };

pub const INVALID_PAGE_ID = std.math.maxInt(PageId);
pub const DISK_FLAG: u64 = 1 << 63;

/// Encodes a heap pointer into a slot value
pub fn encodeMemory(ptr: *anyopaque) SlotValue {
    const addr = @intFromPtr(ptr);
    std.debug.assert(addr & DISK_FLAG == 0); // addr cannot touch 63 bit

    return addr;
}

/// Encodes a disk offset into a slot value
pub fn encodeDisk(offset: u64) SlotValue {
    std.debug.assert(offset & DISK_FLAG == 0); // offset cannot touch 63 bit
    return offset | DISK_FLAG;
}

/// Decodes a slot value known to be a memory pointer
/// Crashes if the slot actually encodes a disk offset
pub fn decodeMemory(slot: SlotValue) *anyopaque {
    std.debug.assert(slot & DISK_FLAG == 0); // must be a memory slot
    return @ptrFromInt(slot);
}

/// Decodes a slot value known to be a disk offset
/// Crashes if the slot actually encodes a memory pointer
pub fn decodeDisk(slot: SlotValue) u64 {
    std.debug.assert(slot & DISK_FLAG != 0); // must be a disk slot
    return slot & ~DISK_FLAG;
}

pub fn slotLocation(slot: SlotValue) PhysicalLocation {
    return if (slot & DISK_FLAG != 0) .disk else .memory;
}

test "encode/decode from memory" {
    var x: u8 = 0;
    const ptr: *anyopaque = &x;
    const slot = encodeMemory(ptr);

    try std.testing.expectEqual(PhysicalLocation.memory, slotLocation(slot));
    try std.testing.expectEqual(ptr, decodeMemory(slot));
}

test "encode/decode from disk" {
    const offset = 0x0000_DEAD_BEEF_0000;
    const slot = encodeDisk(offset);

    try std.testing.expectEqual(PhysicalLocation.disk, slotLocation(slot));
    try std.testing.expectEqual(offset, decodeDisk(slot));
}

test "memory and disk slots are distinguishable" {
    var x: u8 = 0;
    const mem_slot = encodeMemory(&x);
    const disk_slot = encodeDisk(0x1234);

    try std.testing.expect(slotLocation(mem_slot) == .memory);
    try std.testing.expect(slotLocation(disk_slot) == .disk);
    try std.testing.expect(mem_slot != disk_slot);
}
