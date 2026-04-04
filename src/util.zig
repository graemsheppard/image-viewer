const std = @import("std");
const png = @import("png.zig");
const bmp = @import("bitmap.zig");

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

pub fn getFileType(file_name: []const u8) FileFormatError!FileType {
    var idx: ?usize = null;
    const bmp_type = ".bmp";
    const png_type = ".png";
    idx = std.mem.lastIndexOf(u8, file_name, bmp_type);
    if (idx != null)
        return .bitmap;
    idx = std.mem.lastIndexOf(u8, file_name, png_type);
    if (idx != null)
        return .png;
    return FileFormatError.UnsupportedFormat;
}

pub const InvalidCastError = error {
    SizeMismatch
};

pub const FileFormatError = error {
    InvalidFileHeader,
    InvalidDIBHeader,
    UnsupportedFormat
};

pub const Endianness = enum {
    little,
    big
};

pub const ImageFile = union(FileType) {
    png: png.PNG,
    bitmap: bmp.Bitmap,

    pub fn getFileType(self: ImageFile) FileType {
        return switch(self) {
            .png => FileType.png,
            .bitmap => FileType.bitmap
        };
    }
};

pub const FileType = enum {
    bitmap,
    png
};
