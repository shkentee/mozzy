# Zephyr patches

Out-of-tree fixes that must be applied to the vendored Zephyr source before
building. These live here (not in the SDK tree) so they survive `west update`.

## 0001-sd-fix-ctrl-sync-missing-break.patch

Fixes `subsys/sd/sd_ops.c` `card_ioctl()`: the `DISK_IOCTL_CTRL_SYNC` case had
no `break;` and fell through to `default:`, so CTRL_SYNC always returned
`-ENOTSUP`. FatFS `f_sync()` (run by every `fs_sync`/`fs_close`) maps that to
`FR_DISK_ERR` -> `-EIO`, producing the recurring `fs: file close error (-5)` /
`selftest: fs_sync returned -5` logs. Data writes do not use this ioctl, so
recordings were always intact — the error was spurious. One-line fix; verified
on 2026-05-26 (no -5 across boot selftest + many recorder checkpoints).

Upstream base: Zephyr `100befc7` (NCS v2.7.0).

### Apply

```powershell
git -C artifacts\west-workdir\zephyr apply firmware\patches\0001-sd-fix-ctrl-sync-missing-break.patch
```

Then rebuild:

```powershell
cd artifacts\west-workdir
west build -b xiao_ble/nrf52840/sense C:\Users\knsol\projects\voice-recorder\firmware
```
