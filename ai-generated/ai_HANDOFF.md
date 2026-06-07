# mozzy Handoff

Source: ai-generated
Last updated: 2026-06-07 JST
Workspace: `C:\Users\knsol\projects\mozzy`

## Latest Update (2026-06-07 JST)

This section supersedes any older "not pushed yet" / "gain pending" notes below.

### OMI DevKit2 / Current OMI Mic Gain Correction

This subsection is the newest source of truth for mic gain.

- Latest pushed commit: `0181e7f` (`Align mic gain with OMI levels`).
- The user corrected the OMI-compatible display table to:
  - `0 Mute`
  - `1 -20dB`
  - `2 -10dB`
  - `3 +0dB`
  - `4 +6dB`
  - `5 +10dB`
  - `6 +20dB`
  - `7 +30dB`
  - `8 +40dB`
- Official OMI source was checked and recorded separately in `web-source/web_omi_gain_reference_20260607.md`.
- OMI DevKit2 fixed firmware has `#define MIC_GAIN 64` and assigns it to PDM left/right gain.
- Current OMI firmware exposes settings service `19B10010` and mic gain characteristic `19B10012`.
- Current OMI firmware maps level 0..8 to Nordic PDM gain bytes:
  - `0x00`, `0x14`, `0x1E`, `0x28`, `0x2E`, `0x32`, `0x3C`, `0x46`, `0x50`
  - default level is `6` (`+20dB`, `0x3C`)
  - DevKit2 fixed `64` (`0x40`) sits between levels 6 and 7.
- mojizo firmware now uses the same level table and writes the raw Nordic PDM gain via `nrf_pdm_gain_set()`.
- mojio app labels are dB-only; old multiplier labels are removed.
- `tools/ble_gain_control.py` now reports `omi_level=<n> <label> raw_gain=0x..`.
- Local checks passed after this correction:
  - `python -m compileall -q tools`
  - `flutter analyze`
  - `flutter test`
- GitHub Actions for commit `0181e7f`:
  - `tools`: success, run `27092520799`
  - `firmware`: success, run `27092520804`
  - `mobile`: success, run `27092520803`
- Firmware artifact was downloaded to:
  - `artifacts/firmware/27092520804/mozzy-firmware-xiao-ble-0181e7fe6888ba6ed95e63ce1c86fdef9bf648b6/firmware.uf2`
- Flashing that artifact did not complete because the PC currently sees no mojizo COM port and no `XIAO-SENSE` drive:
  - `flash.ps1` reported: `no COM port and no XIAO-SENSE drive`
  - `Get-CimInstance Win32_SerialPort` returned no serial ports
  - present USB device search only showed the Xiaomi phone
- PC-side BLE status checks also did not connect at that moment:
  - `ble_gain_control.py status --mac FF:94:C9:1A:C9:B3` -> `BleakDeviceNotFoundError`
  - `ble_rec_control.py status --mac FF:94:C9:1A:C9:B3` -> `BleakDeviceNotFoundError`
- APK artifacts were downloaded, but ADB install could not update the currently installed app because package signatures differed:
  - release APK install failed with `INSTALL_FAILED_UPDATE_INCOMPATIBLE`
  - debug APK install also failed with `INSTALL_FAILED_UPDATE_INCOMPATIBLE`
  - do not uninstall automatically unless the user confirms, because it removes app data.
- Next physical step: make mojizo visible to the PC over USB, or double-tap reset so the `XIAO-SENSE` UF2 drive appears, then run:

```powershell
powershell -ExecutionPolicy Bypass -File .\flash.ps1 artifacts\firmware\27092520804\mozzy-firmware-xiao-ble-0181e7fe6888ba6ed95e63ce1c86fdef9bf648b6\firmware.uf2
```

- After flashing, verify and restore with:

```powershell
python tools\ble_gain_control.py status --mac FF:94:C9:1A:C9:B3
python tools\ble_gain_control.py level 8 --mac FF:94:C9:1A:C9:B3
python tools\ble_gain_control.py level 6 --mac FF:94:C9:1A:C9:B3
python tools\ble_rec_control.py off --mac FF:94:C9:1A:C9:B3
```

