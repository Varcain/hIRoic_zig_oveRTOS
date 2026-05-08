const std = @import("std");
const ove = @import("ove");
const app_conf = @import("app_conf.zig");

pub const FormatCode = enum(u16) {
    pcm = 0x0001,
    ieee_float = 0x0003,
    a_law = 0x0006,
    mu_law = 0x0007,
    extensible = 0xFFFE,
    _,
};

pub const WavData = struct {
    format: FormatCode,
    num_channels: u32,
    sample_rate: u32,
    block_align: u32,
    bits_per_sample: u32,
    num_samples: u32,
    samples: []const u8,
};

pub const ParseError = error{
    TooSmall,
    BadRiff,
    BadWave,
    BadRiffSize,
    MissingFmt,
    MissingData,
    FmtTooSmall,
    UnsupportedFormat,
    UnsupportedBps,
    InvalidChannels,
    InvalidSampleRate,
    BlockAlignMismatch,
    ByteRateMismatch,
    EmptyData,
};

const CHUNK_RIFF: u32 = @bitCast([4]u8{ 'R', 'I', 'F', 'F' });
const CHUNK_WAVE: u32 = @bitCast([4]u8{ 'W', 'A', 'V', 'E' });
const CHUNK_FMT: u32 = @bitCast([4]u8{ 'f', 'm', 't', ' ' });
const CHUNK_DATA: u32 = @bitCast([4]u8{ 'd', 'a', 't', 'a' });

const FMT_MIN: usize = 16;
const HDR: usize = 8;

fn u32le(b: []const u8) u32 {
    return std.mem.readInt(u32, b[0..4], .little);
}

fn u16le(b: []const u8) u16 {
    return std.mem.readInt(u16, b[0..2], .little);
}

pub fn parse(buf: []const u8) ParseError!WavData {
    if (buf.len < 12) return ParseError.TooSmall;

    if (u32le(buf[0..4]) != CHUNK_RIFF) return ParseError.BadRiff;
    const riff_size = u32le(buf[4..8]);
    if (u32le(buf[8..12]) != CHUNK_WAVE) return ParseError.BadWave;
    if (riff_size < 4 or riff_size > std.math.maxInt(u32) - 8)
        return ParseError.BadRiffSize;

    const end = @min(buf.len, 8 + @as(usize, riff_size));
    var offset: usize = 12;

    var fmt_slice: ?[]const u8 = null;
    var data_slice: ?[]const u8 = null;
    var data_size: u32 = 0;

    while (offset + HDR <= end) {
        const id = u32le(buf[offset .. offset + 4]);
        const size: usize = u32le(buf[offset + 4 .. offset + 8]);
        const body_start = offset + HDR;
        const body_end = @min(end, body_start + size);

        if (id == CHUNK_FMT) {
            if (size < FMT_MIN) return ParseError.FmtTooSmall;
            fmt_slice = buf[body_start..body_end];
        } else if (id == CHUNK_DATA) {
            data_slice = buf[body_start..body_end];
            data_size = @intCast(size);
            break;
        }
        offset += HDR + size;
    }

    const fmt = fmt_slice orelse return ParseError.MissingFmt;
    const data = data_slice orelse return ParseError.MissingData;

    const format_raw = u16le(fmt[0..2]);
    if (format_raw != 0x0001) return ParseError.UnsupportedFormat;

    const num_channels: u32 = u16le(fmt[2..4]);
    const sample_rate = u32le(fmt[4..8]);
    const byte_rate = u32le(fmt[8..12]);
    const block_align: u32 = u16le(fmt[12..14]);
    const bits_per_sample: u32 = u16le(fmt[14..16]);

    if (bits_per_sample != 16 and bits_per_sample != 24 and
        bits_per_sample != 32)
        return ParseError.UnsupportedBps;
    if (num_channels < 1) return ParseError.InvalidChannels;
    if (sample_rate == 0) return ParseError.InvalidSampleRate;
    if (block_align != num_channels * (bits_per_sample / 8))
        return ParseError.BlockAlignMismatch;
    if (byte_rate != sample_rate * block_align)
        return ParseError.ByteRateMismatch;
    if (data_size == 0) return ParseError.EmptyData;

    var num_samples: u32 = data_size / block_align;
    if (num_samples > app_conf.IR_MAX_LEN) {
        num_samples = @intCast(app_conf.IR_MAX_LEN);
    }
    const sample_bytes: usize = @as(usize, num_samples) * block_align;
    const slice_end = @min(sample_bytes, data.len);

    _ = ove;
    return WavData{
        .format = @enumFromInt(format_raw),
        .num_channels = num_channels,
        .sample_rate = sample_rate,
        .block_align = block_align,
        .bits_per_sample = bits_per_sample,
        .num_samples = num_samples,
        .samples = data[0..slice_end],
    };
}
