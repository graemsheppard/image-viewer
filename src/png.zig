const std = @import("std");
const util = @import("util.zig");
const FileFormatError = @import("image.zig").FileFormatError;
const Allocator = std.mem.Allocator;
const ArrayList = std.ArrayList;
const bytesToUsizeBig = util.bytesToUsizeBig;

pub const PNG = struct {
    file_name: []const u8,
    allocator: Allocator,
    ihdr: IHDR,
    plte: ?PLTE,
    chunks: ArrayList(Chunk),

    pub fn parse(allocator: Allocator, file_name: []const u8, data: []u8) FileFormatError!PNG {
        // Validate 8-byte file signature
        if (data[0] != 0x89) return FileFormatError.InvalidFileHeader;
        const signature = bytesToUsizeBig(data[1..4], u24) catch 0;
        if (signature != 0x504E47) return FileFormatError.InvalidFileHeader;

        var chunks = ArrayList(Chunk).initCapacity(allocator, 3) catch return FileFormatError.InvalidFileHeader;

        // IHDR chunk must come first and have data of 13-bytes
        const ihdr_chunk = Chunk.parse(8, data);

        if (ihdr_chunk.length != 13 or !std.mem.eql(u8, ihdr_chunk.name, "IHDR"))
            return FileFormatError.MalformedChunk;

        const ihdr = try IHDR.parse(ihdr_chunk);
        const plte_required = ihdr.color_type == 3;

        var idx: usize = 33;
        var chunk_count: usize = 0;
        var plte: ?PLTE = null;
        while (idx < data.len) : (chunk_count += 1) {
            const chunk = Chunk.parse(idx, data);
            if (std.mem.eql(u8, chunk.name, "PLTE"))
                plte = .{ .data = chunk.data };
            std.debug.print("{s}: {}\n", .{ chunk.name, chunk.length });
            chunks.insert(allocator, chunk_count, chunk) catch return FileFormatError.MalformedChunk;
            idx += chunk.length + 12;
            if (std.mem.eql(u8, chunk.name, "IEND"))
                break;
        }

        if (plte_required and plte == null)
            return FileFormatError.MissingField;

        std.debug.print("{x}\n", .{ plte.?.data });
        return .{
            .file_name = file_name,
            .allocator = allocator,
            .ihdr = ihdr,
            .plte = plte,
            .chunks = chunks
        };
    }

    pub fn deinit(self: PNG) void {
        self.chunks.deinit();
    }

};

pub const IHDR = struct {
    width: u32,
    height: u32,
    bit_depth: u8,
    color_type: u8,
    compression_method: u8,
    filter_method: u8,
    interlace_method: u8,


    fn parse(chunk: Chunk) FileFormatError!IHDR {
        const width = bytesToUsizeBig(chunk.data[0..4], u32) catch return FileFormatError.MalformedChunk;
        const height = bytesToUsizeBig(chunk.data[4..8], u32) catch return FileFormatError.MalformedChunk;

        const bit_depth = chunk.data[8];
        const color_type = chunk.data[9];

        if (!isColorSpecValid(bit_depth, color_type))
            return FileFormatError.MalformedChunk;

        return .{
            .width = width,
            .height = height,
            .bit_depth = chunk.data[8],
            .color_type = chunk.data[9],
            .compression_method = chunk.data[10],
            .filter_method = chunk.data[11],
            .interlace_method = chunk.data[12]
        };
    }

    fn isColorSpecValid(bit_depth: u8, color_type: u8) bool {
        return switch (color_type) {
            0 => switch(bit_depth) { 1, 2, 4, 8, 16 => true, else => false },
            3 => switch(bit_depth) { 1, 2, 4, 8 => true, else => false },
            2, 4, 6 => switch(bit_depth) { 8, 16 => true, else => false },
            else => false
        };
    }
};

pub const PLTE = struct {
    data: []const u8
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
