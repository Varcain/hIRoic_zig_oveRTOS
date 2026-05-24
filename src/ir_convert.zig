const std = @import("std");
const app_conf = @import("app_conf.zig");
const wav = @import("wav_parser.zig");

const log = std.log.scoped(.hiroic);

pub const Converted = struct {
    length: u32,
    sample_rate: u32,
};

pub const ConvertError = error{
    TooManyChannels,
    TooManySamples,
    BadBlockAlign,
    BufferTooSmall,
};

pub fn isWav(filename: []const u8) bool {
    if (filename.len < 4) return false;
    const ext = filename[filename.len - 4 ..];
    return ext[0] == '.' and
        std.ascii.toLower(ext[1]) == 'w' and
        std.ascii.toLower(ext[2]) == 'a' and
        std.ascii.toLower(ext[3]) == 'v';
}

pub fn convertSamples(data: wav.WavData, ir: []i32) ConvertError!Converted {
    if (data.num_channels > 1) return ConvertError.TooManyChannels;
    if (data.num_samples > app_conf.IR_MAX_LEN)
        return ConvertError.TooManySamples;
    if (data.num_samples > ir.len) return ConvertError.BufferTooSmall;
    if (data.block_align == 0 or data.block_align > app_conf.DSP_BITSIZE / 8)
        return ConvertError.BadBlockAlign;

    const n: usize = data.num_samples;
    const ba: usize = data.block_align;

    var i: usize = 0;
    while (i < n) : (i += 1) {
        var acc: i32 = 0;
        var j: usize = 0;
        while (j < ba) : (j += 1) {
            acc |= @as(i32, data.samples[i * ba + j]) <<
                @intCast(j * 8);
        }
        ir[i] = acc;
    }

    if (ba < 4) {
        const sign_bit: i32 = @as(i32, 1) << @intCast(ba * 8 - 1);
        i = 0;
        while (i < n) : (i += 1) {
            ir[i] = (ir[i] ^ sign_bit) - sign_bit;
        }
    }

    if (data.bits_per_sample != app_conf.DSP_BITSIZE) {
        if (app_conf.DSP_BITSIZE > data.bits_per_sample) {
            const shift: u5 = @intCast(app_conf.DSP_BITSIZE -
                data.bits_per_sample);
            i = 0;
            while (i < n) : (i += 1) ir[i] <<= shift;
        } else {
            const shift: u5 = @intCast(data.bits_per_sample -
                app_conf.DSP_BITSIZE);
            i = 0;
            while (i < n) : (i += 1) ir[i] >>= shift;
        }
    }

    log.info("ir: converted {d} samples @ {d} Hz", .{
        data.num_samples, data.sample_rate,
    });
    return Converted{ .length = data.num_samples, .sample_rate = data.sample_rate };
}
