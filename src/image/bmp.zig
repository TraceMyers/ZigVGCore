
const graphics = @import("../graphics.zig");
const std = @import("std");
const string = @import("../string.zig");
const memory = @import("../memory.zig");
const imagef = @import("image.zig");
const bench = @import("../benchmark.zig");

const LocalStringBuffer = string.LocalStringBuffer;
const RGBA32 = graphics.RGBA32;
const RGB24 = graphics.RGB24;
const print = std.debug.print;
const Image = imagef.Image;
const ImageError = imagef.ImageError;

// /////////////////////////////////////////////////////////////////////////////////////////////////////////////////////
// ------------------------------------------------------------------------------------------------------- pub functions
// /////////////////////////////////////////////////////////////////////////////////////////////////////////////////////

pub fn load(file: *std.fs.File, image: *Image, allocator: memory.Allocator) !void {
    var buffer: []u8 = try loadFileAndCoreHeaders(file, allocator, bmp_min_sz);
    defer allocator.free(buffer);

    try validateIdentity(buffer); 

    var info = BitmapInfo{};
    if (!readInitial(buffer, &info)) {
        return ImageError.BmpInvalidBytesInFileHeader;
    }
    if (buffer.len <= info.header_sz + bmp_file_header_sz or buffer.len <= info.data_offset) {
        return ImageError.UnexpectedEOF;
    }

    try loadRemainder(file, buffer, &info);

    var color_table = BitmapColorTable{};
    var buffer_pos: usize = undefined;
    switch (info.header_sz) {
        bmp_info_header_sz_core => buffer_pos = try readCoreInfo(buffer, &info, &color_table),
        bmp_info_header_sz_v1 => buffer_pos = try readV1Info(buffer, &info, &color_table),
        bmp_info_header_sz_v4 => buffer_pos = try readV4Info(buffer, &info, &color_table),
        bmp_info_header_sz_v5 => buffer_pos = try readV5Info(buffer, &info, &color_table),
        else => return ImageError.BmpInvalidHeaderSizeOrVersionUnsupported, 
    }

    if (!colorSpaceSupported(&info)) {
        return ImageError.BmpColorSpaceUnsupported;
    }
    if (!compressionSupported(&info)) {
        return ImageError.BmpCompressionUnsupported;
    }

    try createImage(buffer, image, &info, &color_table, allocator);
}

// /////////////////////////////////////////////////////////////////////////////////////////////////////////////////////
// ----------------------------------------------------------------------------------------------------------- functions
// /////////////////////////////////////////////////////////////////////////////////////////////////////////////////////

fn loadFileAndCoreHeaders(file: *std.fs.File, allocator: anytype, min_sz: usize) ![]u8 {
    const stat = try file.stat();
    if (stat.size + 4 > memory.MAX_SZ) {
        return ImageError.TooLarge;
    }
    if (stat.size < min_sz) {
        return ImageError.InvalidSizeForFormat;
    }
    var buffer: []u8 = try allocator.allocExplicitAlign(u8, stat.size + 4, 4);
    for (0..bmp_file_header_sz + bmp_info_header_sz_core) |i| {
        buffer[i] = try file.reader().readByte();
    }
    return buffer;
}

fn loadRemainder(file: *std.fs.File, buffer: []u8, info: *BitmapInfo) !void {
    const cur_offset = bmp_file_header_sz + bmp_info_header_sz_core;
    for (cur_offset..info.data_offset) |i| {
        buffer[i] = try file.reader().readByte();
    }

    // aligning pixel data to a 4 byte boundary (requirement)
    const offset_mod_4 = info.data_offset % 4;
    const offset_mod_4_neq_0 = @intCast(u32, @boolToInt(offset_mod_4 != 0));
    info.data_offset = info.data_offset + offset_mod_4_neq_0 * (4 - offset_mod_4);

    var data_buf: []u8 = buffer[info.data_offset..];
    _ = try file.reader().read(data_buf);
}

