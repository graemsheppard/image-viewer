const std = @import("std");
const png = @import("png.zig");
const bmp = @import("bitmap.zig");
const PNG = png.PNG;
const Bitmap = bmp.Bitmap;
const Allocator = std.mem.Allocator;

pub const ImageFile = union(FileType) {
    bitmap: Bitmap,
    png: PNG,

    pub fn getFileName(self: ImageFile) []const u8 {
        return switch (self) {
            .bitmap => |b| b.file_name,
            .png => |p| p.file_name
        };
    }

    pub fn getFileType(self: ImageFile) FileType {
        return switch(self) {
            .png => FileType.png,
            .bitmap => FileType.bitmap
        };
    }

    pub fn getDimensions(self: ImageFile) struct { x: i32, y: i32 } {
        return switch(self) {
            .bitmap => |b| {
                const dimensions = b.dib_header.getDimensions();
                return .{ .x = dimensions.x, .y = dimensions.y };
            },
            .png => |p| .{ .x = @intCast(p.ihdr.width), .y = @intCast(p.ihdr.height) }
        };
    }

    pub fn getPixels(self: ImageFile) []u8 {
        return switch(self) {
            .bitmap => |b| b.pixels,
            .png => |p| p.pixels
        };
    }

    pub fn parse(allocator: Allocator, file_name: []const u8, data: []u8) FileFormatError!ImageFile {
        const file_type = try parseFileType(file_name);
        return switch (file_type) {
            .bitmap => .{ .bitmap = try Bitmap.parse(file_name, data) },
            .png => .{ .png = try PNG.parse(allocator, file_name, data) }
        };
    }

    pub fn deinit(self: ImageFile) void {
        switch (self) {
            .png => |p| p.deinit(),
            .bitmap => |b| b.deinit()
        }
    }

    fn parseFileType(file_name: []const u8) FileFormatError!FileType {
        var idx: ?usize = null;
        const bmp_type = ".bmp";
        const png_type = ".png";
        idx = std.mem.lastIndexOf(u8, file_name, bmp_type);
        if (idx != null and idx.? == file_name.len - 4)
            return .bitmap;
        idx = std.mem.lastIndexOf(u8, file_name, png_type);
        if (idx != null and idx.? == file_name.len - 4)
            return .png;
        return FileFormatError.UnsupportedFormat;
    }
};

pub const FileType = enum {
    bitmap,
    png
};


pub const FileFormatError = error {
    InvalidFileHeader,
    InvalidDIBHeader,
    UnsupportedFormat,
    UnsupportedCompressionMethod,
    MalformedChunk,
    MissingField,
    CorruptedData,
    InvalidHuffmanCode
};