- GitHub repo is created and pushed: `https://github.com/shkentee/mozzy` (public).
- Current branch: `main`, tracking `origin/main`.
- Latest pushed commit at handoff update before OMI gain work: `3318d1c` (`Verify mojizo firmware and gain controls`).
- OMI-compatible gain work was added later in commit `de4c4f0` (`Add OMI-compatible mic gain service`) and verified on hardware.
- GitHub Actions after push:
  - `mobile`: success, APK artifacts `mozzy-debug-<sha>` and `mozzy-release-<sha>`.
  - `firmware`: success, artifact `mozzy-firmware-xiao-ble-<sha>` with `firmware.uf2`.
  - `tools`: success after replacing the empty pytest run with Python syntax checks. One older failed `tools` run exists from before the fix.
- Firmware artifact from run `27090753701` was downloaded under ignored `artifacts/firmware/27090753701/` and flashed successfully with `flash.ps1`.
- Fresh firmware boots as BLE name `mojizo`; serial log showed `Advertising as 'mojizo'`.
- SD recording is currently OFF. Verified by:
  - `tools/ble_rec_control.py off --mac FF:94:C9:1A:C9:B3`: `Before: on`, `After: off`.
  - Later `status`: `Before: off`, `After: off`.
  - mojio UI showed `SDに録音 / オフ — 一時停止`.
- Gain is now physically verified on fresh firmware, including the OMI-compatible endpoint:
  - `tools/ble_gain_control.py status`: `omi_level=3`, Q4 `16`, `1.00x`.
  - `tools/ble_gain_control.py level 5`: OMI level changed to `5`, Q4 `32`, `2.00x`.
  - Restored with `level 3`: `omi_level=3`, Q4 `16`, `1.00x`.
  - mojio UI showed `マイクゲイン 1.0x`.
- Storage pull is re-verified on fresh firmware:
  - `tools/mobile_app.py ls --mac FF:94:C9:1A:C9:B3`: listed 106 SD files.
  - `tools/mobile_app.py pull 1780826727.opus_sd --mac FF:94:C9:1A:C9:B3 --out artifacts\verify\1780826727_after_flash.opus_sd`: downloaded 127,836 bytes, decoded 2,976 frames, 0 errors, 29.76 seconds.
- PC tools were updated:
  - `ble_rec_control.py`: read/write SD recording control.
  - `ble_gain_control.py`: read/write OMI-compatible gain first, with Q4 diagnostic fallback.
  - `ble_connect.py`, `mobile_app.py`: MAC mode now scans first and passes the BLEDevice object to avoid Windows Bleak address lookup failures.
  - `wr_storage_client.py`: current windowed FETCH command plus legacy fallback.
- Local generated artifacts are ignored: `artifacts/`, app build output, `.dart_tool`.
- Remaining caveat: Google Drive remote-file presence was not proven via the Codex Google Drive connector because the connector saw the target folder as empty, likely due account mismatch. App-side queue/upload markers and "未アップロードなし" were verified, and `uploadIfNew` now verifies the remote file exists before skipping.

## Current State

`mozzy` was created as a new local Git repository to consolidate the app and firmware work.

Baseline used:

- App: `C:\Users\knsol\projects\wearable-recorder` at commit `b897b21` (`scratch/bring-up` baseline)
- Firmware: `C:\Users\knsol\projects\voice-recorder` at commit `d89005a` (`vad-poc` baseline)

Then today's app-side changes from the dirty `wearable-recorder` tree were copied into `mozzy`, excluding wrong/new firmware experiments and screenshots.

Historical note: this was originally written before the first commit/push. The repo has since been committed and pushed to `https://github.com/shkentee/mozzy`; use the latest update section above as the source of truth.

## Files/Areas Already Migrated

From app baseline/current work:

- `app_mobile/`
- `.github/`
- `docs/`
- root docs/license/gitignore
- Android scaffold copied into `app_mobile/android/` because `flutter build apk` initially failed without it.

From firmware baseline:

- `firmware/`
- `tools/`
- `flash.ps1`
- `west.yml`

App-side files that were intentionally carried over from today's work include:

