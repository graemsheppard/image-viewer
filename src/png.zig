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
    trns: ?TRNS,
    chunks: ArrayList(Chunk),
    bytes_per_row: u32,
    pixels: []u8,

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
        const bpp = ihdr.getBitsPerPixel();
        const bytes_per_row = (bpp * ihdr.width + 7) / 8;
        const total_pixels = ihdr.width * ihdr.height;
        const total_size = (bytes_per_row + 1) * ihdr.height;

        const plte_required = ihdr.color_type == 3;

        var idx: usize = 33;
        var chunk_count: usize = 0;
        var plte: ?PLTE = null;
        var trns: ?TRNS = null;
        var reached_end = false;
        var data_chunks: usize = 0;
        while (idx < data.len) : (chunk_count += 1) {
            const chunk = Chunk.parse(idx, data);
            if (std.mem.eql(u8, chunk.name, "PLTE"))
                plte = try PLTE.parse(chunk);
            if (std.mem.eql(u8, chunk.name, "tRNS"))
                trns = try TRNS.parse(chunk);
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
            idat_idx += 1;
        }

        var stream = IDATStream.init(allocator, idat_chunks) catch return FileFormatError.MalformedChunk;
        defer stream.deinit();

        var output_idx: usize = 0;
        const output_buffer = allocator.alloc(u8, total_size) catch return FileFormatError.InvalidHuffmanCode;
        @memset(output_buffer, 0);
        defer allocator.free(output_buffer);

        // Process the zlib stream 1 block at a time, each block starts with 3-bit header
        while (try parseBlock(allocator, &stream, output_buffer, &output_idx)) {}

        var pixels = allocator.alloc(u8, total_pixels * 4) catch return FileFormatError.CorruptedData;
        @memset(pixels, 0);

        std.debug.print("{}\n{}\n", .{ bpp, ihdr.color_type });

        // Unfilter the pixels by scanline, each scanline could have a different filter method
        const bypp = (bpp + 7) / 8;
        for (0..ihdr.height) |scanline_idx| {
            const stride = bytes_per_row + 1;
            const scanline = output_buffer[(scanline_idx * stride)..((scanline_idx + 1) * stride)];
            const filter_type = scanline[0];
            const line_data = scanline[1..];

            for (line_data, 0..) |*byte, byte_idx| {
                const a = if (byte_idx >= bypp) line_data[byte_idx - bypp] else 0;
                const b = if (scanline_idx > 0) output_buffer[(scanline_idx - 1) * stride + 1 + byte_idx] else 0;
                const c = if (byte_idx >= bypp and scanline_idx > 0) output_buffer[(scanline_idx - 1) * stride + 1 + byte_idx - bypp] else 0;

                byte.* = switch(filter_type) {
                    0 => byte.*,
                    1 => byte.* +% a,
                    2 => byte.* +% b,
                    3 => byte.* +% @as(u8, @truncate((@as(u16, a) + b) / 2)),
                    4 => byte.* +% paethPredictor(a, b, c),
                    else => return FileFormatError.UnsupportedFormat
                };
            }

            for (0..ihdr.width) |x| {
                const dest_idx = (scanline_idx * ihdr.width + x) * 4;
                switch (ihdr.color_type) {
                    3 => { 
                        const palette_idx = line_data[x];
                        const rgb = plte.?.colors[palette_idx];
                        const alpha = if (trns) |t| t.alphaAt(palette_idx) else 0xff;
                        
                        pixels[dest_idx + 0] = rgb[0];
                        pixels[dest_idx + 1] = rgb[1];
                        pixels[dest_idx + 2] = rgb[2];
                        pixels[dest_idx + 3] = alpha;
                    },
                    2 => { 
                        pixels[dest_idx + 0] = line_data[x * 3 + 0];
                        pixels[dest_idx + 1] = line_data[x * 3 + 1];
                        pixels[dest_idx + 2] = line_data[x * 3 + 2];
                        pixels[dest_idx + 3] = 0xff;
                    },
                    6 => { 
                        pixels[dest_idx + 0] = line_data[x * 4 + 0];
                        pixels[dest_idx + 1] = line_data[x * 4 + 1];
                        pixels[dest_idx + 2] = line_data[x * 4 + 2];
                        pixels[dest_idx + 3] = line_data[x * 4 + 3];
                    },
                    else => unreachable
                }
            }
        } 

        return .{
            .file_name = file_name,
            .allocator = allocator,
            .ihdr = ihdr,
            .plte = plte,
            .trns = trns,
            .chunks = chunks,
            .bytes_per_row = bytes_per_row,
            .pixels = pixels
        };
    }

    fn paethPredictor(a: u8, b: u8, c: u8) u8 {
        const ia = @as(i16, a);
        const ib = @as(i16, b);
        const ic = @as(i16, c);
        const p = ia + ib - ic;

        const pa = @abs(p - ia);
        const pb = @abs(p - ib);
        const pc = @abs(p - ic);

        if (pa <= pb and pa <= pc) return a;
        if (pb <= pc) return b;
        return c;
    }

    /// Parses a block from the stream, storing the partial result in the buffer. Assumes we are at the strat of the block including header
    /// Returns true if there are more blocks following this one.
    fn parseBlock(allocator: Allocator, stream: *IDATStream, output_buffer: []u8, output_idx: *usize) FileFormatError!bool {
        var bits_read: u5 = 0;
        const block_header = stream.readBits(3, &bits_read);
        
        if (bits_read < 3) return FileFormatError.CorruptedData;

        const bfinal = block_header & 0x1;
        const btype_val = @as(u2, @intCast((block_header >> 1) & 0b11));
        const btype: BTYPE = @enumFromInt(btype_val);

        switch(btype) { 
            .no_compression => try parseBlockUncompressed(stream, output_buffer, output_idx),
            .compressed_fixed => try parseBlockCompressedFixed(allocator, stream, output_buffer, output_idx),
            .compressed_dynamic => try parseBlockCompressedDynamic(allocator, stream, output_buffer, output_idx),
            .reserved => return FileFormatError.UnsupportedCompressionMethod
        }
        
        return bfinal == 0;
    }

    /// Parses a zlib format block from the stream where the bytes are the literal values, first 4 bytes are for length and its compliment
    fn parseBlockUncompressed(stream: *IDATStream, output_buffer: []u8, output_idx: *usize) FileFormatError!void {
        var len_buf: [4]u8 = undefined;
        try stream.readBytes(&len_buf);
        const len = bytesToUsizeBig(len_buf[0..2], u16) catch return FileFormatError.CorruptedData;
        const output_target: []u8 = output_buffer[output_idx.*..(output_idx.* + len)];
        try stream.readBytes(output_target);
    }

    /// Parses a zlib format block from the stream with the predefined huffman codes
    fn parseBlockCompressedFixed(_: Allocator, stream: *IDATStream, output_buffer: []u8, output_idx: *usize) FileFormatError!void {
        while (true) {
            const lit_symbol = try decodeSymbol(stream, &fixed_codes, &fixed_code_lengths);
            if (!try parseSymbol(stream, lit_symbol, &fixed_distances, &fixed_distance_lengths, output_buffer, output_idx)) break;
        }
    }

    /// Parses a zlib format block from the stream that uses dynamic huffman codes
    fn parseBlockCompressedDynamic(allocator: Allocator, stream: *IDATStream, output_buffer: []u8, output_idx: *usize) FileFormatError!void {
        const symbol_tbl = [_]u8 { 16, 17, 18, 0, 8, 7, 9, 6, 10, 5, 11, 4, 12, 3, 13, 2, 14, 1, 15 };
        var code_len_tbl = [_]u4 { 0 } ** 19;
        
        // Code lengths for literal/length, distance, and code length alphabets
        const hlit = stream.readBits(5, null) + 257;
        const hdist = stream.readBits(5, null) + 1;
        const hclen = stream.readBits(4, null) + 4;

        // Read 3 bits HCLEN times to fill out the lengths table
        var hclen_idx: usize = 0;
        while (hclen_idx < hclen and hclen_idx < symbol_tbl.len) : (hclen_idx += 1) {
            const sym_len = stream.readBits(3, null);
            code_len_tbl[symbol_tbl[hclen_idx]] = @intCast(sym_len);
        }

        const tree_codes = try generateCodes(allocator, &code_len_tbl);
        defer allocator.free(tree_codes);

        const num_lengths = hdist + hlit;
        var all_lengths = allocator.alloc(u4, num_lengths) catch return FileFormatError.InvalidHuffmanCode;
        defer allocator.free(all_lengths);

        // Build the huffman code lookup for the literal/length and distances
        var symbols_decoded: u9 = 0;
        while (symbols_decoded < (hdist + hlit)) {
            const code_len_symbol = try decodeSymbol(stream, tree_codes, &code_len_tbl);

            if (code_len_symbol <= 15) {
                all_lengths[symbols_decoded] = @intCast(code_len_symbol);
                symbols_decoded += 1;
            }
            // Handle repeat codes (16-18)
            else if (code_len_symbol == 16) {
                // Repeat previous length n times
                if (symbols_decoded == 0) return FileFormatError.InvalidHuffmanCode;
                const repeat = stream.readBits(2, null) + 3;
                const val = all_lengths[symbols_decoded - 1];
                for (0..repeat) |_| {
                    all_lengths[symbols_decoded] = val;
                    symbols_decoded += 1;
                }
            } else if (code_len_symbol == 17) {
                // Repeat 0 n times
                const repeat = stream.readBits(3, null) + 3;
                for (0..repeat) |_| {
                    all_lengths[symbols_decoded] = 0;
                    symbols_decoded += 1;
                }
            } else if (code_len_symbol == 18) {
                // Repeat 0 n times
                const repeat = stream.readBits(7, null) + 11;
                for (0..repeat) |_| {
                    all_lengths[symbols_decoded] = 0;
                    symbols_decoded += 1;
                }
            }
        }

        const literal_lengths = all_lengths[0..hlit];
        const distance_lengths = all_lengths[hlit..];

        const literal_codes = try generateCodes(allocator, literal_lengths);
        defer allocator.free(literal_codes);

        const distance_codes = try generateCodes(allocator, distance_lengths);
        defer allocator.free(distance_codes);

        // Use the generated literal/length and distance tables to decompress the data
        while (true) {
            const lit_symbol = try decodeSymbol(stream, literal_codes, literal_lengths);
            if (!try parseSymbol(stream, lit_symbol, distance_codes, distance_lengths, output_buffer, output_idx)) break;
        }
    }

    /// Given a literal/length symbol parses it into the output buffer and the following dist symbol (if the symbol was a length).
    /// Returns false when 256 (EOB) is reached.
    fn parseSymbol(stream: *IDATStream, lit_symbol: u16, distance_codes: []const u16, distance_lengths: []const u4, output_buffer: []u8, output_idx: *usize) FileFormatError!bool {
        switch(lit_symbol) {
            // A literal byte, add it to the output
            0...255 => {
                const byte: u8 = @intCast(lit_symbol);
                output_buffer[output_idx.*] = byte;
                output_idx.* += 1;
            },
            // Signifies end of block
            256 => return false,
            // A length of bytes to copy which must be followed by a distance of bytes to look back
            257...285 => {
                const len_info = length_info_tbl[lit_symbol - 257];
                const extra_length = if (len_info.extra_bits > 0) stream.readBits(len_info.extra_bits, null) else 0;
                const length = len_info.base + extra_length;

                const dist_symbol = try decodeSymbol(stream, distance_codes, distance_lengths);
                const dist_info = distance_info_tbl[dist_symbol];
                const extra_dist = if (dist_info.extra_bits > 0) stream.readBits(dist_info.extra_bits, null) else 0;
                const distance = dist_info.base + extra_dist;

                for (0..length) |_| {
                    const back_byte = output_buffer[output_idx.* - distance];
                    output_buffer[output_idx.*] = back_byte;
                    output_idx.* += 1;
                }
            },
            else => return FileFormatError.CorruptedData
        }

        return true;
    }

    /// Given an array of lengths, returns an array of equal size of codes. Caller owns the memory.
    fn generateCodes(allocator: Allocator, lengths: []u4) FileFormatError![]u16 {
        var codes = allocator.alloc(u16, lengths.len) catch return FileFormatError.InvalidHuffmanCode;
        @memset(codes, 0);

        // Count occurrences of each length
        var length_counts: [16]u9 = [_]u9 { 0 } ** 16;
        for (lengths) |length| {
            if (length > 0) length_counts[length] += 1;
        }

        // Generates the first code for each code length
        var base_codes = [_]u16 { 0 } ** 16;
        var base_code: u16 = 0;
        for (1..16) |bits| {
            base_code = (base_code + length_counts[bits - 1]) << 1;
            base_codes[bits] = base_code;
        }

        // Assigns the huffman code for each symbol
        for (lengths, 0..) |length, length_idx| {
            if (length == 0) continue;
            codes[length_idx] = base_codes[length];
            base_codes[length] += 1;
        }

        return codes;
    }

    /// Decodes the next symbol in the stream given a code table and length table indexed by the symbol, advancing the stream
    pub fn decodeSymbol(stream: *IDATStream, code_tbl: []const u16, length_tbl: []const u4) FileFormatError!u16 {
        var bit_len: u8 = 0;
        var cur: u16 = 0;
        while(true) {
            stream.readBit(&cur);
            bit_len += 1;

            if (bit_len > 15) return FileFormatError.InvalidHuffmanCode;

            for (code_tbl, 0..) |code, symbol| {
                if (length_tbl[symbol] == bit_len and code == cur) {
                    return @intCast(symbol);
                }
            }
        }
    }

    pub fn deinit(self: PNG) void {
        self.chunks.deinit();
        self.allocator.free(self.pixels);
    }
};

