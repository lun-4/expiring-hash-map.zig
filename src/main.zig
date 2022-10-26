const std = @import("std");

pub fn ExpiringHashMap(
    comptime lifetime: usize,
    comptime limit: usize,
    comptime K: type,
    comptime V: type,
) type {
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
        pub fn count(self: *Self) InnerHashMap.Size {
            return self.inner.count();
        }

        const MaybeV = union(enum) {
            expired: V,
            has_value: V,
        };
        const MaybeVPtr = union(enum) {
            expired: *V,
            has_value: *V,
        };

        pub fn get(self: *Self, key: K) ?MaybeV {
            var maybe_value = self.inner.get(key);
            return if (maybe_value) |value| blk: {
                const current_timestamp = std.time.Instant.now() catch @panic("unsupported OS");
                const nanosecs = current_timestamp.since(value.timestamp);
                break :blk if (nanosecs > lifetime) MaybeV{ .expired = value.value } else MaybeV{ .has_value = value.value };
            } else null;
        }

        pub fn getPtr(self: *Self, key: K) ?MaybeVPtr {
            var maybe_value = self.inner.getPtr(key);
            return if (maybe_value) |value| blk: {
                const current_timestamp = std.time.Instant.now() catch @panic("unsupported OS");
                const nanosecs = current_timestamp.since(value.timestamp);
                break :blk if (nanosecs > lifetime) MaybeVPtr{ .expired = &value.value } else MaybeVPtr{ .has_value = &value.value };
            } else null;
        }

        pub fn remove(self: *Self, key: K) bool {
            return self.inner.remove(key);
        }

        pub const RemovedValues = []V;
        const RemovedValueList = std.ArrayList(V);

        pub fn put(self: *Self, key: K, value: V) !RemovedValues {
            const value_entry = EntryV{ .timestamp = try std.time.Instant.now(), .value = value };

            var removed_values = RemovedValueList.init(self.inner.allocator);
            defer removed_values.deinit();

            var current_count = self.inner.count();
            if (current_count >= limit) {
                // go through all entries and try to maybe invalidate
                var it = self.inner.iterator();
                while (it.next()) |entry| {
                    const current_timestamp = std.time.Instant.now() catch @panic("unsupported OS");
                    const nanosecs = current_timestamp.since(entry.value_ptr.timestamp);
                    if (nanosecs > lifetime) {
                        try removed_values.append(entry.value_ptr.*.value);
                        std.debug.assert(self.inner.remove(entry.key_ptr.*));
                    }
                }

                // check again
                var count_after_deletion = self.inner.count();
                if (count_after_deletion >= limit) return error.OutOfEntries;
            }

            try self.inner.put(key, value_entry);
            return removed_values.toOwnedSlice();
        }
    };
}

test "expiring hash map" {
    const lifetime = 1 * std.time.ns_per_s;
    const EHM = ExpiringHashMap(lifetime, 100, usize, usize);

    var ehm = EHM.init(std.testing.allocator);
    defer ehm.deinit();

    {
        try std.testing.expectEqual(@as(?EHM.MaybeV, null), ehm.get(123));
        _ = try ehm.put(123, 456);
        try std.testing.expectEqual(@as(?EHM.MaybeV, EHM.MaybeV{ .has_value = 456 }), ehm.get(123));
        std.time.sleep(lifetime);
        try std.testing.expectEqual(@as(?EHM.MaybeV, EHM.MaybeV{ .expired = 456 }), ehm.get(123));
    }
    {
        _ = try ehm.put(124, 457);
        try std.testing.expectEqual(@as(?EHM.MaybeV, EHM.MaybeV{ .has_value = 457 }), ehm.get(124));
    }
}

test "expiring hash map with harsher limit" {
    const lifetime = 1 * std.time.ns_per_s;
    const EHM = ExpiringHashMap(lifetime, 1, usize, usize);

    var ehm = EHM.init(std.testing.allocator);
    defer ehm.deinit();

    _ = try ehm.put(123, 456);
    try std.testing.expectError(error.OutOfEntries, ehm.put(124, 457));
}
