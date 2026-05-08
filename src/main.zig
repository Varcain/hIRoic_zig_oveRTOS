const std = @import("std");
const ove = @import("ove");

const app_conf = @import("app_conf.zig");
const audio_node = @import("audio_node.zig");
const commands = @import("commands.zig");
const dsp = @import("dsp.zig");
const ir_manager = @import("ir_manager.zig");
const shared = @import("shared.zig");
const threads = @import("threads.zig");
const ui = @import("ui.zig");

const prio = ove.thread.prio;

// Graph outlives appMain(): the audio-I/O threads hold references to it,
// so it needs static storage — same C rule as "don't return a pointer to
// a local".  File-scope `var` keeps it in BSS for the program's lifetime.
var g_graph: ove.audio.Graph = undefined;

fn statsTimerCb() void {
    const deadline_us: u32 = (app_conf.DSP_BUFFER_SIZE * 1_000_000) / app_conf.DSP_RATE;

    ove.led.toggle(0);
    ove.led.toggle(1);

    const count = shared.proc_count.load(.monotonic);
    if (count == 0) return;
    const total = shared.total_proc_us.swap(0, .monotonic);
    shared.proc_count.store(0, .monotonic);
    const avg = total / count;
    const pct: u32 = if (deadline_us > 0) (avg * 100) / deadline_us else 0;

    const guard = ove.lvgl.lock();
    defer guard.deinit();
    ui.updateCpu(pct);
}

fn appMain() void {
    ove.log.inf("hIRoic - Guitar Cabinet IR Convolution (Zig)", .{});
    ove.log.inf("Config: 16-bit, 1 ch, {d} Hz, {d} samples/block", .{
        app_conf.DSP_RATE, app_conf.DSP_BUFFER_SIZE,
    });

    dsp.init();
    ir_manager.init();

    shared.events = ove.EventGroup.create() catch {
        ove.log.err("create event group failed", .{});
        return;
    };
    shared.loader_queue = ove.Queue(shared.IrLoadRequest, 4).create() catch {
        ove.log.err("create queue failed", .{});
        return;
    };
    // Watchdog hardware is optional: a board built without an enabled
    // IWDG/WWDG (NuttX) or `watchdog0` DT alias (Zephyr) returns
    // NotSupported from `_create`/`_init`.  Don't bail out — leave
    // `shared.watchdog = null` so `shared.watchdogFeed()` becomes a
    // no-op and the watchdog `.start()` site below skips cleanly.
    shared.watchdog = ove.Watchdog.create(5000) catch |e| blk: {
        ove.log.wrn("watchdog create failed ({s}); continuing without it", .{@errorName(e)});
        break :blk null;
    };
    shared.stats_timer = ove.Timer.create(statsTimerCb, 1000, .periodic) catch {
        ove.log.err("create stats timer failed", .{});
        return;
    };

    // Audio graph initialised into the file-scope `g_graph` (see the
    // comment on `g_graph` for lifetime reasoning).  Two-phase init
    // via in-place `init(frames_per_period)`; node count, channel count,
    // and sample width are inferred from the per-node `addProcessor` /
    // `deviceSource` / `deviceSink` calls and the cfg passed to them.
    g_graph.init(app_conf.DSP_BUFFER_SIZE) catch {
        ove.log.err("audio graph init failed", .{});
        return;
    };
    const graph = &g_graph;

    const cfg = ove.audio.Graph.deviceCfgI2s(app_conf.DSP_RATE, 1, 0);
    const src_idx = graph.deviceSource(&cfg, "i2s-in") catch {
        ove.log.err("i2s-in source failed", .{});
        return;
    };
    const dsp_idx = graph.addProcessor(
        audio_node.HiroicDsp,
        &audio_node.dsp_node,
        "dsp",
    ) catch {
        ove.log.err("dsp processor failed", .{});
        return;
    };
    const sink_idx = graph.deviceSink(&cfg, "i2s-out") catch {
        ove.log.err("i2s-out sink failed", .{});
        return;
    };
    graph.connect(@intCast(src_idx), @intCast(dsp_idx)) catch {
        ove.log.err("connect src->dsp failed", .{});
        return;
    };
    graph.connect(@intCast(dsp_idx), @intCast(sink_idx)) catch {
        ove.log.err("connect dsp->sink failed", .{});
        return;
    };
    graph.build() catch {
        ove.log.err("audio graph build failed", .{});
        return;
    };

    if (shared.watchdog) |wd| {
        wd.start() catch ove.log.wrn("watchdog start failed", .{});
    }
    shared.stats_timer.?.start() catch ove.log.wrn("stats timer start failed", .{});

    commands.registerAll();
    commands.restoreFromNvs();

    // `ove.Thread(STACK).create(name, entry, prio)` — stack size is a
    // comptime parameter on the template; `create` no longer takes it.
    _ = ove.Thread(2048).create("Heartbeat", threads.heartbeatEntry, prio.high) catch {
        ove.log.err("spawn heartbeat failed", .{});
        return;
    };
    _ = ove.Thread(8192).create("Graphics", threads.graphicsEntry, prio.normal) catch {
        ove.log.err("spawn graphics failed", .{});
        return;
    };
    _ = ove.Thread(4096).create("Inputs", threads.inputEntry, prio.above_normal) catch {
        ove.log.err("spawn inputs failed", .{});
        return;
    };
    _ = ove.Thread(8192).create("Loader", threads.loaderEntry, prio.high) catch {
        ove.log.err("spawn loader failed", .{});
        return;
    };

    ove.lvgl.init() catch {
        ove.log.wrn("lvgl: init failed (UI disabled)", .{});
    };
    {
        const guard = ove.lvgl.lock();
        defer guard.deinit();
        ui.createWidgets("hIRoic");
    }

    graph.start() catch {
        ove.log.err("audio graph start failed", .{});
        return;
    };

    ove.log.inf("init: done", .{});

    ove.run();

    graph.stop() catch {};
}

comptime {
    ove.exportMain(appMain);
}
