const std = @import("std");

pub const PgmError = error{
    InvalidMagicNumber,
    InvalidHeader,
    InvalidDimensions,
    InvalidMaxVal,
    UnexpectedEof,
    OutOfMemory,
    ReadError,
};

pub const PgmImage = struct {
    width: u32,
    height: u32,
    maxval: u16, // Must be > 0 and < 65536
    pixels: Pixels,
    allocator: std.mem.Allocator,

    pub fn deinit(self: *PgmImage) void {
        switch (self.pixels) {
            .data_u8 => |data| self.allocator.free(data),
            .data_u16 => |data| self.allocator.free(data),
        }
    }
};

pub const Pixels = union(enum) {
    data_u8: []u8,
    data_u16: []u16, // Must be stored in host-native endianness
};

pub fn decode(allocator: std.mem.Allocator, reader: anytype) !PgmImage {
    var br = std.io.bufferedReader(reader);
    const buff_reader = br.reader();

    // Helper function to skip whitespace and comments.
    // This is a closure that captures `br`.
    const skipWhitespaceAndComments = struct {
        fn skip(r: anytype, b: *std.io.BufferedReader(4096, @TypeOf(reader))) !void {
            var in_comment = false;
            while (true) {
                const byte = r.readByte() catch |err| switch (err) {
                    error.EndOfStream => return,
                    else => return err,
                };

                if (in_comment) {
                    if (byte == '\n' or byte == '\r') {
                        in_comment = false;
                    }
                } else {
                    if (byte == '#') {
                        in_comment = true;
                    } else if (!std.ascii.isWhitespace(byte)) {
                        // Not whitespace, so put it back and we're done.
                        try b.seekTo(b.pos - 1);
                        return;
                    }
                }
            }
        }
    }.skip;

    // Helper to read the next non-whitespace token.
    // This is also a closure that captures `br`.
    const readToken = struct {
        fn read(r: anytype, b: *std.io.BufferedReader(4096, @TypeOf(reader)), buffer: []u8) ![]u8 {
            try skipWhitespaceAndComments(r, b);
            var len: usize = 0;
            while (len < buffer.len) : (len += 1) {
                const byte = r.readByte() catch |err| switch (err) {
                    error.EndOfStream => break,
                    else => return err,
                };
                if (std.ascii.isWhitespace(byte)) {
                    try b.seekTo(b.pos - 1);
                    break;
                }
                buffer[len] = byte;
            }
            if (len == 0) return PgmError.UnexpectedEof;
            return buffer[0..len];
        }
    }.read;

    var token_buffer: [32]u8 = undefined;

    // 1. Read and check magic number
    const magic = try readToken(buff_reader, &br, &token_buffer);
    if (!std.mem.eql(u8, magic, "P5")) {
        return PgmError.InvalidMagicNumber;
    }

    // 2. Read width
    const width_str = try readToken(buff_reader, &br, &token_buffer);
    const width = std.fmt.parseUnsigned(u32, width_str, 10) catch return PgmError.InvalidDimensions;
    if (width == 0) return PgmError.InvalidDimensions;

    // 3. Read height
    const height_str = try readToken(buff_reader, &br, &token_buffer);
    const height = std.fmt.parseUnsigned(u32, height_str, 10) catch return PgmError.InvalidDimensions;
    if (height == 0) return PgmError.InvalidDimensions;

    // 4. Read maxval
    const maxval_str = try readToken(buff_reader, &br, &token_buffer);
    const maxval = std.fmt.parseUnsigned(u16, maxval_str, 10) catch return PgmError.InvalidMaxVal;
    if (maxval == 0 or maxval >= 65536) return PgmError.InvalidMaxVal;

    // 5. Consume the single whitespace character delimiter
    const delimiter = buff_reader.readByte() catch return PgmError.UnexpectedEof;
    if (!std.ascii.isWhitespace(delimiter)) {
        return PgmError.InvalidHeader;
    }

    // 6. Allocate memory and read raster data
    const num_pixels = width * height;

    var image = PgmImage{
        .width = width,
        .height = height,
        .maxval = maxval,
        .allocator = allocator,
        .pixels = undefined,
    };

    if (maxval < 256) {
        const pixel_data = try allocator.alloc(u8, num_pixels);
        errdefer allocator.free(pixel_data);

        const bytes_read = try buff_reader.readAll(pixel_data);
        if (bytes_read != num_pixels) {
            return PgmError.UnexpectedEof;
        }
        image.pixels = .{ .data_u8 = pixel_data };
    } else {
        const pixel_data = try allocator.alloc(u16, num_pixels);
        errdefer allocator.free(pixel_data);

        const raw_buffer = std.mem.sliceAsBytes(pixel_data);
        const bytes_read = try buff_reader.readAll(raw_buffer);
        if (bytes_read != num_pixels * 2) {
            return PgmError.UnexpectedEof;
        }

        std.mem.swapBigToNative(u16, pixel_data);

        image.pixels = .{ .data_u16 = pixel_data };
    }

    return image;
}

