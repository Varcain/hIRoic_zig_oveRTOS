const std = @import("std");
const ove = @import("ove");

const shared = @import("shared.zig");
const ir_manager = @import("ir_manager.zig");

fn queueRequest(kind: shared.LoadType, name: ?[]const u8) void {
    var req: shared.IrLoadRequest = .{
        .kind = kind,
        .filename = [_]u8{0} ** 64,
    };
    if (name) |src| {
        const n = @min(src.len, req.filename.len - 1);
        @memcpy(req.filename[0..n], src[0..n]);
    }
    if (shared.loader_queue) |q| {
        q.send(&req, 0) catch {};
    }
}

fn cmdLoad(argc: c_int, argv: [*c]const [*c]const u8) void {
    if (argc < 2) {
        ove.log.inf("usage: load <filename>", .{});
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
    ove.log.inf("bypass: {s}", .{if (want) "ON" else "OFF"});

    const val: u8 = if (want) @intCast(shared.EVT_IR_BYPASS) else 0;
    ove.nvs.write("bypass", &.{val}) catch {};
}

fn cmdStats(_: c_int, _: [*c]const [*c]const u8) void {
    ove.log.inf("stats: count={d} overrun={d} rx_peak={d} tx_peak={d}", .{
        shared.proc_count.load(.monotonic),
        shared.overrun_count.load(.monotonic),
        shared.rx_peak.load(.monotonic),
        shared.audio_peak.load(.monotonic),
    });
}

fn cmdList(_: c_int, _: [*c]const [*c]const u8) void {
    if (!ir_manager.isAvailable()) {
        ove.log.inf("list: SD card not mounted", .{});
        return;
    }
    ove.log.inf("Found {d} WAV files", .{ir_manager.count()});
}

pub fn registerAll() void {
    ove.shell.init() catch {};
    ove.shell.registerCmd("load", "<file> - load IR by name", cmdLoad) catch {};
    ove.shell.registerCmd("next", "load next IR", cmdNext) catch {};
    ove.shell.registerCmd("prev", "load previous IR", cmdPrev) catch {};
    ove.shell.registerCmd("bypass", "toggle DSP bypass", cmdBypass) catch {};
    ove.shell.registerCmd("stats", "print DSP stats", cmdStats) catch {};
    ove.shell.registerCmd("list", "list WAVs", cmdList) catch {};
    ove.log.inf("shell: 6 commands registered", .{});
}

pub fn restoreFromNvs() void {
    ove.nvs.init() catch {};

    var bypass_val: [1]u8 = .{0};
    if (ove.nvs.read("bypass", &bypass_val)) |n| {
        if (n > 0 and (bypass_val[0] & @as(u8, @intCast(shared.EVT_IR_BYPASS))) != 0) {
            if (shared.events) |evt| _ = evt.setBits(shared.EVT_IR_BYPASS);
            ove.log.inf("nvs: restored bypass=ON", .{});
        }
    } else |_| {}

    var saved: [64]u8 = [_]u8{0} ** 64;
    if (ove.nvs.read("last_ir", &saved)) |n| {
        if (n > 0) {
            const slice = saved[0..@min(n, saved.len)];
            ove.log.inf("nvs: would restore last_ir", .{});
            queueRequest(.by_name, slice);
        }
    } else |_| {}
}
