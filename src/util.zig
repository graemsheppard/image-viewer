const std = @import("std");

pub fn bytesToUsizeLittle(bytes: []const u8, comptime T: type) InvalidCastError!T {
    return bytesToUsize(bytes, T, .little);
}

pub fn bytesToUsizeBig(bytes: []const u8, comptime T: type) InvalidCastError!T {
    return bytesToUsize(bytes, T, .big);
}

pub fn bytesToUsize(bytes: []const u8, comptime T: type, comptime endianness: Endianness) InvalidCastError!T {
    const info = @typeInfo(T);
    comptime if (info != .int)
        @compileError("Target type must be an integer!\n");
    
    comptime if (@sizeOf(T) > 8)
        @compileError("Size of T is greater than 64!\n");

    comptime if (@bitSizeOf(T) % 8 != 0)
        @compileError("T must have a size representable in bytes!\n");

    const size: usize = comptime @bitSizeOf(T) / 8;
    if (size != bytes.len) {
        return InvalidCastError.SizeMismatch;
    }

    var i: usize = 0;
    var result = @as(T, 0);
    
    while (i < size) : (i += 1) {
        const idx = if (endianness == .little) i else bytes.len - (i + 1);
        var cur = @as(T, bytes[idx]);
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

pub const Endianness = enum {
    little,
    big
};

