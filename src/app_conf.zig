//! Application-wide configuration constants.
//!
//! Defaults mirror the Kconfig defaults in `app.yaml`.  A future build-time
//! hook could parse `ove_config.h` to pick up menuconfig overrides.

pub const DSP_BUFFER_SIZE: u32 = 512;
pub const DSP_BITSIZE: u32 = 32;
pub const DSP_RATE: u32 = 44100;
pub const IR_MAX_LEN: usize = 1048;
pub const WAV_BUF_MAX_LEN: usize = (IR_MAX_LEN + 64) * 4;
