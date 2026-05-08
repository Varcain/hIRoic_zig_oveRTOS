# hIRoic — Guitar Cabinet IR Convolution on oveRTOS (Zig)

Zig port of the hIRoic real-time guitar cabinet impulse response (IR)
convolution app, built on the [oveRTOS](https://github.com/varcain/oveRTOS)
RTOS abstraction framework.  Same audio pipeline and feature set as the
[C variant](../hiroic/README.md), exercised through the typed Zig `ove`
module.  Runs on the STM32F746G-Discovery board across FreeRTOS, Apache
NuttX, and Zephyr — and on the host POSIX simulator — from a single
codebase with zero comptime branches on RTOS at the use site.

## What it does

- **Real-time audio convolution** — FFT-based overlap-add processing
  using ARM CMSIS-DSP, applying cabinet impulse responses to a live
  audio stream at 44.1 kHz / 16-bit mono.
- **SD card IR management** — enumerates `.wav` files on an SD card,
  loads and converts them to the internal IR format on the fly.
- **LVGL touch UI** — displays current IR name, CPU load, and a live
  VU meter on the on-board LCD.
- **Shell CLI** — serial commands for loading IRs, toggling bypass,
  viewing stats, and listing available files.
- **Persistent settings** — last-used IR and bypass state are saved to
  non-volatile storage and restored on boot.

## Architecture

```
┌─────────────────────────────────────────────────────────┐
│  appMain()                                              │
│  ┌─────────┐ ┌───────────┐ ┌────────┐ ┌──────────────┐  │
│  │ Audio   │ │ Event     │ │ Queue  │ │ Timer        │  │
│  │ graph   │ │ group     │ │ (IR    │ │ (stats 1Hz)  │  │
│  │         │ │ (bypass/  │ │  load  │ │              │  │
│  │         │ │  loading) │ │  reqs) │ │              │  │
│  └─────────┘ └───────────┘ └────────┘ └──────────────┘  │
│                                                         │
│  Threads:                                               │
│  ┌────────────┐ ┌──────────┐ ┌───────┐ ┌─────────────┐  │
│  │ Heartbeat  │ │ Graphics │ │ Input │ │ Loader      │  │
│  │ (HIGH)     │ │ (NORMAL) │ │(ABOVE │ │ (HIGH)      │  │
│  │ WDT feed,  │ │ LVGL     │ │NORMAL)│ │ SD card I/O │  │
│  │ VU meter   │ │ tick/    │ │ shell │ │ via queue   │  │
│  │ 30 fps     │ │ handler  │ │ chars │ │             │  │
│  └────────────┘ └──────────┘ └───────┘ └─────────────┘  │
│                                                         │
│  Audio graph node:  hiroicDspProcess()                  │
│                     DSP convolution / bypass            │
└─────────────────────────────────────────────────────────┘
```

## Zig binding usage

The app imports `const ove = @import("ove");` for the typed wrapper
layer at `bindings/zig/ove`.  Highlights:

- **Comptime-parameterised RTOS objects**: `ove.Queue(T, N)`,
  `ove.Thread(stack_size)`, `ove.Workqueue(stack_size)`,
  `ove.Stream(byte_capacity)` — capacity is a comptime parameter, the
  wrapper constructs the kernel object via the heap-mode `_create()`
  / `_destroy()` API.  The allocation mode is fixed in `app.yaml`'s
  `defconfig:` — switching to zero-heap is not a drop-in change for
  hIRoic-zig; it would require reworking the dynamic IR-loading flow
  to use caller-supplied static storage.
- **Containers**: `ove.String(N)` with `cStr()` for null-terminated
  handoff to LVGL / `File.open`; `ove.Vec(T, N)` for fixed-capacity
  buffers; or `ove.fixedBufferAlloc(buf)` to back stdlib
  `std.*Unmanaged` containers without ever touching the heap.
- **Errors as values**: every fallible call returns `ove.Error!T`;
  panics only fire in debug-build pinning checks.

App entry:

```zig
comptime { ove.exportMain(appMain); }  // emits ove_main symbol
```

## oveRTOS modules exercised

Same 15 oveRTOS modules as the C variant — see
[../hiroic/README.md](../hiroic/README.md#overtos-apis-exercised) for
the full table.  Notable Zig-specific surface:

| Module | Zig binding usage |
|---|---|
| **Containers** | `ove.String(80)` with `.cStr()` for the path buffer passed to `ove.fs.File.open`; `ove.String(96)` for LVGL label formatting via `.format(...)` |
| **Threading** | `ove.Thread(stack_size)` returns the type; `try th.init(...)`-then-`defer th.deinit()` shape |
| **Queue** | `ove.Queue(IrLoadRequest, 4)` — element type and depth as comptime params |
| **Static state** | File-scope `var` for kernel-object storage, with `linksection(".dsp_bss")` on FFT working buffers to keep them out of the data segment |
| **Audio graph** | `ove.audio.Graph` + `device_source / add_processor / device_sink` chain in `appMain` |

## Shell commands

| Command | Description |
|---------|-------------|
| `help` | List available commands |
| `load <file>` | Load a specific IR WAV file by name |
| `next` | Load the next IR on the SD card |
| `prev` | Load the previous IR |
| `bypass` | Toggle DSP bypass (pass audio through) |
| `stats` | Show DSP timing, peak levels, overrun count |
| `list` | List WAV files on the SD card |

## Building

hIRoic-zig is an **external oveRTOS application**.  The Makefile
delegates to oveRTOS via the `ove` CLI; configuration is fragment-based,
picked up from a `<board>.<rtos>.<app>` target name.

```bash
# From the hiroic_zig app directory.  OVE_DIR defaults to ../../oveRTOS
# (see Makefile); override if your layout differs.
export OVE_DIR=/path/to/oveRTOS

# 1. Pick a (board, rtos) target.  hIRoic-zig is heap-mode only — the
#    allocation mode is fixed in app.yaml's defconfig.
make stm32f746g-discovery.freertos.hiroic_zig              # FreeRTOS
make stm32f746g-discovery.nuttx.hiroic_zig                 # NuttX
make stm32f746g-discovery.zephyr.hiroic_zig                # Zephyr
make host.posix.hiroic_zig                                 # Host simulator

# 2. Build (downloads sources on first run — including the pinned Zig
#    toolchain — configures, then compiles).
make

# 3. Flash to the board.
make flash
```

`make` (no args) is shorthand for `download && configure && build`.
`make run` invokes the board's run target where applicable (host POSIX
simulator, QEMU).  `make clean` removes the workspace under `output/`.

### Other useful targets

| Target | Purpose |
|---|---|
| `make menuconfig` | Tweak the resolved `.config` interactively |
| `make savedefconfig` | Snapshot the current config to a defconfig file |
| `make lint` / `make format` | Run / apply `zig fmt`, `zig ast-check`, clang-format, etc. (covers this external app via `OVE_EXTERNAL_APPS`, set automatically by the Makefile) |
| `make help` | Print the full target list and any saved defconfigs |

### Supported configurations

| Board | RTOS | Status |
|-------|------|--------|
| stm32f746g-discovery | freertos | yes |
| stm32f746g-discovery | nuttx    | yes |
| stm32f746g-discovery | zephyr   | yes |
| host                 | posix    | yes |

All configurations are heap-mode (oveRTOS `_create()` / `_destroy()`
API).  Zero-heap is not a supported configuration for hIRoic-zig.

## DSP details

The convolution engine (`src/dsp.zig`) uses ARM CMSIS-DSP via the
`ove.ffi` raw bindings for FFT-based overlap-add processing:

- **FFT size**: auto-selected (next power of 2 above IR length)
- **Sample rate**: 44100 Hz
- **Frame size**: 512 samples (~11.6 ms latency)
- **Format**: 16-bit signed mono (Q15 fixed-point internally)
- **IR hot-swap**: double-buffered with atomic pointer swap — no audio
  glitches during IR loading
- **DSP working buffers**: `linksection(".dsp_bss") = undefined` to
  pin large FFT scratch into the dedicated BSS section the linker
  script assigns to fast TCM / SRAM where available

The DSP path falls back to a software-only passthrough on host/POSIX
builds where CMSIS-DSP is unavailable.

## License

GPL-3.0-or-later.  See the SPDX headers in each source file.
