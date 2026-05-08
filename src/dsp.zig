//! DSP engine — FFT-based overlap-add convolution via CMSIS-DSP.
//!
//! On ARM targets (`builtin.target.cpu.arch == .thumb`) the `arm_impl`
//! comptime block provides the full CMSIS-DSP FFT convolution path; on
//! POSIX / native it is a passthrough (matches C `dsp_stub.c`).
//!
//! CMSIS-DSP entry points are declared via `extern fn` rather than
//! `@cImport(arm_math.h)` to avoid requiring an `arm_math.h` include path
//! at `@cImport` resolution time — the symbols are already linked in by
//! the ARM board's CMakeLists, we just reference them.

const std = @import("std");
const builtin = @import("builtin");
const ove = @import("ove");
const app_conf = @import("app_conf.zig");

pub var loaded_sample_rate: std.atomic.Value(u32) = std.atomic.Value(u32).init(0);

const use_cmsis = builtin.target.cpu.arch == .thumb;

pub fn init() void {
    if (comptime use_cmsis) {
        arm_impl.init();
    } else {
        ove.log.inf("DSP stub: passthrough mode", .{});
    }
}

pub fn process(out: []i16, input: []const i16) void {
    if (comptime use_cmsis) {
        arm_impl.process(out, input);
    } else {
        const n = @min(@min(out.len, input.len), @as(usize, app_conf.DSP_BUFFER_SIZE));
        @memcpy(out[0..n], input[0..n]);
    }
}

pub fn loadIR(ir: []const i32, sample_rate: u32) void {
    loaded_sample_rate.store(sample_rate, .release);
    if (comptime use_cmsis) {
        arm_impl.loadIR(ir, sample_rate);
    } else {
        const len = @min(ir.len, app_conf.IR_MAX_LEN);
        ove.log.inf("DSP stub: IR load ignored ({d} samples @ {d} Hz)", .{ len, sample_rate });
    }
}

// ----------------------------------------------------------------------------
// ARM / CMSIS-DSP implementation
// ----------------------------------------------------------------------------