pub fn encode(image: PgmImage, writer: anytype) !void {
    var bw = std.io.bufferedWriter(writer);
    const buff_writer = bw.writer();

    // 1. Write header in a canonical format for maximum compatibility.
    try buff_writer.print("P5\n{d} {d}\n{d}\n", .{
        image.width,
        image.height,
        image.maxval,
    });

    // 2. Write raster data
    switch (image.pixels) {
        .data_u8 => |pixels| {
            try buff_writer.writeAll(pixels);
        },
        .data_u16 => |pixels| {
            // To avoid heap allocations, we process the data in chunks
            // using a stack-allocated buffer.
            var temp_buf: [64]u16 = undefined;
            var pixel_idx: usize = 0;
            while (pixel_idx < pixels.len) {
                const chunk_len = @min(temp_buf.len, pixels.len - pixel_idx);
                const chunk_in = pixels[pixel_idx .. pixel_idx + chunk_len];
                const chunk_out = temp_buf[0..chunk_len];

                // Copy a chunk of pixels to our temporary buffer.
                @memcpy(chunk_out.ptr, chunk_in.ptr, chunk_len * @sizeOf(u16));

                // Swap the chunk from native to big-endian.
                std.mem.swapNativeToBig(u16, chunk_out);

                // Write the byte-swapped chunk.
                try buff_writer.writeAll(std.mem.sliceAsBytes(chunk_out));

                pixel_idx += chunk_len;
            }
        },
    }

    try bw.flush();
}

const testing = std.testing;

test "8-bit round trip" {
    const allocator = testing.allocator;
    const width: u32 = 10;
    const height: u32 = 20;
    const num_pixels = width * height;

    var original_pixels = try allocator.alloc(u8, num_pixels);
    defer allocator.free(original_pixels);
    for (original_pixels, 0..) |_, i| {
        original_pixels[i] = @as(u8, @intCast(i % 256));
    }

    const original_image = PgmImage{
        .width = width,
        .height = height,
        .maxval = 255,
        .allocator = allocator,
        .pixels = .{ .data_u8 = original_pixels },
    };

    var buffer: [1024]u8 = undefined;
    var fbs = std.io.fixedBufferStream(&buffer);

    try encode(original_image, fbs.writer());

    try fbs.seekTo(0);

    var decoded_image = try decode(allocator, fbs.reader());
    defer decoded_image.deinit();

    try testing.expectEqual(original_image.width, decoded_image.width);
    try testing.expectEqual(original_image.height, decoded_image.height);
    try testing.expectEqual(original_image.maxval, decoded_image.maxval);
    try testing.expectEqualSlices(u8, original_image.pixels.data_u8, decoded_image.pixels.data_u8);
}

