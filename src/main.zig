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

// Wire `std.log.*` calls through ove_console_write so module code can
// use the standard library facade (`const log = std.log.scoped(...)`)
// instead of a custom logger.
pub const std_options: std.Options = .{
    .logFn = ove.log.logFn,
};

const log = std.log.scoped(.hiroic);

// Graph outlives appMain(): the audio-I/O threads hold references to it,
// so it needs static storage — same Zig rule as "don't return a pointer
// to a local".  File-scope `var` keeps it in BSS for the program's
// lifetime.
var g_graph: ove.audio.Graph = undefined;

// Threads also outlive appMain.  Their backing storage (TCB + stack)
// is allocator-owned and freed in `Thread.deinit`; we keep the
// wrapper values at file scope so they don't go out of scope and
// trigger deinit while the program is still running.
var g_heartbeat_th: ove.Thread(2048) = undefined;
var g_graphics_th: ove.Thread(8192) = undefined;
var g_input_th: ove.Thread(4096) = undefined;
var g_loader_th: ove.Thread(8192) = undefined;

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
    // All RTOS primitives that need an allocator (Queue, Timer, Thread,
    // EventGroup, …) take a `std.mem.Allocator`.  Under heap mode use
    // the libc-backed allocator; zero-heap requires a static-backed
    // FixedBufferAllocator, which we set up via comptime cfg in a
    // follow-up.  hIRoic is heap-mode only (per app.yaml).
    const allocator = ove.allocators.c_allocator;

    log.info("hIRoic - Guitar Cabinet IR Convolution (Zig)", .{});
    log.info("Config: 16-bit, 1 ch, {d} Hz, {d} samples/block", .{
        app_conf.DSP_RATE, app_conf.DSP_BUFFER_SIZE,
    });

    dsp.init();
    ir_manager.init();

    shared.events = ove.EventGroup.create(allocator) catch {
        log.err("create event group failed", .{});
        return;
    };
    shared.loader_queue = ove.Queue(shared.IrLoadRequest, 4).create(allocator) catch {
        log.err("create queue failed", .{});
        return;
    };
    // Watchdog hardware is optional: a board built without an enabled
    // IWDG/WWDG (NuttX) or `watchdog0` DT alias (Zephyr) returns
    // NotSupported from `_create`.  Don't bail out — leave
    // `shared.watchdog = null` so `shared.watchdogFeed()` becomes a
    // no-op and the watchdog `.start()` site below skips cleanly.
    shared.watchdog = ove.Watchdog.create(5000) catch |e| blk: {
        log.warn("watchdog create failed ({s}); continuing without it", .{@errorName(e)});
        break :blk null;
    };
    shared.stats_timer = ove.Timer.create(
        allocator,
        .{ .period_ms = 1000, .mode = .periodic },
        statsTimerCb,
        .{},
    ) catch {
        log.err("create stats timer failed", .{});
        return;
    };

    // Audio graph initialised into the file-scope `g_graph` (see the
    // comment on `g_graph` for lifetime reasoning).  Two-phase init
    // via in-place `init(frames_per_period)`; node count, channel count,
    // and sample width are inferred from the per-node `addProcessor` /
    // `deviceSource` / `deviceSink` calls and the cfg passed to them.
    g_graph.init(app_conf.DSP_BUFFER_SIZE) catch {
        log.err("audio graph init failed", .{});
        return;
    };

    const cfg = ove.audio.Graph.deviceCfgI2s(app_conf.DSP_RATE, 1, 0);
    const src_idx = g_graph.deviceSource(&cfg, "i2s-in") catch {
        log.err("i2s-in source failed", .{});
        return;
    };
    const dsp_idx = g_graph.addProcessor(
        audio_node.HiroicDsp,
        &audio_node.dsp_node,
        "dsp",
    ) catch {
        log.err("dsp processor failed", .{});
        return;
    };
    const sink_idx = g_graph.deviceSink(&cfg, "i2s-out") catch {
        log.err("i2s-out sink failed", .{});
        return;
    };
    g_graph.connect(@intCast(src_idx), @intCast(dsp_idx)) catch {
        log.err("connect src->dsp failed", .{});
        return;
    };
    g_graph.connect(@intCast(dsp_idx), @intCast(sink_idx)) catch {
        log.err("connect dsp->sink failed", .{});
        return;
    };
    g_graph.build() catch {
        log.err("audio graph build failed", .{});
        return;
    };

    if (shared.watchdog) |wd| {
        wd.start() catch log.warn("watchdog start failed", .{});
    }
    if (shared.stats_timer) |t| {
        t.start() catch log.warn("stats timer start failed", .{});
    }

    commands.registerAll();
    commands.restoreFromNvs();

    // Cooperative-cancellation workers — entry functions take a
    // `StopToken` so they exit cleanly if `deinit` is ever called.
    g_heartbeat_th = ove.Thread(2048).spawn(
        allocator,
        .{ .name = "Heartbeat", .priority = .high },
        threads.heartbeatEntry,
        .{},
    ) catch {
        log.err("spawn heartbeat failed", .{});
        return;
    };
    g_graphics_th = ove.Thread(8192).spawn(
        allocator,
        .{ .name = "Graphics", .priority = .normal },
        threads.graphicsEntry,
        .{},
    ) catch {
        log.err("spawn graphics failed", .{});
        return;
    };
    g_input_th = ove.Thread(4096).spawn(
        allocator,
        .{ .name = "Inputs", .priority = .above_normal },
        threads.inputEntry,
        .{},
    ) catch {
        log.err("spawn inputs failed", .{});
        return;
    };
    g_loader_th = ove.Thread(8192).spawn(
        allocator,
        .{ .name = "Loader", .priority = .high },
        threads.loaderEntry,
        .{},
    ) catch {
        log.err("spawn loader failed", .{});
        return;
    };

    ove.lvgl.init() catch {
        log.warn("lvgl: init failed (UI disabled)", .{});
    };
    {
        const guard = ove.lvgl.lock();
        defer guard.deinit();
        ui.createWidgets("hIRoic");
    }

    // Start the audio graph LAST.  On Zephyr the SAI driver uses one-
    // shot DMA: if the TX queue drains before the audio thread gets CPU
    // time (e.g. because main is still running higher-priority init
    // work like LVGL setup), the RX clock dies too.  Matching the C
    // reference's "start_graph immediately before scheduler" ordering
    // avoids the race.
    g_graph.start() catch {
        log.err("audio graph start failed", .{});
        return;
    };

    log.info("init: done", .{});

    ove.run();
}

comptime {
    ove.exportMain(appMain);
}
