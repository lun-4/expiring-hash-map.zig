# expiring-hash-map.zig

need a cache or you're limited by memory in your long-lived zig code, well fear no more!

this doesn't implement all of the HashMap API, but it is good enough
for my usecases (https://github.com/lun-4/awtfdb).

## basically, it goes like this

```zig
// This hash map will hold at most 100 items, and if any of the items
// life for longer than a second, they will be removed

// to do so, get() and put() return more than just the value type, so that
// the caller can determine when to free the given memory (if the value
// has pointers that are heap allocated).
const EHM = ExpiringHashMap(1 * std.time.ns_per_s, 100, usize, usize);

var ehm = EHM.init(std.testing.allocator);
defer ehm.deinit();

// returns null
ehm.get(123);

// since we didn't have anything in the map, ignore the list of things to remove
_ = try ehm.put(123, 456);

// returns a wrapper type (?MaybeV) containing 456 as a non-expired value
var maybe_value = ehm.get(123);
maybe_value.has_value; // assert that there's a value

// sneaky sleep
std.time.sleep(1 * std.time.ns_per_s);

// now the value is expired.
var maybe_value = ehm.get(123);
maybe_value.has_value; // will error
maybe_value.expired; // returns the value, 456

// now, if i add a value, wait, and add another, the first one should be expired
_ = try ehm.put(123, 456);
std.time.sleep(1 * std.time.ns_per_s);
var to_remove = try ehm.put(127, 457);
for (to_remove) |value| do_something_to_free_this(value);
```
