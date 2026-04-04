const util = @import("util.zig");
const FileFormatError = util.FileFormatError;
const bytesToUsizeBig = util.bytesToUsizeBig;

pub const PNG = struct {
    file_name: []const u8,

    pub fn parse(file_name: []const u8, data: []u8) FileFormatError!PNG {
        // Validate file signature
        if (data[0] != 0x89) return FileFormatError.InvalidFileHeader;
        const signature = bytesToUsizeBig(data[1..4], u24) catch 0;
        if (signature != 0x504E47) return FileFormatError.InvalidFileHeader;

        return .{
            .file_name = file_name
        };
    }
};

