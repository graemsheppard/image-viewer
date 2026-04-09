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
        var reached_end = false;
        var data_chunks: usize = 0;
        while (idx < data.len) : (chunk_count += 1) {
            const chunk = Chunk.parse(idx, data);
            if (std.mem.eql(u8, chunk.name, "PLTE"))
                plte = try PLTE.parse(chunk);
            chunks.insert(allocator, chunk_count, chunk) catch return FileFormatError.MalformedChunk;

            // Each chunk requires at least 12 bytes for headers and CRC
            idx += chunk.length + 12;

            if (std.mem.eql(u8, chunk.name, "IDAT")) {
                data_chunks += 1;
            } else if (std.mem.eql(u8, chunk.name, "IEND")) {
                reached_end = true;
                break;
            }
        }

        if (!reached_end)
            return FileFormatError.MissingField;

        if (plte_required and plte == null)
            return FileFormatError.MissingField;

        // Iterate over the IDAT chunks now that the number is known and parse them
        var idat_chunks = allocator.alloc(IDAT, data_chunks) catch return FileFormatError.MalformedChunk;
        defer allocator.free(idat_chunks);

        var idat_idx: usize = 0;
        var chunk_idx: usize = 0;
        while (chunk_idx < chunks.items.len) : (chunk_idx += 1) {
            const chunk = chunks.items[chunk_idx];
            if (!std.mem.eql(u8, chunk.name, "IDAT")) continue;
            idat_chunks[idat_idx] = IDAT.parse(chunk, data_chunks, idat_idx);
            idat_chunks[idat_idx].print();
            idat_idx += 1;
        }

        std.debug.print("IDAT Chunks: {}\nData: {x}\n", .{ idat_chunks.len, idat_chunks[0].data[0..8] });
        var stream = IDATStream.init(allocator, idat_chunks) catch return FileFormatError.MalformedChunk;
        defer stream.deinit();

        var bits_read: u5 = 0;
        var block_header = stream.readBits(3, &bits_read);
        
        // Each block starts with 3-bit header
        while (bits_read > 0) : (block_header = stream.readBits(3, &bits_read)) {
            const bfinal = block_header & 0x1;

            const btype_val = @as(u2, @intCast((block_header >> 1) & 0b11));
            const btype: BTYPE = @enumFromInt(btype_val);

            if (btype == .no_compression) {
                stream.seekByte();
                _ = stream.readBits(16, null);
                
            } else if (btype == .compressed_fixed) {

            } else if (btype == .compressed_dynamic) {
                const symbol_tbl = [_]u8 { 16, 17, 18, 0, 8, 7, 9, 6, 10, 5, 11, 4, 12, 3, 13, 2, 14, 1, 15 };
                var code_len_tbl = [_]u8 { 0 } ** 19;
                
                // Code lengths for literal/length and distance
                const hlit = stream.readBits(5, null) + 257;
                const hdist = stream.readBits(5, null) + 1;

                // Code lengths for the code length alphabet (?)
                const hclen = stream.readBits(4, null) + 4;

                // Read 3 bits HCLEN times to fill out the lengths table
                var hclen_idx: usize = 0;
                while (hclen_idx < hclen and hclen_idx < symbol_tbl.len) : (hclen_idx += 1) {
                    const sym_len = stream.readBits(3, null);
                    code_len_tbl[symbol_tbl[hclen_idx]] = @intCast(sym_len);
                }

                const codes = allocator.alloc(u7, hclen) catch return FileFormatError.MalformedChunk;
                defer allocator.free(codes);

                std.debug.print("HLIT: {}\nHDIST: {}\nHCEN: {}\n", .{ hlit, hdist, hclen });
                for (symbol_tbl) |sym| {
                    std.debug.print("[{}]: {}\n", .{ sym, code_len_tbl[sym] });
                }

            } else {
                break;
            }
            std.debug.print("{}, {}\n", .{ bfinal, btype });
            // if (bfinal > 0) break;
            break;
        }

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

const BTYPE = enum(u2) {
    no_compression = 0,
    compressed_fixed = 1,
    compressed_dynamic = 2,
    reserved = 3
};