const CodeInfo = struct {
    base: u16,
    extra_bits: u4
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

    /// Reads a single bit into the destination, shifting the destination left
    pub fn readBit(self: *IDATStream, destination: *u16) void {
        var bits_read: u5 = 0;
        const bit = self.readBits(1, &bits_read);
        if (bits_read == 0) return;

        destination.* <<= 1;
        destination.* |= (bit & 0x1);
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
        if (self.bit_idx % 8 == 0 or self.data_idx >= self.data.len) return;
        self.bit_idx = 0;
        self.byte_idx += 1;
        if (self.byte_idx >= self.data[self.data_idx].len) {
            self.byte_idx = 0;
            self.data_idx += 1;
        }
    }

    /// Read bytes into the target slice until it is full or there is no more data in the stream. Returns error if bytes read does not match requested.
    pub fn readBytes(self: *IDATStream, output: []u8) FileFormatError!void {
        self.seekByte();
        var bytes_read: usize = 0;
        for (output, 0..) |_, idx| {
            output[idx] = self.data[self.data_idx][self.byte_idx];
            self.byte_idx += 1;
            bytes_read += 1;
            if (self.byte_idx >= self.data[self.data_idx].len) {
                self.byte_idx = 0;
                self.data_idx += 1;
            }
            if (self.data_idx >= self.data.len) break;
        }
        
        if (bytes_read == output.len) return FileFormatError.CorruptedData;
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

    fn getBitsPerPixel(self: IHDR) u8 {
        return switch(self.color_type) {
            0, 3 => self.bit_depth,     // Grayscale, Indexed(Palette)
            2 => self.bit_depth * 3,    // RGB
            4 => self.bit_depth * 2,    // Grayscale w/ alpha
            5 => self.bit_depth * 4,    // RGBA
            else => unreachable
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
};

/// Stores the alpha for each pallette index as a byte.
pub const TRNS = struct {
    alphas: []const u8,

    pub fn parse(chunk: Chunk) FileFormatError!TRNS {
        return .{
            .alphas = chunk.data
        };
    }

    /// Alphas is not guaranteed to have 256 entries so this should be used.
    pub fn alphaAt(self: TRNS, idx: usize) u8 {
        return if (idx >= self.alphas.len) 0xff else self.alphas[idx];
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

/// Indexed by length symbol, base is the base length and extra bits is how many to read and add onto base. [RFC-1951]
const length_info_tbl: [29]CodeInfo = [_]CodeInfo {
    .{ .base = 3,   .extra_bits = 0 },
    .{ .base = 4,   .extra_bits = 0 },
    .{ .base = 5,   .extra_bits = 0 },
    .{ .base = 6,   .extra_bits = 0 },
    .{ .base = 7,   .extra_bits = 0 },
    .{ .base = 8,   .extra_bits = 0 },
    .{ .base = 9,   .extra_bits = 0 },
    .{ .base = 10,  .extra_bits = 0 },
    .{ .base = 11,  .extra_bits = 1 },
    .{ .base = 13,  .extra_bits = 1 },
    .{ .base = 15,  .extra_bits = 1 },
    .{ .base = 17,  .extra_bits = 1 },
    .{ .base = 19,  .extra_bits = 2 },
    .{ .base = 23,  .extra_bits = 2 },
    .{ .base = 27,  .extra_bits = 2 },
    .{ .base = 31,  .extra_bits = 2 },
    .{ .base = 35,  .extra_bits = 3 },
    .{ .base = 43,  .extra_bits = 3 },
    .{ .base = 51,  .extra_bits = 3 },
    .{ .base = 59,  .extra_bits = 3 },
    .{ .base = 67,  .extra_bits = 4 },
    .{ .base = 83,  .extra_bits = 4 },
    .{ .base = 99,  .extra_bits = 4 },
    .{ .base = 115, .extra_bits = 4 },
    .{ .base = 131, .extra_bits = 5 },
    .{ .base = 163, .extra_bits = 5 },
    .{ .base = 195, .extra_bits = 5 },
    .{ .base = 227, .extra_bits = 5 },
    .{ .base = 258, .extra_bits = 0 }
};

/// Indexed by distance symbol, base is the base distance and extra bits is how many to read and add onto base. [RFC-1951]
const distance_info_tbl: [30]CodeInfo = [_]CodeInfo {
    .{ .base = 1,     .extra_bits = 0 },
    .{ .base = 2,     .extra_bits = 0 },
    .{ .base = 3,     .extra_bits = 0 },
    .{ .base = 4,     .extra_bits = 0 },
    .{ .base = 5,     .extra_bits = 1 },
    .{ .base = 7,     .extra_bits = 1 },
    .{ .base = 9,     .extra_bits = 2 },
    .{ .base = 13,    .extra_bits = 2 },
    .{ .base = 17,    .extra_bits = 3 },
    .{ .base = 25,    .extra_bits = 3 },
    .{ .base = 33,    .extra_bits = 4 },
    .{ .base = 49,    .extra_bits = 4 },
    .{ .base = 65,    .extra_bits = 5 },
    .{ .base = 97,    .extra_bits = 5 },
    .{ .base = 129,   .extra_bits = 6 },
    .{ .base = 193,   .extra_bits = 6 },
    .{ .base = 257,   .extra_bits = 7 },
    .{ .base = 385,   .extra_bits = 7 },
    .{ .base = 513,   .extra_bits = 8 },
    .{ .base = 769,   .extra_bits = 8 },
    .{ .base = 1025,  .extra_bits = 9 },
    .{ .base = 1537,  .extra_bits = 9 },
    .{ .base = 2049,  .extra_bits = 10 },
    .{ .base = 3073,  .extra_bits = 10 },
    .{ .base = 4097,  .extra_bits = 11 },
    .{ .base = 6145,  .extra_bits = 11 },
    .{ .base = 8193,  .extra_bits = 12 },
    .{ .base = 12289, .extra_bits = 12 },
    .{ .base = 16385, .extra_bits = 13 },
    .{ .base = 24577, .extra_bits = 13 }
};

// Calculate fixed huffman codes and their bit lengths at comptime
const fixed_codes = fixed_blk: {
    var temp_codes: [288]u16 = undefined;
    for (0..144, 0..)   |sym, idx| temp_codes[sym] = 0b00110000 + idx;
    for (144..256, 0..) |sym, idx| temp_codes[sym] = 0b110010000 + idx;
    for (256..280, 0..) |sym, idx| temp_codes[sym] = 0b0000000 + idx;
    for (280..288, 0..) |sym, idx| temp_codes[sym] = 0b11000000 + idx;
    break :fixed_blk temp_codes;
};

const fixed_code_lengths = fixed_blk: {
    var temp_lengths: [288]u4 = undefined;
    for (0..144)   |sym| temp_lengths[sym] = 8;
    for (144..256) |sym| temp_lengths[sym] = 9;
    for (256..279) |sym| temp_lengths[sym] = 7;
    for (279..288) |sym| temp_lengths[sym] = 8;
    break :fixed_blk temp_lengths;
};

const fixed_distances = fixed_blk: {
    var temp_distances: [32]u16 = undefined;
    for (0..32) |idx| temp_distances[idx] = idx;
    break :fixed_blk temp_distances;
};

const fixed_distance_lengths = fixed_blk: {
    var temp_lengths: [32]u4 = undefined;
    for (0..32) |idx| temp_lengths[idx] = 5;
    break :fixed_blk temp_lengths;
};
