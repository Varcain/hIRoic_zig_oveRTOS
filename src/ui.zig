const std = @import("std");
const ove = @import("ove");
const lvgl = ove.lvgl;

const log = std.log.scoped(.hiroic);

var cpu_label: ?lvgl.Label = null;
var ir_label: ?lvgl.Label = null;
var vu_bar: ?lvgl.Bar = null;

pub fn createWidgets(title: [*:0]const u8) void {
    const screen = lvgl.screenActive();

    ove.ffi.lv_obj_set_style_bg_color(screen.obj, lvgl.colorBlack(), 0);

    _ = lvgl.Label.create(screen)
        .text(title)
        .font(lvgl.fontMontserrat32())
        .color(lvgl.colorWhite())
        .pos(10, 10);

    cpu_label = lvgl.Label.create(screen)
        .text("CPU: 0%")
        .font(lvgl.fontMontserrat14())
        .color(lvgl.colorMake(0, 255, 0))
        .pos(10, 55);

    ir_label = lvgl.Label.create(screen)
        .text("IR: none (bypass)")
        .font(lvgl.fontMontserrat14())
        .color(lvgl.colorWhite())
        .pos(10, 80);

    vu_bar = lvgl.Bar.create(screen)
        .range(0, 100)
        .value(0)
        .barColor(lvgl.colorMake(40, 40, 40))
        .indicatorColor(lvgl.colorMake(0, 200, 0))
        .size(200, 12)
        .pos(10, 105);

    log.info("LVGL widgets created", .{});
}

pub fn updateCpu(pct: u32) void {
    const label = cpu_label orelse return;
    var s = ove.String(24).init();
    s.format("CPU: {d}%", .{pct}) catch return;
    const c = s.cStr() catch return;
    _ = label.text(c);
}

pub fn updateIr(name: []const u8, samples: u32) void {
    const label = ir_label orelse return;
    var s = ove.String(96).init();
    s.format("IR: {s} ({d} samples)", .{ name, samples }) catch return;
    const c = s.cStr() catch return;
    _ = label.text(c);
}

pub fn updateVu(peak: i16) void {
    const bar = vu_bar orelse return;
    const level: i32 = if (peak > 0) @intCast((@as(u32, @intCast(peak)) * 100) / 32767) else 0;
    _ = bar.value(level);
}
