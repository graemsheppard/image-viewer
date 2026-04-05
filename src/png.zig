const std = @import("std");
const util = @import("util.zig");
const FileFormatError = @import("image.zig").FileFormatError;
const Allocator = std.mem.Allocator;
const bytesToUsizeBig = util.bytesToUsizeBig;

pub const PNG = struct {
    file_name: []const u8,
    allocator: Allocator,
    chunks: []Chunk,

    pub fn parse(allocator: Allocator, file_name: []const u8, data: []u8) FileFormatError!PNG {
        // Validate file signature
        if (data[0] != 0x89) return FileFormatError.InvalidFileHeader;
        const signature = bytesToUsizeBig(data[1..4], u24) catch 0;
        if (signature != 0x504E47) return FileFormatError.InvalidFileHeader;

        var chunks = allocator.alloc(Chunk, data.len / 12) catch {
            return FileFormatError.UnsupportedFormat;
        };

        var idx: usize = 8;
        var chunk_count: usize = 0;
        while (idx < data.len) : (chunk_count += 1) {
            const chunk = Chunk.parse(idx, data);
            if (chunk_count == 0 and !std.mem.eql(u8, chunk.name, "IHDR"))
                return FileFormatError.MalformedChunk;
            chunks[chunk_count] = chunk;
            idx += chunk.length + 12;
            if (std.mem.eql(u8, chunk.name, "IEND"))
                break;
        }

        chunks = allocator.realloc(chunks, chunks.len) catch {
            return FileFormatError.UnsupportedFormat;
        };

        return .{
            .file_name = file_name,
            .allocator = allocator,
            .chunks = chunks
        };
    }

    pub fn deinit(self: PNG) void {
        self.allocator.free(self.chunks);
    }
};

const Chunk = struct {
    length: u32,
    name: []const u8,
    data: []const u8,
    crc: u32,

    pub fn parse(start_idx: usize, data: []const u8) Chunk {
        const length = bytesToUsizeBig(data[start_idx..(start_idx + 4)], u32) catch 0;
        const name = data[(start_idx + 4)..(start_idx + 8)];
        const chunk_data = data[(start_idx + 8)..(start_idx + 8 + length)];
        const crc = bytesToUsizeBig(data[(start_idx + 8 + length)..(start_idx + 12 + length)], u32) catch 0;
        return .{
            .length = length,
            .name = name,
            .data = chunk_data,
            .crc = crc
        };
    }
};
