pub fn Maybe(comptime T: type) type {
    return struct {
        ptr_maybe: ?*const T,

        pub fn take(result: *@This()) ?T {
            const ptr = result.ptr_maybe orelse return null;
            result.ptr_maybe = null;
            return ptr.*;
        }
    };
}