/// Helper for reading data bitwise
const IDATStream = struct {
    num_chunks: usize,
    allocator: Allocator,
    data: [][]const u8,
    bit_idx: u4,
    byte_idx: usize,
    data_idx: usize,

    pub fn init(allocator: Allocator, chunks: []IDAT) !IDATStream {
        var data = try allocator.alloc([]const u8, chunks.len);
        for (chunks, 0..) |chunk, idx| {
            data[idx] = chunk.data;
        }

        return .{
            .allocator = allocator,
            .num_chunks = chunks.len,
            .data = data,
            .bit_idx = 0,
            .byte_idx = 0,
            .data_idx = 0
        };
    }

    /// Reads count bits from the stream and assigns the result to result, returns number of bits actually read
    pub fn readBits(self: *IDATStream, count: usize, bits_read: ?*u5) u16 {
        var counter: isize = @intCast(count - 1);
        var value: u16 = 0;
        var _bits_read: u5 = 0;
        while (counter >= 0 and self.data_idx < self.data.len) : (counter -= 1) {
            const mask: u16 = 0x0001;
            var cur = self.data[self.data_idx][self.byte_idx];
            cur >>= @intCast(self.bit_idx);
            const bit = (cur & mask) << @intCast(_bits_read);
            value |= bit;

            _bits_read += 1;
            self.bit_idx += 1;
            if (self.bit_idx == 8) {
                self.bit_idx = 0;
                self.byte_idx += 1;
            }
            if (self.byte_idx >= self.data[self.data_idx].len) {
                self.byte_idx = 0;
                self.data_idx += 1;
            }
        }
        if (bits_read) |br| br.* = _bits_read;
        return value;
    }

    /// If the reader is not currently byte-aligned, moves forward to the start of the next byte, otherwise does nothing
    pub fn seekByte(self: *IDATStream) void {
        if (self.bit_idx % 8 == 0) return;
        self.bit_idx = 0;
        self.byte_idx += 1;
        if (self.byte_idx >= self.data[self.data_idx].len) {
            self.byte_idx = 0;
            self.data_idx += 1;
        }
    }

    pub fn deinit(self: IDATStream) void {
        self.allocator.free(self.data);
    }
};

/// Stores the zlib compressed stream. Fields given by RFC-1950
pub const IDAT = struct {
    cm: ?u4,
    cinfo: ?u4,
    data: []const u8,

    /// Parses a chunk because the total number must be known for this call
    pub fn parse(chunk: Chunk, num_chunks: usize, chunk_idx: usize) IDAT {
        var data = chunk.data;
        var cm: ?u4 = null;
        var cinfo: ?u4 = null;
        if (chunk_idx == 0) {
            // First 2 bytes are for CMF and FLG
            const cmf = data[0];
            cm = @intCast(cmf & 0x0f);
            cinfo = @intCast((cmf & 0xf0) >> 4);
            data = data[2..];
        }
        if (chunk_idx == num_chunks - 1) {
            // Ignore last 4 bytes of crc
            data = data[0..data.len - 4];
        }

        return .{
            .cm = cm,
            .cinfo = cinfo,
            .data = data
        };
    }

    pub fn print(self: IDAT) void {
        std.debug.print("CM: {?}\nCINFO: {?}\nLength: {}\nData: {x}...\n", .{ self.cm, self.cinfo, self.data.len, self.data[0..4] });
    }
};

/// Stores critical information about the image and must be the first chunk (offset 8)
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

        const compression_method = chunk.data[10];
        if (compression_method != 0)
            return FileFormatError.UnsupportedCompressionMethod;

        return .{
            .width = width,
            .height = height,
            .bit_depth = bit_depth,
            .color_type = color_type, 
            .compression_method = compression_method, 
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

/// Stores the color table as a slice of 3-byte segments where each byte is R,G,B in order.
pub const PLTE = struct {
    colors: []const [3]u8,

    pub fn parse(chunk: Chunk) FileFormatError!PLTE {
        if (chunk.data.len % 3 != 0)
            return FileFormatError.MalformedChunk;

        // Retinterpret as slice of triples
        const colors = std.mem.bytesAsSlice([3]u8, chunk.data);
        
        return .{
            .colors = colors
        };
    }

    pub fn print(self: PLTE) void {
        for (self.colors, 0..) |color, idx| {
            std.debug.print("{:0>3}: {x:0>2}{x:0>2}{x:0>2}\n", .{ idx, color[0], color[1], color[2] });
        }
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