inline fn readInitial(buffer: []const u8, info: *BitmapInfo) bool {
    info.file_sz = std.mem.readIntNative(u32, buffer[2..6]);
    const reserved_verify_zero = std.mem.readIntNative(u32, buffer[6..10]);
    if (reserved_verify_zero != 0) {
        return false;
    }
    info.data_offset = std.mem.readIntNative(u32, buffer[10..14]);
    info.header_sz = std.mem.readIntNative(u32, buffer[14..18]);
    return true;
}

fn validateIdentity(buffer: []const u8) !void {
    const identity = buffer[0..2];
    if (!string.same(identity, "BM")) {
        // identity strings acceptable for forms of OS/2 bitmaps. microsoft shouldered-out IBM and started taking over
        // the format during windows 3.1 times.
        if (string.same(identity, "BA")
            or string.same(identity, "CI")
            or string.same(identity, "CP")
            or string.same(identity, "IC")
            or string.same(identity, "PT")
        ) {
            return ImageError.BmpFlavorUnsupported;
        }
        else {
            return ImageError.BmpInvalidBytesInFileHeader;
        }
    }
}

fn readCoreInfo(buffer: []u8, info: *BitmapInfo, color_table: *BitmapColorTable) !usize {
    info.header_type = BitmapHeaderType.Core;
    info.width = @intCast(i32, std.mem.readIntNative(i16, buffer[18..20]));
    info.height = @intCast(i32, std.mem.readIntNative(i16, buffer[20..22]));
    info.color_depth = @intCast(u32, std.mem.readIntNative(u16, buffer[24..26]));
    info.data_size = info.file_sz - info.data_offset;
    info.compression = BitmapCompression.RGB;
    const table_offset = bmp_file_header_sz + bmp_info_header_sz_core;
    try readColorTable(buffer[table_offset..], info, color_table, graphics.RGB24);
    return table_offset + color_table.length * @sizeOf(graphics.RGB24);
}

fn readV1Info(buffer: []u8, info: *BitmapInfo, color_table: *BitmapColorTable) !usize {
    info.header_type = BitmapHeaderType.V1;
    readV1HeaderPart(buffer, info);
    var mask_offset: usize = 0;
    if (info.compression == BitmapCompression.BITFIELDS) {
        readColorMasks(buffer, info, false);
        mask_offset = 12;
    }
    else if (info.compression == BitmapCompression.ALPHABITFIELDS) {
        readColorMasks(buffer, info, true);
        mask_offset = 16;
    }
    const table_offset = bmp_file_header_sz + bmp_info_header_sz_v1 + mask_offset;
    try readColorTable(buffer[table_offset..], info, color_table, graphics.RGB32);
    return table_offset + color_table.length * @sizeOf(graphics.RGB32);
}

fn readV4Info(buffer: []u8, info: *BitmapInfo, color_table: *BitmapColorTable) !usize {
    info.header_type = BitmapHeaderType.V4;
    readV1HeaderPart(buffer, info);
    readV4HeaderPart(buffer, info);
    const table_offset = bmp_file_header_sz + bmp_info_header_sz_v4;
    try readColorTable(buffer[table_offset..], info, color_table, graphics.RGB32);
    return table_offset + color_table.length * @sizeOf(graphics.RGB32);
}

fn readV5Info(buffer: []u8, info: *BitmapInfo, color_table: *BitmapColorTable) !usize {
    info.header_type = BitmapHeaderType.V5;
    readV1HeaderPart(buffer, info);
    readV4HeaderPart(buffer, info);
    readV5HeaderPart(buffer, info);
    const table_offset = bmp_file_header_sz + bmp_info_header_sz_v5;
    try readColorTable(buffer[table_offset..], info, color_table, graphics.RGB32);
    return table_offset + color_table.length * @sizeOf(graphics.RGB32);
}

inline fn readV1HeaderPart(buffer: []u8, info: *BitmapInfo) void {
    info.width = std.mem.readIntNative(i32, buffer[18..22]);
    info.height = std.mem.readIntNative(i32, buffer[22..26]);
    info.color_depth = @intCast(u32, std.mem.readIntNative(u16, buffer[28..30]));
    info.compression = @intToEnum(BitmapCompression, std.mem.readIntNative(u32, buffer[30..34]));
    info.data_size = std.mem.readIntNative(u32, buffer[34..38]);
    info.color_ct = std.mem.readIntNative(u32, buffer[46..50]);
}

