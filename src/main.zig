const std = @import("std");
const bmp = @import("bitmap.zig");
const gui = @import("gui.zig");
const util = @import("util.zig");
const png = @import("png.zig");
const img = @import("image.zig");
const Bitmap = bmp.Bitmap;
const FileType = img.FileType;
const FileFormatError = img.FileFormatError;
const ImageFile = img.ImageFile;
const print = std.debug.print;

pub fn main() void {
    const allocator = std.heap.page_allocator;
    const file_name = "snail.png";

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

    const image = ImageFile.parse(allocator, file_name, data) catch |err| {
        print("A file format error was encountere: {}\n", . { err });
        std.process.exit(@intCast(@intFromError(err)));
    };

    defer image.deinit();

//    gui.createWindow(allocator, image.bitmap) catch |err| {
//        print("Could not draw to screen. {}\n", .{err});
//        std.process.exit(1);
//    };

    std.process.exit(0);
}
