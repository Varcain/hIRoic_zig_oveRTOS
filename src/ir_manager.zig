//! IR manager — SD card enumeration and IR loading.
//!
//! Shared state is owned exclusively by the loader thread.

const std = @import("std");
const ove = @import("ove");
const app_conf = @import("app_conf.zig");
const wav = @import("wav_parser.zig");
const ir_convert = @import("ir_convert.zig");

const log = std.log.scoped(.hiroic);

// Cortex-M7 cache-line alignment is required for SDMMC DMA: Zephyr's
// STM32 SDMMC driver does sys_cache_data_invd_range() over the user
// buffer after each DMA read, which corrupts adjacent globals living
// on the same 32-byte line if the buffer is unaligned (see comment in
// zephyr/drivers/disk/sdmmc_stm32.c, and the matching `alignas(32)`
// fix on the C++ port at hiroic_cpp/src/ir_manager.cpp).
var wav_buf: [app_conf.WAV_BUF_MAX_LEN]u8 align(32) = undefined;
var current_name: [64]u8 = [_]u8{0} ** 64;
var available: bool = false;

pub fn init() void {
    ove.fs.mount("", "") catch {
        log.warn("ir_mgr: fs mount failed (SD not available)", .{});
        return;
    };
    const default = "default";
    @memcpy(current_name[0..default.len], default);
    current_name[default.len] = 0;
    available = true;
    log.info("ir_mgr: ready", .{});
}

pub fn isAvailable() bool {
    return available;
}

fn nullTermLen(buf: []const u8) usize {
    for (buf, 0..) |c, i| {
        if (c == 0) return i;
    }
    return buf.len;
}

pub fn currentName() []const u8 {
    return current_name[0..nullTermLen(&current_name)];
}

fn setCurrent(name: []const u8) void {
    const n = @min(name.len, current_name.len - 1);
    @memcpy(current_name[0..n], name[0..n]);
    current_name[n] = 0;
    @memset(current_name[n + 1 ..], 0);
}

fn loadFile(name: []const u8, size: usize, ir: []i32) ?ir_convert.Converted {
    // Build a null-terminated path (File.open expects a C string).
    var path = ove.String(80).init();
    const copy_len = @min(name.len, path.bytes.len - 1);
    path.appendSlice(name[0..copy_len]) catch return null;
    const path_z = path.cStr() catch return null;

    var file = ove.fs.File.open(path_z, ove.fs.O_READ) catch {
        log.err("ir_mgr: open failed", .{});
        return null;
    };
    defer file.close();

    const read_cap = @min(@as(usize, size), wav_buf.len);
    const bytes_read = file.read(wav_buf[0..read_cap]) catch return null;

    const parsed = wav.parse(wav_buf[0..bytes_read]) catch return null;
    const converted = ir_convert.convertSamples(parsed, ir) catch return null;
    setCurrent(name);
    return converted;
}

pub fn count() u32 {
    if (!available) return 0;
    var dir = ove.fs.Dir.open("/") catch return 0;
    defer dir.close();

    var n: u32 = 0;
    while (dir.readEntry() catch null) |entry| {
        const name = std.mem.sliceTo(&entry.name, 0);
        if (ir_convert.isWav(name)) n += 1;
    }
    return n;
}

pub fn loadByName(name: []const u8, ir: []i32) ?ir_convert.Converted {
    if (!available) return null;
    const name_nz = name[0..nullTermLen(name)];

    var dir = ove.fs.Dir.open("/") catch return null;
    defer dir.close();

    while (dir.readEntry() catch null) |entry| {
        const ename = std.mem.sliceTo(&entry.name, 0);
        if (std.mem.eql(u8, ename, name_nz)) {
            return loadFile(ename, entry.size, ir);
        }
    }
    return null;
}

pub fn loadNext(ir: []i32) ?ir_convert.Converted {
    if (!available) return null;
    const cur = currentName();

    var dir = ove.fs.Dir.open("/") catch return null;
    defer dir.close();

    var after = false;
    var first_name: [64]u8 = [_]u8{0} ** 64;
    var first_size: usize = 0;
    var have_first = false;

    while (dir.readEntry() catch null) |entry| {
        const ename = std.mem.sliceTo(&entry.name, 0);
        if (!ir_convert.isWav(ename)) continue;

        if (!have_first) {
            const n = @min(ename.len, first_name.len - 1);
            @memcpy(first_name[0..n], ename[0..n]);
            first_name[n] = 0;
            first_size = entry.size;
            have_first = true;
        }
        if (after) return loadFile(ename, entry.size, ir);
        if (std.mem.eql(u8, ename, cur)) after = true;
    }
    if (have_first) {
        const fname = std.mem.sliceTo(&first_name, 0);
        return loadFile(fname, first_size, ir);
    }
    return null;
}

pub fn loadPrev(ir: []i32) ?ir_convert.Converted {
    if (!available) return null;
    const cur = currentName();

    var dir = ove.fs.Dir.open("/") catch return null;
    defer dir.close();

    var prev_name: [64]u8 = [_]u8{0} ** 64;
    var prev_size: usize = 0;
    var have_prev = false;
    var last_name: [64]u8 = [_]u8{0} ** 64;
    var last_size: usize = 0;
    var have_last = false;
    var found = false;

    while (dir.readEntry() catch null) |entry| {
        const ename = std.mem.sliceTo(&entry.name, 0);
        if (!ir_convert.isWav(ename)) continue;

        if (!found and std.mem.eql(u8, ename, cur)) {
            found = true;
            continue;
        }
        if (!found) {
            const n = @min(ename.len, prev_name.len - 1);
            @memcpy(prev_name[0..n], ename[0..n]);
            prev_name[n] = 0;
            prev_size = entry.size;
            have_prev = true;
        }
        const n = @min(ename.len, last_name.len - 1);
        @memcpy(last_name[0..n], ename[0..n]);
        last_name[n] = 0;
        last_size = entry.size;
        have_last = true;
    }

    if (have_prev) return loadFile(std.mem.sliceTo(&prev_name, 0), prev_size, ir);
    if (have_last) return loadFile(std.mem.sliceTo(&last_name, 0), last_size, ir);
    return null;
}
