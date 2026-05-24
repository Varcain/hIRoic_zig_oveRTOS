const std = @import("std");
const ove = @import("ove");

const shared = @import("shared.zig");
const ir_manager = @import("ir_manager.zig");

const log = std.log.scoped(.hiroic);

fn queueRequest(kind: shared.LoadType, name: ?[]const u8) void {
    var req: shared.IrLoadRequest = .{
        .kind = kind,
        .filename = [_]u8{0} ** 64,
    };
    if (name) |src| {
        const n = @min(src.len, req.filename.len - 1);
        @memcpy(req.filename[0..n], src[0..n]);
    }
    const q = shared.loader_queue orelse return;
    // `trySend` is the non-blocking variant — mirrors the C reference's
    // `ove_queue_send(..., 0)`.  Forever-blocking `send` is wrong from
    // a shell-command context: it would lock the input thread if the
    // loader thread fell behind.
    q.trySend(&req) catch log.warn("loader queue full, drop request", .{});
}

fn cmdLoad(argc: c_int, argv: [*c]const [*c]const u8) void {
    if (argc < 2) {
        log.info("usage: load <filename>", .{});
        return;
    }
    const name = std.mem.span(argv[1]);
    queueRequest(.by_name, name);
}

fn cmdNext(_: c_int, _: [*c]const [*c]const u8) void {
    queueRequest(.next, null);
}

fn cmdPrev(_: c_int, _: [*c]const [*c]const u8) void {
    queueRequest(.prev, null);
}

fn cmdBypass(_: c_int, _: [*c]const [*c]const u8) void {
    const evt = shared.events orelse return;
    const bits = evt.getBits();
    const want = (bits & shared.EVT_IR_BYPASS) == 0;
    if (want) {
        _ = evt.setBits(shared.EVT_IR_BYPASS);
    } else {
        _ = evt.clearBits(shared.EVT_IR_BYPASS);
    }
    log.info("bypass: {s}", .{if (want) "ON" else "OFF"});

    const val: u8 = if (want) @intCast(shared.EVT_IR_BYPASS) else 0;
    ove.nvs.write("bypass", &.{val}) catch {};
}

fn cmdStats(_: c_int, _: [*c]const [*c]const u8) void {
    const app_conf = @import("app_conf.zig");
    const deadline_us: u32 = (app_conf.DSP_BUFFER_SIZE * 1_000_000) / app_conf.DSP_RATE;
    const count = shared.proc_count.load(.monotonic);
    const total = shared.total_proc_us.load(.monotonic);
    const avg_us: u32 = if (count > 0) total / count else 0;
    const pct: u32 = if (deadline_us > 0) (avg_us * 100) / deadline_us else 0;
    log.info("DSP {d}.{d:0>3}/{d}.{d:0>3} ms ({d}%) count={d} rx={d} tx={d}", .{
        avg_us / 1000,      avg_us % 1000,
        deadline_us / 1000, deadline_us % 1000,
        pct,                count,
        shared.rx_peak.load(.monotonic),
        shared.audio_peak.load(.monotonic),
    });
}

fn cmdList(_: c_int, _: [*c]const [*c]const u8) void {
    if (!ir_manager.isAvailable()) {
        log.info("list: SD card not mounted", .{});
        return;
    }
    log.info("Found {d} WAV files", .{ir_manager.count()});
}

pub fn registerAll() void {
    ove.shell.init() catch {};
    ove.shell.registerCmd("load", "<file> - load IR by name", cmdLoad) catch {};
    ove.shell.registerCmd("next", "load next IR", cmdNext) catch {};
    ove.shell.registerCmd("prev", "load previous IR", cmdPrev) catch {};
    ove.shell.registerCmd("bypass", "toggle DSP bypass", cmdBypass) catch {};
    ove.shell.registerCmd("stats", "print DSP stats", cmdStats) catch {};
    ove.shell.registerCmd("list", "list WAVs", cmdList) catch {};
    log.info("shell: 6 commands registered", .{});
}

pub fn restoreFromNvs() void {
    ove.nvs.init() catch {};

    var bypass_val: [1]u8 = .{0};
    if (ove.nvs.read("bypass", &bypass_val)) |n| {
        if (n > 0 and (bypass_val[0] & @as(u8, @intCast(shared.EVT_IR_BYPASS))) != 0) {
            if (shared.events) |evt| _ = evt.setBits(shared.EVT_IR_BYPASS);
            log.info("nvs: restored bypass=ON", .{});
        }
    } else |_| {}

    var saved: [64]u8 = [_]u8{0} ** 64;
    if (ove.nvs.read("last_ir", &saved)) |n| {
        if (n > 0) {
            const slice = saved[0..@min(n, saved.len)];
            log.info("nvs: restoring last_ir", .{});
            queueRequest(.by_name, slice);
        }
    } else |_| {}
}