fn readV4HeaderPart(buffer: []u8, info: *BitmapInfo) void {
    readColorMasks(buffer, info, true);
    info.color_space = @intToEnum(BitmapColorSpace, std.mem.readIntNative(u32, buffer[70..74]));
    if (info.color_space == BitmapColorSpace.sRGB or info.color_space == BitmapColorSpace.WindowsCS) {
        return;
    }
    var buffer_casted = @ptrCast([*]FxPt2Dot30, @alignCast(@alignOf(FxPt2Dot30), &buffer[72]));
    @memcpy(info.cs_points.red[0..3], buffer_casted[0..3]);
    @memcpy(info.cs_points.green[0..3], buffer_casted[3..6]);
    @memcpy(info.cs_points.blue[0..3], buffer_casted[6..9]);
    info.red_gamma = std.mem.readIntNative(u32, buffer[110..114]);
    info.green_gamma = std.mem.readIntNative(u32, buffer[114..118]);
    info.blue_gamma = std.mem.readIntNative(u32, buffer[118..122]);
}

inline fn readV5HeaderPart(buffer: []u8, info: *BitmapInfo) void {
    info.profile_data = std.mem.readIntNative(u32, buffer[126..130]);
    info.profile_size = std.mem.readIntNative(u32, buffer[130..134]);
}

inline fn readColorMasks(buffer: []u8, info: *BitmapInfo, alpha: bool) void {
    info.red_mask = std.mem.readIntNative(u32, buffer[54..58]);
    info.green_mask = std.mem.readIntNative(u32, buffer[58..62]);
    info.blue_mask = std.mem.readIntNative(u32, buffer[62..66]);
    if (alpha) {
        info.alpha_mask = std.mem.readIntNative(u32, buffer[66..70]);
    }
}

fn readColorTable(
    buffer: []u8, info: *const BitmapInfo, color_table: *BitmapColorTable, comptime ColorType: type
) !void {
    var data_casted = @ptrCast([*]ColorType, @alignCast(@alignOf(ColorType), &buffer[0]));

    switch (info.color_depth) {
        32, 24, 16 => {
            if (info.color_ct > 0) {
                // (nowadays typical) large color depths might have a color table in order to support 256 bit
                // video adapters. currently this function will retrieve the table, but it goes unused.
                if (info.color_ct >= 2 and info.color_ct <= 256) {
                    color_table.length = info.color_ct;
                }
                else {
                    return ImageError.BmpInvalidColorCount;
                }
            }
            else {
                color_table.length = 0;
                return;
            }
        },
        8 => {
            if (info.color_ct > 0) {
                if (info.color_ct >= 2 and info.color_ct <= 256) {
                    color_table.length = info.color_ct;
                }
                else {
                    return ImageError.BmpInvalidColorCount;
                }
            }
            else {
                color_table.length = 256;
            }
        },
        4 => {
            if (info.color_ct > 0) {
                if (info.color_ct >= 2 and info.color_ct <= 16) {
                    color_table.length = info.color_ct;
                }
                else {
                    return ImageError.BmpInvalidColorCount;
                }
            }
            else {
                color_table.length = 16;
            }
        },
        1 => {
            if (info.color_ct == 0 or info.color_ct == 2) {
                color_table.length = 2;
            }
            else {
                return ImageError.BmpInvalidColorCount;
            }
        },
        else => return ImageError.BmpInvalidColorDepth,
    }

    if (buffer.len <= color_table.length * @sizeOf(ColorType)) {
        return ImageError.UnexpectedEOF;
    }
    else {
        for (0.. color_table.length) |i| {
            const table_color: *RGBA32 = &color_table.buffer[i];
            const buffer_color: *const ColorType = &data_casted[i];
            // bgr to rgb
            table_color.a = 255;
            table_color.b = buffer_color.r;
            table_color.g = buffer_color.g;
            table_color.r = buffer_color.b;
        }
    }
}

