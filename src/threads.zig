const std = @import("std");
const ove = @import("ove");
const app_conf = @import("app_conf.zig");
const dsp = @import("dsp.zig");
const ir_manager = @import("ir_manager.zig");
const shared = @import("shared.zig");
const ui = @import("ui.zig");

const log = std.log.scoped(.hiroic);

pub fn heartbeatEntry(stop: ove.StopToken) void {
    while (!stop.isStopped()) {
        ove.thread.sleepMs(33);
        shared.watchdogFeed();

        const peak = shared.audio_peak.load(.monotonic);
        const guard = ove.lvgl.lock();
        defer guard.deinit();
        ui.updateVu(peak);
    }
}

pub fn graphicsEntry(stop: ove.StopToken) void {
    var last_us = ove.time.getUs() catch 0;

    while (!stop.isStopped()) {
        const now_us = ove.time.getUs() catch last_us;
        const elapsed_ms: u32 = @intCast((now_us - last_us) / 1000);
        last_us = now_us;

        {
            const guard = ove.lvgl.lock();
            defer guard.deinit();
            ove.lvgl.tick(elapsed_ms);
            ove.lvgl.handler();
        }

        ove.thread.sleepMs(33);
    }
}

pub fn inputEntry(stop: ove.StopToken) void {
    while (!stop.isStopped()) {
        if (ove.console.getchar()) |ch| {
            ove.shell.processChar(ch);
        } else {
            ove.thread.sleepMs(25);
        }
    }
}

/// IR buffer is owned exclusively by the loader thread.  File-static so
/// it survives across iterations without going through the stack.
var ir_buf: [app_conf.IR_MAX_LEN]i32 = undefined;

pub fn loaderEntry(stop: ove.StopToken) void {
    while (!stop.isStopped()) {
        const q = shared.loader_queue orelse {
            ove.thread.sleepMs(100);
            continue;
        };
        // `recv()` is the forever-blocking variant — replaces the
        // legacy `receive(WAIT_FOREVER)` call.  Cooperative shutdown
        // would have to drain the queue, but hiroic runs the loader
        // for the program's lifetime so a stuck-in-recv() worker on
        // teardown is acceptable.
        const req = q.recv();

        if (shared.events) |evt| _ = evt.setBits(shared.EVT_IR_LOADING);

        // Retry up to 3x on transient SD failures.  The Zephyr STM32
        // SDMMC driver occasionally returns -EIO under bus contention
        // (SDMMC and SAI share DMA2); a brief backoff almost always
        // gets the next read through.
        var attempt: u8 = 0;
        const result = while (attempt < 3) : (attempt += 1) {
            const r = switch (req.kind) {
                .by_name => blk: {
                    const name = std.mem.sliceTo(&req.filename, 0);
                    break :blk ir_manager.loadByName(name, &ir_buf);
                },
                .next => ir_manager.loadNext(&ir_buf),
                .prev => ir_manager.loadPrev(&ir_buf),
            };
            if (r != null) break r;
            if (attempt + 1 < 3) ove.thread.sleepMs(50);
        } else null;

        if (result) |c| {
            dsp.loadIR(ir_buf[0..c.length], c.sample_rate);
            const name = ir_manager.currentName();
            log.info("loader: loaded {d} samples @ {d} Hz", .{ c.length, c.sample_rate });

            {
                const guard = ove.lvgl.lock();
                defer guard.deinit();
                ui.updateIr(name, c.length);
            }

            ove.nvs.write("last_ir", name) catch {};
        } else {
            log.err("loader: load failed", .{});
        }

        if (shared.events) |evt| _ = evt.clearBits(shared.EVT_IR_LOADING);
    }
}
