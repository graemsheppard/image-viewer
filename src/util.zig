const std = @import("std");

pub fn bytesToUsize(bytes: []const u8, comptime T: type) InvalidCastError!T {
    const info = @typeInfo(T);
    comptime if (info != .int)
        @compileError("Target type must be an integer!\n");
    
    comptime if (@sizeOf(T) > 8)
        @compileError("Size of T is greater than 64!\n");

    if (@sizeOf(T) != bytes.len) {
        return InvalidCastError.SizeMismatch;
    }

    var i: usize = 0;
    var result = @as(T, 0);
    
    while (i < @sizeOf(T)) : (i += 1) {
        var cur = @as(T, bytes[i]);
        var j: usize = 0;
        while (j < i) : (j += 1) {
            cur <<= 8;
        }
        result = result | cur;
    }

    return result;
}

pub const InvalidCastError = error {
    SizeMismatch
};
