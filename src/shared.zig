const std = @import("std");
const ove = @import("ove");

pub const EVT_IR_LOADING: u32 = 1 << 0;
pub const EVT_IR_BYPASS: u32 = 1 << 1;

pub const LoadType = enum(u8) {
    next = 0,
    prev = 1,
    by_name = 2,
};

pub const IrLoadRequest = extern struct {
    kind: LoadType,
    filename: [64]u8,
};

pub var events: ?ove.EventGroup = null;
pub var loader_queue: ?ove.Queue(IrLoadRequest, 4) = null;
pub var watchdog: ?ove.Watchdog = null;
pub var stats_timer: ?ove.Timer = null;

pub var total_proc_us: std.atomic.Value(u32) = std.atomic.Value(u32).init(0);
pub var proc_count: std.atomic.Value(u32) = std.atomic.Value(u32).init(0);
pub var overrun_count: std.atomic.Value(u32) = std.atomic.Value(u32).init(0);
pub var audio_peak: std.atomic.Value(i16) = std.atomic.Value(i16).init(0);
pub var rx_peak: std.atomic.Value(i16) = std.atomic.Value(i16).init(0);

pub fn watchdogFeed() void {
    if (watchdog) |wd| wd.feed() catch {};
}
