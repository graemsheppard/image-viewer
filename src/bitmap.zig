const std = @import("std");
const FileFormatError = @import("image.zig").FileFormatError;
const bytesToUsizeLittle = @import("util.zig").bytesToUsizeLittle;

pub const Bitmap = struct {
    file_name: []const u8,
    pixels: []u8,
    bytes_per_row: u32,
    file_header: BitmapFileHeader,
    dib_header: DIBHeader,

    pub fn parse(file_name: []const u8, data: []u8) FileFormatError!Bitmap {
        if (data.len < 14) return FileFormatError.InvalidFileHeader;
        
        // Handle the headers and their variations
        const file_header = try BitmapFileHeader.parse(data);

        // The u16 size at offset 14 is enough to identify the DIB header format
        const dib_size = bytesToUsizeLittle(data[14..18], u32) catch 0;
        const dib_type = if (std.enums.fromInt(DIBHeaderSize, dib_size )) |val| val else return FileFormatError.InvalidDIBHeader;
        const dib_header: DIBHeader = switch(dib_type ) {
            .bitmap_info_header => .{ .bitmap_info_header = try BitmapInfoHeader.parse(data) },
            .bitmap_core_header => .{ .bitmap_core_header = try BitmapCoreHeader.parse(data) }
        };
        
        // Find the region of data that represents the pixels
        const bpp = dib_header.getBpp();
        const dimensions = dib_header.getDimensions();
        const bits_per_row = bpp * @abs(dimensions.x);
        const height_unsigned = @abs(dimensions.y);
        const bytes_per_row = 4 * ((bits_per_row + 31) / 32);
        const pixel_data_len= bytes_per_row * height_unsigned ;
        
        const result: Bitmap = .{
            .file_name = file_name,
            .file_header = file_header,
            .dib_header = dib_header,
            .bytes_per_row = bytes_per_row,
            .pixels = data[file_header.offset..(file_header.offset + pixel_data_len)]
        };

        return result;
    }

    pub fn deinit(_: Bitmap) void {
        // TODO
    }

    pub fn print(self: Bitmap) void {
        const dimensions = self.dib_header.getDimensions();
        std.debug.print(
            \\FILE HEADER:
            \\  File Size: {}
            \\  Image Start: {}
            \\{s}:
            \\  Width: {}
            \\  Height: {}
            \\  Planes: {}
            \\  Depth: {} 
            \\
            , .{
                self.file_header.file_size,
                self.file_header.offset,
                self.dib_header.getName(),
                dimensions.x,
                dimensions.y,
                self.dib_header.getPlanes(),
                self.dib_header.getBpp()
            }
        );
    }
};

pub const BitmapFileHeader = struct {
    signature: u16,
    file_size: u32,
    offset: u32,

    fn parse(data: []u8) FileFormatError!BitmapFileHeader {
        const signature = bytesToUsizeLittle(data[0..2], u16) catch 0;

        if (signature != 0x4d42) return FileFormatError.UnsupportedFormat;

        const fileSize = bytesToUsizeLittle(data[2..6], u32) catch 0;
        const offset = bytesToUsizeLittle(data[10..14], u32) catch 0;

        const result: BitmapFileHeader = .{
            .offset = offset,
            .file_size = fileSize,
            .signature = signature
        };

        return result;
    }
};

pub const DIBHeader = union(DIBHeaderSize) {
    bitmap_info_header: BitmapInfoHeader,
    bitmap_core_header: BitmapCoreHeader,

    pub fn getName(self: DIBHeader) []const u8 {
        return switch(self) {
            .bitmap_info_header => "BITMAPINFOHEADER",
            .bitmap_core_header => "BITMAPCOREHEADER"
        };
    }

    pub fn getDimensions(self: DIBHeader) struct { x: i32, y: i32 } {
        return switch(self) {
            .bitmap_info_header => |h| .{ .x = h.width, .y = h.height },
            .bitmap_core_header => |h| .{ .x = h.width, .y = h.height }
        };
    }

    pub fn getPlanes(self: DIBHeader) u16 {
        return switch(self) {
            .bitmap_info_header => |h| h.planes,
            .bitmap_core_header => |h| h.planes
        };
    }

    pub fn getBpp(self: DIBHeader) u16 {
        return switch(self) {
            .bitmap_info_header => |h| h.bpp,
            .bitmap_core_header => |h| h.bpp
        };
    }
};

pub const DIBHeaderSize = enum(u32) {
    bitmap_info_header = 40,
    bitmap_core_header = 12
};

const BitmapCoreHeader = struct {
    size: u32,
    width: u16,
    height: u16,
    planes: u16,
    bpp: u16,

    fn parse(data: []u8) FileFormatError!BitmapCoreHeader {
        const width = bytesToUsizeLittle(data[18..20], u16) catch 0;
        const height = bytesToUsizeLittle(data[20..22], u16) catch 0;
        const planes = bytesToUsizeLittle(data[22..24], u16) catch 0;
        const bpp = bytesToUsizeLittle(data[24..26], u16) catch 0;

        return .{
            .size = 40,
            .width = width,
            .height = height,
            .planes = planes,
            .bpp = bpp,
        };
    }
};

const BitmapInfoHeader = struct {
    size: u32,
    width: i32,
    height: i32,
    planes: u16,
    bpp: u16,
    compression: u32,

    fn parse(data: []u8) FileFormatError!BitmapInfoHeader {
        const width = bytesToUsizeLittle(data[18..22], i32) catch 0;
        const height = bytesToUsizeLittle(data[22..26], i32) catch 0;
        const planes = bytesToUsizeLittle(data[26..28], u16) catch 0;
        const bpp = bytesToUsizeLittle(data[28..30], u16) catch 0;
        const compression = bytesToUsizeLittle(data[30..34], u32) catch 0;

        return .{
            .size = 40,
            .width = width,
            .height = height,
            .planes = planes,
            .bpp = bpp,
            .compression = compression
        };
    }
};

