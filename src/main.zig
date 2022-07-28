const std = @import("std");

pub fn ExpiringHashMap(lifetime: usize, limit: usize, comptime K: type, comptime V: type) type {
    const EntryV = struct {
        timestamp: std.time.Instant,
        value: V,
    };

    const InnerHashMap = std.AutoHashMap(K, EntryV);

    return struct {
        inner: InnerHashMap,

        const Self = @This();

        pub fn init(allocator: std.mem.Allocator) Self {
            return Self{ .inner = InnerHashMap.init(allocator) };
        }

        pub fn deinit(self: *Self) void {
            self.inner.deinit();
        }

        pub fn get(self: *Self, key: K) ?V {
            var maybe_value = self.inner.get(key);
            return if (maybe_value) |value| blk: {
                const current_timestamp = std.time.Instant.now() catch @panic("unsupported OS");
                const nanosecs = current_timestamp.since(value.timestamp);
                break :blk if (nanosecs > lifetime)
                    null
                else
                    value.value;
            } else null;
        }

        pub fn put(self: *Self, key: K, value: V) !void {
            const value_entry = EntryV{ .timestamp = try std.time.Instant.now(), .value = value };
            var count = self.inner.count();
            if (count >= limit) {
                // go through all entries and try to maybe invalidate
                var it = self.inner.iterator();
                while (it.next()) |entry| {
                    const current_timestamp = std.time.Instant.now() catch @panic("unsupported OS");
                    const nanosecs = current_timestamp.since(entry.value_ptr.timestamp);
                    if (nanosecs > lifetime) {
                        std.debug.assert(self.inner.remove(entry.key_ptr.*));
                    }
                }

                // check again
                var count_after_deletion = self.inner.count();
                if (count_after_deletion >= limit) return error.OutOfEntries;
            }

            try self.inner.put(key, value_entry);
        }
    };
}

test "expiring hash map" {
    const lifetime = 1 * std.time.ns_per_s;
    const EHM = ExpiringHashMap(lifetime, 100, usize, usize);

    var ehm = EHM.init(std.testing.allocator);
    defer ehm.deinit();

    {
        try std.testing.expectEqual(@as(?usize, null), ehm.get(123));
        try ehm.put(123, 456);
        try std.testing.expectEqual(@as(?usize, 456), ehm.get(123));
        std.time.sleep(lifetime);
        try std.testing.expectEqual(@as(?usize, null), ehm.get(123));
    }
    {
        try ehm.put(124, 457);
        try std.testing.expectEqual(@as(?usize, 457), ehm.get(124));
    }
}

test "expiring hash map with harsher limit" {
    const lifetime = 1 * std.time.ns_per_s;
    const EHM = ExpiringHashMap(lifetime, 1, usize, usize);

    var ehm = EHM.init(std.testing.allocator);
    defer ehm.deinit();

    try ehm.put(123, 456);
    try std.testing.expectError(error.OutOfEntries, ehm.put(124, 457));
}
