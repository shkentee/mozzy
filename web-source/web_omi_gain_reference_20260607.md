# OMI Mic Gain Reference

Source: web-source
Date checked: 2026-06-07 JST

Official repository checked: `BasedHardware/omi`

## OMI DevKit2 Fixed Firmware

Files checked:

- `omi/firmware/devkit/src/config.h`
- `omi/firmware/devkit/src/mic.c`

Findings:

- `config.h` defines `MIC_GAIN 64`.
- `mic.c` assigns `MIC_GAIN` to both `pdm_config.gain_l` and `pdm_config.gain_r`.

## Current OMI Firmware Mic Gain Service

Files checked:

- `omi/firmware/omi/src/lib/core/config.h`
- `omi/firmware/omi/src/lib/core/transport.c`
- `omi/firmware/omi/src/settings.c`
- `omi/firmware/omi/src/mic.c`

Findings:

- Settings service UUID: `19B10010-E8F2-537E-4F6C-D104768A1214`
- Mic gain characteristic UUID: `19B10012-E8F2-537E-4F6C-D104768A1214`
- The app writes and reads one byte as mic gain level.
- `settings.c` default mic gain level is `6`.
- `mic.c` maps levels to Nordic PDM gain bytes:

| Level | Label | PDM gain |
| --: | --- | ---: |
| 0 | Mute | `0x00` |
| 1 | `-20dB` | `0x14` |
| 2 | `-10dB` | `0x1E` |
| 3 | `+0dB` | `0x28` |
| 4 | `+6dB` | `0x2E` |
| 5 | `+10dB` | `0x32` |
| 6 | `+20dB` | `0x3C` |
| 7 | `+30dB` | `0x46` |
| 8 | `+40dB` | `0x50` |

Note:

- DevKit2 fixed `MIC_GAIN 64` is `0x40`, between current OMI levels 6 (`0x3C`) and 7 (`0x46`).