- `app_mobile/lib/pages/device_page.dart`
- `app_mobile/lib/pages/scan_page.dart`
- `app_mobile/lib/pages/settings_page.dart`
- `app_mobile/lib/pages/transcripts_page.dart`
- `app_mobile/lib/services/wr_ble_device.dart`
- `app_mobile/lib/services/wr_ble_scanner.dart`
- `app_mobile/lib/services/wr_drive_uploader.dart`
- `app_mobile/lib/services/wr_sd_sync.dart`
- `app_mobile/lib/services/wr_sync_schedule.dart`
- `app_mobile/lib/services/wr_uuids.dart`
- `app_mobile/pubspec.yaml`
- `app_mobile/pubspec.lock`
- related tests

## Fixes Already Made In mozzy

- `wr_ble_scanner.dart`: native BLE scan filter narrowed to Battery Service (`180F`) because firmware advertises only standard services in advertisements; custom UUID filters did not match on Android.
- `scan_page.dart`: added initial auto-scan when no saved device ID exists. This also bypasses unreliable ADB coordinate taps on this device.
- `device_page.dart`: fixed error status display so `error:` states show the actual error rather than generic connecting text.
- Tests updated for current Japanese UI strings, `audioLevel` stream, recording/gain mocks, and new storage fetch command format.
- Drive default folder ID is set in `wr_drive_uploader.dart` to `1IPNXw8EzMz6u6nGUo5H1xtuwkI4NKayJ`.

## Verification Already Completed

App static/build checks:

- `flutter pub get`: OK
- `flutter analyze`: OK, no issues found
- `flutter test`: OK, 76 tests passed
- `flutter build apk --release`: OK, APK produced
- `flutter build apk --debug`: OK, APK produced

Build note: APK build required this environment adjustment because Android NDK expected Unix tools:

```powershell
$env:PATH = 'C:\Program Files\Git\usr\bin;' + $env:PATH
$env:HOST_OS = 'windows'
flutter build apk --release
```

Phone:

- ADB device connected: `EAXWU8IRFEMRKBQS device`
- Release APK installed successfully.
- Permissions granted with ADB.
- ADB coordinate taps against Flutter UI were unreliable. Workaround used: write SharedPreferences directly in debug build, then reinstall release without clearing data.

Saved app preferences used for verification:

- `wr_last_device_id = FF:94:C9:1A:C9:B3`
- `wr_sched_mode = 2` (`intervalWindow`)
- `wr_sched_interval = 60`
- `wr_sched_winstart = 0`
- `wr_sched_winend = 1439`
- `wr_drive_upload_auto = true`
- `wr_upload_wifi_only = false`
- `wr_drive_folder_id = 1IPNXw8EzMz6u6nGUo5H1xtuwkI4NKayJ`
- `wr_drive_folder = recordings`

App/device verification after current firmware flash:

- App auto-connected to BLE device.
- UI showed: `Mojio Device`, connected, battery `97%`.
- UI showed `SDに録音` switch visible and ON (`オン — 本体に保存中`).
- UI showed sync schedule: `00:00〜23:59 / 60分間隔`.
- UI showed pull status: `最新まで吸出し済み`.
- UI showed Drive status: `自動`, `未アップロードなし`.

## Firmware State

Do not use the previously copied `mozzy-d89005a-20260606.uf2` as the active firmware. It was flashed once but BLE service listing showed it was missing recording control and time sync.

Current active firmware flashed to the device:

- Source file copied from: `C:\Users\knsol\projects\voice-recorder\artifacts\firmware_verify60.uf2`
- Copied to: `C:\Users\knsol\projects\mozzy\artifacts\firmware\firmware_verify60.uf2`
- Flashed with:

```powershell
powershell -ExecutionPolicy Bypass -File C:\Users\knsol\projects\mozzy\flash.ps1 C:\Users\knsol\projects\mozzy\artifacts\firmware\firmware_verify60.uf2 -ComPort COM8
```

Flash result: success; COM8 came back online.

BLE service listing after flashing `firmware_verify60.uf2` confirmed these services:

- Battery Service `0000180f...`
- Device Information `0000180a...`
- Audio `19b10000...`
- Recording control `19b10006...` with read/write/write-without-response
- Storage `30295780...`
- Time sync `19b10005...`

This matches the app enough for connection, recording ON/OFF, storage pull, and time sync.

## Important Firmware/App Mismatch

Mic gain is not fully resolved.

Current `mozzy/firmware` source contains `firmware/src/wr_gain_control.c`, which defines gain as:

- UUID: `19B10007-E8F2-537E-4F6C-D104768A1214`
- Format: Q4 software gain, `16 = 1.0x`

But the app currently expects Omi-style gain:

- Service: `19b10010-e8f2-537e-4f6c-d104768a1214`
- Characteristic: `19b10012-e8f2-537e-4f6c-d104768a1214`
- Format: level `0..8`, labels `Mute, -20dB, -10dB, 0dB, +6dB, +10dB, +20dB, +30dB, +40dB`

The currently flashed `firmware_verify60.uf2` does not expose either gain service, so the app hides the mic-gain card. Do not claim gain verification is complete.

To finish gain properly, choose one path:

1. Add CMake/Zephyr build tools and build current source so `wr_gain_control.c` is included, then change the app to read/write `19B10007` Q4 gain, or
2. Change firmware to expose Omi-style `19b10010/19b10012` level `0..8` and build/flash that.

A firmware rebuild was attempted but failed because CMake is not installed/found on this PC.

## Not Yet Completed

- Actual Drive upload verification by creating/pulling a new audio file and checking Google Drive folder contents is not complete.
- Full app UI tap-flow verification is incomplete because ADB coordinate taps were unreliable on this Xiaomi/Android device. Auto-connect and UI state were verified through saved prefs and UI dump.
- GitHub repo `mozzy` has not been created/pushed yet.
- Old folder `C:\Users\knsol\projects\voice-recorder` has not been deleted and must not be deleted until after successful commit/push and verification.
- Firmware source build from `mozzy/firmware` is not verified because CMake is missing.

## Git/Commit Notes

Current repo is new and mostly untracked. Before committing:

- Remove/ignore temporary verification XML/PNG files if any appear.
- Generated artifacts are ignored: `.dart_tool`, `build`, `.gradle`, `artifacts`.
- Android scaffold was copied, but `app_mobile/android/.gitignore` ignores Gradle wrapper files:
  - `app_mobile/android/gradlew`
  - `app_mobile/android/gradlew.bat`
  - `app_mobile/android/gradle/wrapper/gradle-wrapper.jar`
- Decide whether to adjust Android `.gitignore` or force-add those files. For a portable Flutter Android build, they should likely be committed.
- `app_mobile/android/local.properties` must not be committed.

Recommended check before commit:

```powershell
git status --short --ignored
flutter analyze
flutter test
flutter build apk --release
```

Potential GitHub command after verification:

```powershell
gh repo create shkentee/mozzy --public --source C:\Users\knsol\projects\mozzy --remote origin --push
```

## Recommended Next Steps

1. Keep current flashed `firmware_verify60.uf2` unless/until a proper source build is possible.
2. Verify physical device behavior:
   - Recording ON should be white breathing LED.
   - Recording OFF should be green blinking/breathing.
   - Short press physical button toggles recording.
   - Long press enters sleep; next press wakes/resets.
3. Verify app pull/upload with real data:
   - Let device record for a short period.
   - Confirm app remains connected and sync is enabled.
   - Trigger manual pull if needed from UI or wait interval.
   - Check pending files/outbox and Drive upload status.
   - Confirm files appear in Google Drive folder `1IPNXw8EzMz6u6nGUo5H1xtuwkI4NKayJ` / local mirror `C:\Users\knsol\coai\recordings`.
4. Decide and fix mic-gain path. Do not say Omi-style gain is verified yet.
5. Clean Git status, commit, create public GitHub repo, push.
6. Only after successful push and requested verification, delete `C:\Users\knsol\projects\voice-recorder`.

## High-Risk Reminder

The earlier wrong path was caused by flashing a UF2 that looked like the baseline but did not expose the expected BLE control services. Always verify firmware by BLE service listing after flashing, not by filename alone.