const arm_impl = if (use_cmsis) struct {
    // CMSIS-DSP FFI — linked from ARM build's CMSIS_DSP library.
    const arm_cfft_instance_q31 = opaque {};

    extern fn arm_cfft_q31(
        S: *const arm_cfft_instance_q31,
        p1: [*]i32,
        ifftFlag: u8,
        bitReverseFlag: u8,
    ) void;
    extern fn arm_cmplx_mult_cmplx_q31(
        pSrcA: [*]const i32,
        pSrcB: [*]const i32,
        pDst: [*]i32,
        numSamples: u32,
    ) void;
    extern fn arm_add_q31(
        pSrcA: [*]const i32,
        pSrcB: [*]const i32,
        pDst: [*]i32,
        blockSize: u32,
    ) void;

    extern const arm_cfft_sR_q31_len16: arm_cfft_instance_q31;
    extern const arm_cfft_sR_q31_len32: arm_cfft_instance_q31;
    extern const arm_cfft_sR_q31_len64: arm_cfft_instance_q31;
    extern const arm_cfft_sR_q31_len128: arm_cfft_instance_q31;
    extern const arm_cfft_sR_q31_len256: arm_cfft_instance_q31;
    extern const arm_cfft_sR_q31_len512: arm_cfft_instance_q31;
    extern const arm_cfft_sR_q31_len1024: arm_cfft_instance_q31;
    extern const arm_cfft_sR_q31_len2048: arm_cfft_instance_q31;
    extern const arm_cfft_sR_q31_len4096: arm_cfft_instance_q31;

    const FFT_CAP: u32 = 4096;

    fn nextPow2Capped(comptime n: comptime_int) comptime_int {
        comptime {
            var p: u32 = 16;
            while (p < n and p < FFT_CAP) : (p <<= 1) {}
            return @min(p, FFT_CAP);
        }
    }

    const FFT_SIZE_MAX: usize = nextPow2Capped(
        app_conf.DSP_BUFFER_SIZE + app_conf.IR_MAX_LEN - 1,
    );

    const IrState = struct {
        ir_fft: [FFT_SIZE_MAX * 2]i32,
        fft_instance: ?*const arm_cfft_instance_q31,
        fft_size: u32,
        fft_log2n: u32,
        overlap_size: u32,
        ir_boost_bits: u32,
    };

    // Memory placement.  Section names are RTOS-specific: FreeRTOS / NuttX
    // board linker scripts define `.dsp_bss` (DTCM) and `.sdram_bss`
    // (external SDRAM); Zephyr's generated linker uses `.dtcm_bss`
    // (matching the upstream `__dtcm_bss_section` macro) and `SDRAM1`
    // (matching `LINKER_DT_NODE_REGION_NAME(DT_NODELABEL(sdram1))`).  If
    // the section name doesn't match a region in the resolved linker
    // script, the linker silently emits the data into flash — which then
    // traps with an MPU data-access fault when the runtime tries to
    // touch it at startup.  The C++ port handles this in `dsp.cpp` via
    // `#if defined(__ZEPHYR__)`.
    const is_zephyr = @hasDecl(ove.ffi, "CONFIG_OVE_RTOS_ZEPHYR");
    const dsp_section: []const u8 = if (is_zephyr) ".dtcm_bss" else ".dsp_bss";
    const sdram_section: []const u8 = if (is_zephyr) "SDRAM1" else ".sdram_bss";

    var state_a: IrState linksection(sdram_section) = undefined;
    var state_b: IrState linksection(sdram_section) = undefined;

    var input_fft: [FFT_SIZE_MAX * 2]i32 linksection(dsp_section) = undefined;
    var output_fft: [FFT_SIZE_MAX * 2]i32 linksection(dsp_section) = undefined;
    var overlap_buffer: [FFT_SIZE_MAX]i32 linksection(dsp_section) = undefined;
    var work_buffer: [FFT_SIZE_MAX]i32 linksection(dsp_section) = undefined;

    var active_ir: std.atomic.Value(*IrState) = undefined;

    fn fftInstanceFor(size: u32) ?*const arm_cfft_instance_q31 {
        return switch (size) {
            16 => &arm_cfft_sR_q31_len16,
            32 => &arm_cfft_sR_q31_len32,
            64 => &arm_cfft_sR_q31_len64,
            128 => &arm_cfft_sR_q31_len128,
            256 => &arm_cfft_sR_q31_len256,
            512 => &arm_cfft_sR_q31_len512,
            1024 => &arm_cfft_sR_q31_len1024,
            2048 => &arm_cfft_sR_q31_len2048,
            4096 => &arm_cfft_sR_q31_len4096,
            else => null,
        };
    }

    fn setFftSize(s: *IrState, ir_len: u32) void {
        const min_fft = app_conf.DSP_BUFFER_SIZE + ir_len - 1;
        if (min_fft > FFT_CAP) {
            ove.log.err("dsp: required FFT size {d} > {d}", .{ min_fft, FFT_CAP });
            s.fft_size = 0;
            s.overlap_size = 0;
            s.fft_log2n = 0;
            s.fft_instance = null;
            return;
        }
        var p: u32 = 16;
        while (p < min_fft and p < FFT_CAP) : (p <<= 1) {}
        s.fft_size = p;
        s.overlap_size = p - app_conf.DSP_BUFFER_SIZE;
        s.fft_instance = fftInstanceFor(p);

        var tmp: u32 = p;
        s.fft_log2n = 0;
        while (tmp > 1) : (tmp >>= 1) s.fft_log2n += 1;

        if (s.fft_instance == null) {
            s.fft_size = 0;
            s.fft_log2n = 0;
            s.overlap_size = 0;
        }
    }

    fn absQ31(v: i32) i32 {
        return if (v < 0) -%v else v;
    }

    pub fn init() void {
        @memset(std.mem.asBytes(&state_a), 0);
        @memset(std.mem.asBytes(&state_b), 0);
        @memset(std.mem.asBytes(&overlap_buffer), 0);
        active_ir = std.atomic.Value(*IrState).init(&state_a);

        // No IR loaded — `process()` falls through to passthrough until
        // `loadIR()` is called with a real IR.
    }

    pub fn process(out: []i16, input: []const i16) void {
        const ir = active_ir.load(.acquire);
        const instance = ir.fft_instance orelse {
            const n = @min(@min(out.len, input.len), @as(usize, app_conf.DSP_BUFFER_SIZE));
            @memcpy(out[0..n], input[0..n]);
            return;
        };
        const fs = ir.fft_size;
        const log2n = ir.fft_log2n;
        const ovl: usize = ir.overlap_size;

        // int16 → Q31 complex (interleaved real / imag=0)
        var i: usize = 0;
        while (i < app_conf.DSP_BUFFER_SIZE) : (i += 1) {
            input_fft[i * 2] = @as(i32, input[i]) << 16;
            input_fft[i * 2 + 1] = 0;
        }
        i = @as(usize, app_conf.DSP_BUFFER_SIZE) * 2;
        while (i < @as(usize, fs) * 2) : (i += 1) input_fft[i] = 0;

        arm_cfft_q31(instance, &input_fft, 0, 1);
        arm_cmplx_mult_cmplx_q31(&input_fft, &ir.ir_fft, &output_fft, fs);
        arm_cfft_q31(instance, &output_fft, 1, 1);

        i = 0;
        while (i < fs) : (i += 1) work_buffer[i] = output_fft[i * 2];

        arm_add_q31(&work_buffer, &overlap_buffer, &work_buffer, @intCast(ovl));

        i = 0;
        while (i < ovl) : (i += 1)
            overlap_buffer[i] = work_buffer[app_conf.DSP_BUFFER_SIZE + i];

        const gain_bits = if ((2 * log2n + 2) >= ir.ir_boost_bits)
            (2 * log2n + 2) - ir.ir_boost_bits
        else
            0;

        i = 0;
        while (i < app_conf.DSP_BUFFER_SIZE) : (i += 1) {
            const v: i64 = if (gain_bits <= 16)
                @as(i64, work_buffer[i]) >> @intCast(16 - gain_bits)
            else
                @as(i64, work_buffer[i]) << @intCast(gain_bits - 16);
            out[i] = @intCast(std.math.clamp(v, -32768, 32767));
        }
    }

    pub fn loadIR(ir: []const i32, sample_rate: u32) void {
        if (ir.len == 0) return;

        var actual_len: u32 = @intCast(ir.len);
        if (actual_len > app_conf.IR_MAX_LEN) {
            ove.log.wrn("dsp: IR len {d} > {d}, truncating", .{
                actual_len, app_conf.IR_MAX_LEN,
            });
            actual_len = @intCast(app_conf.IR_MAX_LEN);
        }
        if (sample_rate != app_conf.DSP_RATE) {
            ove.log.wrn("dsp: IR rate {d} != {d}", .{ sample_rate, app_conf.DSP_RATE });
        }

        const active = active_ir.load(.acquire);
        const staging: *IrState = if (active == &state_a) &state_b else &state_a;

        setFftSize(staging, actual_len);
        const instance = staging.fft_instance orelse {
            ove.log.err("dsp: FFT init failed, len {d}", .{actual_len});
            return;
        };

        // Copy IR into scratch for normalisation.
        var i: usize = 0;
        while (i < actual_len) : (i += 1) work_buffer[i] = ir[i];

        // Peak-normalise to ~-15 dB below Q31_MAX (0x16A09E66 ≈ 2^31 / √2 / 2).
        var peak: i32 = 0;
        i = 0;
        while (i < actual_len) : (i += 1) {
            const a = absQ31(work_buffer[i]);
            if (a > peak) peak = a;
        }
        if (peak > 0) {
            i = 0;
            while (i < actual_len) : (i += 1) {
                work_buffer[i] = @intCast(@divTrunc(
                    @as(i64, work_buffer[i]) * 0x16A09E66,
                    @as(i64, peak),
                ));
            }
        }
        i = actual_len;
        while (i < staging.fft_size) : (i += 1) work_buffer[i] = 0;

        // Real → complex (imag=0)
        i = 0;
        while (i < staging.fft_size) : (i += 1) {
            staging.ir_fft[i * 2] = work_buffer[i];
            staging.ir_fft[i * 2 + 1] = 0;
        }

        arm_cfft_q31(instance, &staging.ir_fft, 0, 1);

        // Drop DC — cabinets don't reproduce it.
        staging.ir_fft[0] = 0;
        staging.ir_fft[1] = 0;

        // Headroom boost: shift IR bins up so the peak is just under Q31_MAX.
        // process() subtracts `ir_boost_bits` from the output gain recovery.
        var peak_bin: i32 = 0;
        i = 0;
        while (i < staging.fft_size * 2) : (i += 1) {
            const a = absQ31(staging.ir_fft[i]);
            if (a > peak_bin) peak_bin = a;
        }
        staging.ir_boost_bits = 0;
        if (peak_bin > 0) {
            var shifted: i32 = peak_bin;
            while (shifted <= 0x3FFFFFFF and
                staging.ir_boost_bits < 2 * staging.fft_log2n + 2) : (staging.ir_boost_bits += 1)
            {
                shifted <<= 1;
            }
        }
        if (staging.ir_boost_bits > 0) {
            i = 0;
            while (i < staging.fft_size * 2) : (i += 1) {
                staging.ir_fft[i] <<= @intCast(staging.ir_boost_bits);
            }
        }

        i = 0;
        while (i < staging.overlap_size) : (i += 1) overlap_buffer[i] = 0;

        // Publish: release-store pairs with process()'s acquire-load.
        active_ir.store(staging, .release);

        ove.log.inf(
            "dsp: IR loaded, {d} samples, FFT {d}, boost {d}, gain {d}",
            .{ actual_len, staging.fft_size, staging.ir_boost_bits, 2 * staging.fft_log2n + 2 - staging.ir_boost_bits },
        );
    }
} else struct {};