inline fn colorSpaceSupported(info: *const BitmapInfo) bool {
    return switch(info.color_space) {
        .CalibratedRGB => false,
        .ProfileLinked => false,
        .ProfileEmbedded => false,
        .WindowsCS => true,
        .sRGB => true,
        .None => true,
    };
}

inline fn compressionSupported(info: *const BitmapInfo) bool {
    return switch(info.compression) {
        .RGB => true,
        .RLE8 => true,
        .RLE4 => true,
        .BITFIELDS => true,
        .JPEG => false,
        .PNG => false,
        .ALPHABITFIELDS => true,
        .CMYK => false,
        .CMYKRLE8 => false,
        .CMYKRLE4 => false,
        .None => false,
    };
}

inline fn bufferLongEnough(pixel_buf: []const u8, image: *const Image, row_length: usize) bool {
    return pixel_buf.len >= row_length * image.height;
}

fn createImage(
    buffer: []const u8, 
    image: *Image, 
    info: *const BitmapInfo, 
    color_table: *const BitmapColorTable, 
    allocator: memory.Allocator
) !void {
    image.width = @intCast(u32, try std.math.absInt(info.width));
    image.height = @intCast(u32, try std.math.absInt(info.height));
    image.allocator = allocator;
    image.pixels = try image.allocator.?.alloc(graphics.RGBA32, image.width * image.height);
    errdefer image.clear();

    var t = bench.ScopeTimer.start("createImage (pre pixels)", bench.getScopeTimerID());
    defer t.stop();

    // get row length in bytes as a multiple of 4 (rows are padded to 4 byte increments)
    const row_length = ((image.width * info.color_depth + 31) & ~@as(u32, 31)) >> 3;    
    const pixel_buf = buffer[info.data_offset..];

    try switch(info.compression) {
        .RGB => switch(info.color_depth) {
            1 => try readColorTableImage(u1, pixel_buf, info, color_table, image, row_length),
            4 => try readColorTableImage(u4, pixel_buf, info, color_table, image, row_length),
            8 => try readColorTableImage(u8, pixel_buf, info, color_table, image, row_length),
            16 => try readInlinePixelImage(u16, pixel_buf, info, image, row_length, true),
            24 => try readInlinePixelImage(u24, pixel_buf, info, image, row_length, true),
            32 => try readInlinePixelImage(u32, pixel_buf, info, image, row_length, true),
            else => ImageError.BmpInvalidColorDepth,
        },
        .RLE8 => {
            if (info.color_depth != 8) {
                return ImageError.BmpInvalidCompression;
            }
            return ImageError.BmpCompressionUnsupported;
        },
        .RLE4 => {
            if (info.color_depth != 4) {
                return ImageError.BmpInvalidCompression;
            }
            return ImageError.BmpCompressionUnsupported;
        },
        .BITFIELDS, .ALPHABITFIELDS => switch(info.color_depth) {
            16 => try readInlinePixelImage(u16, pixel_buf, info, image, row_length, false),
            24 => try readInlinePixelImage(u24, pixel_buf, info, image, row_length, false),
            32 => try readInlinePixelImage(u32, pixel_buf, info, image, row_length, false),
            else => return ImageError.BmpInvalidCompression,
        },
        else => return ImageError.BmpCompressionUnsupported,
    };
}

// bitmaps are stored bottom to top, meaning the top-left corner of the image is idx 0 of the last row, unless the
// height param is negative. we always read top to bottom and write up or down depending.
inline fn initWrite(info: *const BitmapInfo, image: *const Image) BmpWriteInfo {
    const write_direction = @intToEnum(BitmapReadDirection, @intCast(u8, @boolToInt(info.height < 0)));
    if (write_direction == .BottomUp) {
        return BmpWriteInfo {
            .begin = (@intCast(i32, image.height) - 1) * @intCast(i32, image.width),
            .increment = -@intCast(i32, image.width),
        };
    }
    else {
        return BmpWriteInfo {
            .begin = 0,
            .increment = @intCast(i32, image.width),
        };
    }
}

