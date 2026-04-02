const std = @import("std");
const bmp = @import("bitmap.zig");
const gui = @import("gui.zig");
const FileFormatError = bmp.FileFormatError;
const Bitmap = bmp.Bitmap;
const bytesToUsize = @import("util.zig").bytesToUsize;
const print = std.debug.print;

pub fn main() void {
    const allocator = std.heap.page_allocator;

    const file = std.fs.cwd().openFile("red.bmp", .{}) catch {
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

    const info = Bitmap.parse(data) catch |err| {
        switch (err) {
            FileFormatError.UnsupportedFormat => print("File is not in a supported format.\n", .{}),
            FileFormatError.InvalidFileHeader => print("The file header is not valid.\n", .{}),
            FileFormatError.InvalidDIBHeader => print("The DIB header is not valid.\n", .{}),
        }
        std.process.exit(2);
    };

    info.print();

    gui.testWindow(info) catch {
        print("Could not open file.\n", .{});
        std.process.exit(1);
    };

    std.process.exit(0);
    const newFile = std.fs.cwd().createFile("newSnail.bmp", .{}) catch {
        print("Could not create file.\n", .{});
        std.process.exit(1);
    };

    var buf: [4096]u8 = undefined;
    var writer = newFile.writer(&buf);
    writer.interface.writeAll(data) catch {};
    writer.end() catch {};
    std.process.exit(0);
}

fn samplePixel(bitmap: Bitmap, x: usize, y: usize) []u8 {
    const yOffset = y * bitmap.bytesPerRow;
    const xOffset = x * bitmap.dibHeader.bitmap_info_header.bpp / 8;
    return bitmap.pixels[(xOffset + yOffset)..(xOffset + yOffset + 3)];
}
