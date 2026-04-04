const std = @import("std");
const bmp = @import("bitmap.zig");
const gui = @import("gui.zig");
const util = @import("util.zig");
const png = @import("png.zig");
const Bitmap = bmp.Bitmap;
const FileType = util.FileType;
const FileFormatError = util.FileFormatError;
const print = std.debug.print;

pub fn main() void {
    const allocator = std.heap.page_allocator;
    const file_name = "snail.bmp";

    const file = std.fs.cwd().openFile(file_name, .{}) catch {
        print("Could not open file.\n", .{});
        std.process.exit(1);
    };

    const stat = file.stat() catch {
        print("Could not get file stats.\n", .{});
        std.process.exit(1);
    };

    const data: []u8 = file.readToEndAlloc(allocator, stat.size) catch {
        print("Could not read file\n", .{});
        std.process.exit(1);
    };

    const file_type = util.getFileType(file_name) catch {
        print("Unsupported file type\n", .{});
        std.process.exit(1);
    };

    if (file_type == FileType.png) {
        _ = png.PNG.parse(file_name, data) catch {
            std.process.exit(1);
        };
    }

    if (file_type == FileType.bitmap) {
        const info = Bitmap.parse(file_name, data) catch |err| {
            switch (err) {
                FileFormatError.UnsupportedFormat => print("File is not in a supported format.\n", .{}),
                FileFormatError.InvalidFileHeader => print("The file header is not valid.\n", .{}),
                FileFormatError.InvalidDIBHeader => print("The DIB header is not valid.\n", .{}),
            }
            std.process.exit(2);
        };

        gui.createWindow(allocator, info) catch |err| {
            print("Could not draw to screen. {}\n", .{err});
            std.process.exit(1);
        };
    }

    std.process.exit(0);
}

fn samplePixel(bitmap: Bitmap, x: usize, y: usize) []u8 {
    const yOffset = y * bitmap.bytesPerRow;
    const xOffset = x * bitmap.dibHeader.bitmap_info_header.bpp / 8;
    return bitmap.pixels[(xOffset + yOffset)..(xOffset + yOffset + 3)];
}