fn readColorTableImage(
    comptime PixelType: type, 
    pixel_buf: []const u8, 
    info: *const BitmapInfo,
    color_table: *const BitmapColorTable, 
    image: *Image, 
    row_sz: usize
) !void {
    if (color_table.length < 2) {
        return ImageError.BmpInvalidColorTable;
    }
    if (!bufferLongEnough(pixel_buf, image, row_sz)) {
        return ImageError.UnexpectedEOF;
    }
    
    const write_info = initWrite(info, image);

    const byte_iter_ct = switch(PixelType) {
        u1 => image.width >> 3,
        u4 => image.width >> 1,
        u8 => 1,
        else => unreachable,
    };
    const indices_per_byte = switch(PixelType) {
        u1 => 8,
        u4 => 2,
        u8 => 1,
        else => unreachable,
    };
    const row_remainder = image.width - byte_iter_ct * indices_per_byte;

    const colors = color_table.slice();
    var px_row_start: usize = 0;
   
    for (0..image.height) |i| {
        const row_start = @intCast(usize, write_info.begin + write_info.increment * @intCast(i32, i));
        const row_end = row_start + image.width;

        var index_row = pixel_buf[px_row_start..px_row_start + row_sz];
        var image_row = image.pixels.?[row_start..row_end];

        // over each pixel (index to the color table) in the buffer row...
        switch(PixelType) {
            u1 => {
                var img_idx: usize = 0;
                for (0..byte_iter_ct) |byte| {
                    const idx_byte = index_row[byte];
                    // mask each bit in the byte and get the index to the 2-color table
                    inline for (0..8) |j| {
                        const mask: comptime_int = @as(u8, 0x80) >> @intCast(u3, j);
                        const col_idx: u8 = (idx_byte & mask) >> @intCast(u3, 7-j);
                        if (col_idx >= colors.len) {
                            return ImageError.BmpInvalidColorTableIndex;
                        }
                        image_row[img_idx+j] = colors[col_idx];
                    }
                    img_idx += 8;
                }
                // if there are 1-7 indices left at the end, get the remaining colors
                if (row_remainder > 0) {
                    const idx_byte = index_row[byte_iter_ct];
                    for (0..row_remainder) |j| {
                        const mask = @as(u8, 0x80) >> @intCast(u3, j);
                        const col_idx: u8 = (idx_byte & mask) >> @intCast(u3, 7-j);
                        if (col_idx >= colors.len) {
                            return ImageError.BmpInvalidColorTableIndex;
                        }
                        image_row[img_idx+j] = colors[col_idx];
                    }
                }
            },
            u4 => {
                var img_idx: usize = 0;
                for (0..byte_iter_ct) |byte| {
                    // mask each 4bit index (0 to 15) in the byte and get the color table entry
                    inline for(0..2) |j| {
                        const mask: comptime_int = @as(u8, 0xf0) >> (j*4);
                        const col_idx: u8 = (index_row[byte] & mask) >> (4-(j*4));
                        if (col_idx >= colors.len) {
                            return ImageError.BmpInvalidColorTableIndex;
                        }
                        image_row[img_idx+j] = colors[col_idx];
                    }
                    img_idx += 2;
                }
                // if there is a single remaining index, get the remaining color
                if (row_remainder > 0) {
                    const col_idx: u8 = (index_row[byte_iter_ct] & @as(u8, 0xf0)) >> 4;
                    if (col_idx >= colors.len) {
                        return ImageError.BmpInvalidColorTableIndex;
                    }
                    image_row[img_idx] = colors[col_idx];
                }
            },
            u8 => {
                // each byte is an index to the color table
                for (0..image.width) |img_idx| {
                    const col_idx: u8 = index_row[img_idx];
                    if (col_idx >= colors.len) {
                        return ImageError.BmpInvalidColorTableIndex;
                    }
                    image_row[img_idx] = colors[col_idx];
                }
            },
            else => unreachable,
        }
        px_row_start += row_sz;
    }
}

