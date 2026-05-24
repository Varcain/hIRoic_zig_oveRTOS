const std = @import("std");
const ove = @import("ove");
const dsp = @import("dsp.zig");
const shared = @import("shared.zig");

fn peakAbs(data: []const i16) i16 {
    var p: i16 = 0;
    for (data) |v| {
        const a: i16 = if (v < 0) -%v else v;
        if (a > p) p = a;
    }
    return p;
}

pub const HiroicDsp = struct {
    pub fn process(_: *HiroicDsp, input: ove.audio.AudioBuf, output: ove.audio.AudioBuf) void {
        const src = input.dataS16();
        const dst = output.dataS16Mut();

        const start = ove.time.getUs() catch 0;

        shared.rx_peak.store(peakAbs(src), .monotonic);

        if (shared.events) |evt| {
            const bits = evt.getBits();
            if ((bits & shared.EVT_IR_LOADING) != 0 or (bits & shared.EVT_IR_BYPASS) != 0) {
                const n = @min(src.len, dst.len);
                @memcpy(dst[0..n], src[0..n]);
            } else {
                dsp.process(dst, src);
            }
        } else {
            const n = @min(src.len, dst.len);
            @memcpy(dst[0..n], src[0..n]);
        }

        const end = ove.time.getUs() catch start;
        _ = shared.total_proc_us.fetchAdd(@intCast(end - start), .monotonic);
        _ = shared.proc_count.fetchAdd(1, .monotonic);

        shared.audio_peak.store(peakAbs(dst), .monotonic);
    }
};

pub var dsp_node: HiroicDsp = .{};