test "16-bit round trip and endianness" {
    const allocator = testing.allocator;
    const width: u32 = 5;
    const height: u32 = 5;
    const num_pixels = width * height;
    const test_pixel_value: u16 = 0x1A2B;

    var original_pixels = try allocator.alloc(u16, num_pixels);
    defer allocator.free(original_pixels);
    for (original_pixels, 0..) |_, i| {
        original_pixels[i] = @as(u16, @intCast(i));
    }
    original_pixels[10] = test_pixel_value; // A specific value to check endianness

    const original_image = PgmImage{
        .width = width,
        .height = height,
        .maxval = 10000,
        .allocator = allocator,
        .pixels = .{ .data_u16 = original_pixels },
    };

    var buffer: [1024]u8 = undefined;
    var fbs = std.io.fixedBufferStream(&buffer);

    try encode(original_image, fbs.writer());

    // Check endianness of the written data
    const written_bytes = fbs.getWritten();

    var newline_count = 0;
    var header_end_idx: usize = 0;
    for (written_bytes, 0..) |c, i| {
        if (c == '\n') {
            newline_count += 1;
            if (newline_count == 3) {
                header_end_idx = i + 1;
                break;
            }
        }
    }
    try testing.expect(header_end_idx > 0);

    const pixel_data_start = written_bytes[header_end_idx..];
    const test_pixel_bytes = pixel_data_start[10 * 2 .. 10 * 2 + 2];

    // The byte sequence should be 0x1A, 0x2B (Big Endian)
    try testing.expectEqual(@as(u8, 0x1A), test_pixel_bytes[0]);
    try testing.expectEqual(@as(u8, 0x2B), test_pixel_bytes[1]);


    try fbs.seekTo(0);

    var decoded_image = try decode(allocator, fbs.reader());
    defer decoded_image.deinit();

    try testing.expectEqual(original_image.width, decoded_image.width);
    try testing.expectEqualSlices(u16, original_image.pixels.data_u16, decoded_image.pixels.data_u16);
    try testing.expectEqual(test_pixel_value, decoded_image.pixels.data_u16[10]);
}

test "header flexibility" {
    const allocator = testing.allocator;
    const pgm_data =
        \\P5 #magic
        \\
        \\	 2#width
        \\#height comment
        \\2
        \\#maxval comment
        \\255
        \\
    ;
    var image_data_buffer: [128]u8 = undefined;
    const pgm_data_bytes = std.mem.sliceAsBytes(pgm_data);
    @memcpy(image_data_buffer[0..pgm_data_bytes.len], pgm_data_bytes);
    const pixel_data = "\x01\x02\x03\x04";
    const pixel_data_bytes = std.mem.sliceAsBytes(pixel_data);
    @memcpy(image_data_buffer[pgm_data_bytes.len..][0..pixel_data_bytes.len], pixel_data_bytes);

    const final_data = image_data_buffer[0..pgm_data_bytes.len+pixel_data_bytes.len];

    var fbs = std.io.fixedBufferStream(final_data);
    var image = try decode(allocator, fbs.reader());
    defer image.deinit();

    try testing.expectEqual(@as(u32, 2), image.width);
    try testing.expectEqual(@as(u32, 2), image.height);
    try testing.expectEqual(@as(u16, 255), image.maxval);
    try testing.expectEqualSlices(u8, &.{ 1, 2, 3, 4 }, image.pixels.data_u8);
}

test "critical delimiter pitfall" {
    const allocator = testing.allocator;
    // The single byte after maxval is a space. The first pixel is 0x0A (newline).
    const pgm_data = "P5 1 1 255 \x0A";
    var fbs = std.io.fixedBufferStream(pgm_data);
    var image = try decode(allocator, fbs.reader());
    defer image.deinit();

    try testing.expectEqual(@as(u32, 1), image.width);
    try testing.expectEqual(@as(u32, 1), image.height);
    try testing.expectEqualSlices(u8, &.{0x0A}, image.pixels.data_u8);
}

test "error handling" {
    const allocator = testing.allocator;

    // Bad magic number
    var fbs1 = std.io.fixedBufferStream("P6 1 1 255 \x00");
    try testing.expectError(PgmError.InvalidMagicNumber, decode(allocator, fbs1.reader()));

    // Non-numeric dimensions
    var fbs2 = std.io.fixedBufferStream("P5 1a 1 255 \x00");
    try testing.expectError(PgmError.InvalidDimensions, decode(allocator, fbs2.reader()));

    // EOF in header
    var fbs3 = std.io.fixedBufferStream("P5 1 1");
    try testing.expectError(PgmError.UnexpectedEof, decode(allocator, fbs3.reader()));

    // EOF in raster
    var fbs4 = std.io.fixedBufferStream("P5 2 2 255 \x01\x02\x03");
    try testing.expectError(PgmError.UnexpectedEof, decode(allocator, fbs4.reader()));

    // maxval == 0
    var fbs5 = std.io.fixedBufferStream("P5 1 1 0 \x00");
    try testing.expectError(PgmError.InvalidMaxVal, decode(allocator, fbs5.reader()));

    // maxval >= 65536
    var fbs6 = std.io.fixedBufferStream("P5 1 1 65536 \x00");
    try testing.expectError(PgmError.InvalidMaxVal, decode(allocator, fbs6.reader()));
}