fn validColorMasks(comptime PixelType: type, info: *const BitmapInfo) bool {
    const mask_intersection = info.red_mask & info.green_mask & info.blue_mask & info.alpha_mask;
    if (mask_intersection > 0) {
        return false;
    }
    const mask_union = info.red_mask | info.green_mask | info.blue_mask | info.alpha_mask;
    const type_overflow = ((@as(u32, @sizeOf(u32)) << 3) - @clz(mask_union)) > (@as(u32, @sizeOf(PixelType)) << 3);
    if (type_overflow) {
        return false;
    }
    return true;
}

fn readInlinePixelImage(
    comptime PixelType: type,
    pixel_buf: []const u8,
    info: *const BitmapInfo,
    image: *Image,
    row_sz: usize,
    standard_masks: bool
) !void {
    const alpha_bitfields =  info.compression == .ALPHABITFIELDS;

    if (alpha_bitfields and PixelType != u32) {
        return ImageError.BmpInvalidPixelSizeForAlphaBitfields;
    }
    if (!bufferLongEnough(pixel_buf, image, row_sz)) {
        return ImageError.UnexpectedEOF;
    }
    if (!standard_masks) {
        if (PixelType == u24) {
            return ImageError.Bmp24BitCustomMasksUnsupported;
        }
        if (!validColorMasks(PixelType, info)) {
            return ImageError.BmpInvalidColorMasks;
        }
    }

    const write_info = initWrite(info, image);
    const mask_set = 
        if (standard_masks) try BitmapColorMaskSet(PixelType).standard()
        else try BitmapColorMaskSet(PixelType).fromInfo(info);

    var px_start: usize = 0;
    for (0..image.height) |i| {
        const img_start = @intCast(usize, write_info.begin + write_info.increment * @intCast(i32, i));
        const img_end = img_start + image.width;

        var image_row = image.pixels.?[img_start..img_end];
        var file_buffer_row = pixel_buf[px_start..px_start + row_sz];

        // apply custom or standard rgb/rgba masks to each u16, u24 or u32 pixel in the row, store in RGBA32 image
        mask_set.extractRow(image_row, file_buffer_row, alpha_bitfields);

        px_start += row_sz;
    }
}

// /////////////////////////////////////////////////////////////////////////////////////////////////////////////////////
// ----------------------------------------------------------------------------------------------------------- constants
// /////////////////////////////////////////////////////////////////////////////////////////////////////////////////////

const bmp_file_header_sz = 14;
const bmp_info_header_sz_core = 12;
const bmp_info_header_sz_v1 = 40;
const bmp_info_header_sz_v4 = 108;
const bmp_info_header_sz_v5 = 124;
const bmp_row_align = 4; // bmp pixel rows pad to 4 bytes
const bmp_rgb24_sz = 3;
// the smallest possible (hard disk) bmp has a core header, 1 bit px / 2 colors in table, width in [1,32] and height = 1
const bmp_min_sz = bmp_file_header_sz + bmp_info_header_sz_core + 2 * bmp_rgb24_sz + bmp_row_align;

// /////////////////////////////////////////////////////////////////////////////////////////////////////////////////////
// --------------------------------------------------------------------------------------------------------------- enums
// /////////////////////////////////////////////////////////////////////////////////////////////////////////////////////

const BitmapColorTableType = enum { None, RGB24, RGB32 };

const BitmapHeaderType = enum(u32) { None, Core, V1, V4, V5 };

const BitmapCompression = enum(u32) { 
    RGB, RLE8, RLE4, BITFIELDS, JPEG, PNG, ALPHABITFIELDS, CMYK, CMYKRLE8, CMYKRLE4, None 
};

const BitmapReadDirection = enum(u8) { BottomUp=0, TopDown=1 };

const BitmapColorSpace = enum(u32) {
    CalibratedRGB = 0x0,
    ProfileLinked = 0x4c494e4b,
    ProfileEmbedded = 0x4d424544,
    WindowsCS = 0x57696e20,
    sRGB = 0x73524742,
    None = 0xffffffff,
};

