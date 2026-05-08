const std = @import("std");
const ove = @import("ove");
const app_conf = @import("app_conf.zig");
const dsp = @import("dsp.zig");
const ir_manager = @import("ir_manager.zig");
const shared = @import("shared.zig");
const ui = @import("ui.zig");

pub fn heartbeatEntry() void {
    while (true) {
        ove.thread.sleepMs(33);
        shared.watchdogFeed();

        const peak = shared.audio_peak.load(.monotonic);
        const guard = ove.lvgl.lock();
        defer guard.deinit();
        ui.updateVu(peak);
    }
}

pub fn graphicsEntry() void {
    var last_us: u64 = 0;
    _ = ove.ffi.ove_time_get_us(&last_us);

    while (true) {
        var now_us: u64 = 0;
        _ = ove.ffi.ove_time_get_us(&now_us);
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

pub fn inputEntry() void {
    while (true) {
        const ch = ove.ffi.ove_console_getchar();
        if (ch >= 0) {
            ove.shell.processChar(@intCast(ch));
        } else {
            ove.thread.sleepMs(25);
        }
    }
}

var ir_buf: [app_conf.IR_MAX_LEN]i32 = undefined;

pub fn loaderEntry() void {
    while (true) {
        const req = if (shared.loader_queue) |q|
            q.receive(ove.wait_forever) catch continue
        else {
            ove.thread.sleepMs(100);
            continue;
        };

        if (shared.events) |evt| _ = evt.setBits(shared.EVT_IR_LOADING);

        const result = switch (req.kind) {
            .by_name => blk: {
                const name = std.mem.sliceTo(&req.filename, 0);
                break :blk ir_manager.loadByName(name, &ir_buf);
            },
            .next => ir_manager.loadNext(&ir_buf),
            .prev => ir_manager.loadPrev(&ir_buf),
        };

        if (result) |c| {
            dsp.loadIR(ir_buf[0..c.length], c.sample_rate);
            const name = ir_manager.currentName();
            ove.log.inf("loader: loaded {d} samples @ {d} Hz", .{ c.length, c.sample_rate });

            {
                const guard = ove.lvgl.lock();
                defer guard.deinit();
                ui.updateIr(name, c.length);
            }

            ove.nvs.write("last_ir", name) catch {};
        } else {
            ove.log.err("loader: load failed", .{});
        }

        if (shared.events) |evt| _ = evt.clearBits(shared.EVT_IR_LOADING);
    }
}