// /////////////////////////////////////////////////////////////////////////////////////////////////////////////////////
// --------------------------------------------------------------------------------------------------------------- types
// /////////////////////////////////////////////////////////////////////////////////////////////////////////////////////

const BitmapColorTable = struct {
    buffer: [256]graphics.RGBA32 = undefined,
    length: usize = 0,

    pub inline fn slice(self: *const BitmapColorTable) []const graphics.RGBA32 {
        return self.buffer[0..self.length];
    }
};

const FxPt2Dot30 = extern struct {
    data: u32,

    pub inline fn integer(self: *const FxPt2Dot30) u32 {
        return (self.data & 0xc0000000) >> 30;
    }

    pub inline fn fraction(self: *const FxPt2Dot30) u32 {
        return self.data & 0x8fffffff;
    }
};

const CieXYZTriple = extern struct {
    red: [3]FxPt2Dot30 = undefined,
    green: [3]FxPt2Dot30 = undefined,
    blue: [3]FxPt2Dot30 = undefined,
};

const BmpWriteInfo = struct {
    begin: i32,
    increment: i32,
};

fn BitmapColorMask(comptime IntType: type) type {

    const ShiftType = switch(IntType) {
        u16 => u4,
        u24 => u5,
        u32 => u5,
        else => undefined
    };

    return struct {
        const MaskType = @This();

        mask: IntType = 0,
        rshift: ShiftType = 0,
        lshift: ShiftType = 0,

        fn new(in_mask: u32) !MaskType {
            const type_bit_sz = @sizeOf(IntType) * 8;
            const target_leading_zero_ct = type_bit_sz - 8;
            const shr: i32 = @as(i32, target_leading_zero_ct) - @intCast(i32, @clz(@intCast(IntType, in_mask)));
            if (shr > 0) {
                return MaskType{ .mask=@intCast(IntType, in_mask), .rshift=@intCast(ShiftType, shr) };
            }
            else {
                return MaskType{ .mask=@intCast(IntType, in_mask), .lshift=@intCast(ShiftType, try std.math.absInt(shr)) };
            }
        }

        inline fn extractColor(self: *const MaskType, pixel: IntType) u8 {
            return @intCast(u8, ((pixel & self.mask) >> self.rshift) << self.lshift);
        }
    };
}

fn BitmapColorMaskSet(comptime IntType: type) type {

    return struct {
        const SetType = @This();

        r_mask: BitmapColorMask(IntType) = BitmapColorMask(IntType){},
        g_mask: BitmapColorMask(IntType) = BitmapColorMask(IntType){},
        b_mask: BitmapColorMask(IntType) = BitmapColorMask(IntType){},
        a_mask: BitmapColorMask(IntType) = BitmapColorMask(IntType){},

        inline fn standard() !SetType {
            return SetType {
                .r_mask=switch(IntType) {
                    u16 => try BitmapColorMask(IntType).new(0x7c00),
                    u24 => try BitmapColorMask(IntType).new(0),
                    u32 => try BitmapColorMask(IntType).new(0x00ff0000),
                    else => unreachable,
                },
                .g_mask=switch(IntType) {
                    u16 => try BitmapColorMask(IntType).new(0x03e0),
                    u24 => try BitmapColorMask(IntType).new(0),
                    u32 => try BitmapColorMask(IntType).new(0x0000ff00),
                    else => unreachable,
                },
                .b_mask=switch(IntType) {
                    u16 => try BitmapColorMask(IntType).new(0x001f),
                    u24 => try BitmapColorMask(IntType).new(0),
                    u32 => try BitmapColorMask(IntType).new(0x000000ff),
                    else => unreachable,
                },
                .a_mask=switch(IntType) {
                    u16 => try BitmapColorMask(IntType).new(0),
                    u24 => try BitmapColorMask(IntType).new(0),
                    u32 => try BitmapColorMask(IntType).new(0xff000000),
                    else => unreachable,
                },
            };
        }

        inline fn fromInfo(info: *const BitmapInfo) !SetType {
            return SetType{
                .r_mask=try BitmapColorMask(IntType).new(info.red_mask),
                .b_mask=try BitmapColorMask(IntType).new(info.blue_mask),
                .g_mask=try BitmapColorMask(IntType).new(info.green_mask),
                .a_mask=try BitmapColorMask(IntType).new(info.alpha_mask),
            };
        }

        inline fn extractRGBA(self: *const SetType, pixel: IntType) RGBA32 {
            return RGBA32 {
                .r=self.r_mask.extractColor(pixel),
                .g=self.g_mask.extractColor(pixel),
                .b=self.b_mask.extractColor(pixel),
                .a=self.a_mask.extractColor(pixel)
            };
        }

        inline fn extractRGB(self: *const SetType, pixel: IntType) RGBA32 {
            return RGBA32 {
                .r=self.r_mask.extractColor(pixel),
                .g=self.g_mask.extractColor(pixel),
                .b=self.b_mask.extractColor(pixel),
                .a=255
            };
        }

        inline fn extractRow(self: *const SetType, image_row: []RGBA32, pixel_row: []const u8, mask_alpha: bool) void {
            if (mask_alpha) {
                self.extractRowRGBA(image_row, pixel_row);
            }
            else {
                self.extractRowRGB(image_row, pixel_row);
            }
        }

        inline fn extractRowRGB(self: *const SetType, image_row: []RGBA32, pixel_row: []const u8) void {
            switch(IntType) {
                u16, u32 => {
                    var pixels = @ptrCast([*]const IntType, @alignCast(@alignOf(IntType), &pixel_row[0]))[0..image_row.len];
                    for (0..image_row.len) |j| {
                        image_row[j] = self.extractRGB(pixels[j]);
                    }
                },
                u24 => {
                    var byte: usize = 0;
                    for (0..image_row.len) |j| {
                        const image_pixel: *RGBA32 = &image_row[j];
                        image_pixel.a = 255;
                        image_pixel.b = pixel_row[byte];
                        image_pixel.g = pixel_row[byte+1];
                        image_pixel.r = pixel_row[byte+2];
                        byte += 3;
                    }
                },
                else => unreachable,
            }
        }

        inline fn extractRowRGBA(self: *const SetType, image_row: []RGBA32, pixel_row: []const u8) void {
            var pixels = @ptrCast([*]const IntType, @alignCast(@alignOf(IntType), &pixel_row[0]))[0..image_row.len];
            for (0..image_row.len) |j| {
                image_row[j] = self.extractRGBA(pixels[j]);
            }
        }
    };
}

const BitmapInfo = extern struct {
    file_sz: u32 = 0,
    // offset from beginning of file to pixel data
    data_offset: u32 = 0,
    // size of the info header (comes after the file header)
    header_sz: u32 = 0,
    header_type: BitmapHeaderType = .None,
    width: i32 = 0,
    height: i32 = 0,
    // bits per pixel
    color_depth: u32 = 0,
    compression: BitmapCompression = .None,
    // pixel data size; may not always be valid.
    data_size: u32 = 0,
    // how many colors in image. mandatory for color depths of 1,4,8. if 0, using full color depth.
    color_ct: u32 = 0,
    // masks to pull color data from pixels. only used if compression is BITFIELDS or ALPHABITFIELDS
    red_mask: u32 = 0x0,
    green_mask: u32 = 0x0,
    blue_mask: u32 = 0x0,
    alpha_mask: u32 = 0x0,
    // how the colors should be interpreted
    color_space: BitmapColorSpace = .None,
    // if using a color space profile, info about how to interpret colors
    profile_data: u32 = undefined,
    profile_size: u32 = undefined,
    // triangle representing the color space of the image
    cs_points: CieXYZTriple = undefined,
    // function f takes two parameters: 1.) gamma and 2.) a color value c in, for example, 0 to 255. It outputs
    // a color value f(gamma, c) in 0 and 255, on a concave curve. larger gamma -> more concave.
    red_gamma: u32 = undefined,
    green_gamma: u32 = undefined,
    blue_gamma: u32 = undefined,
};
