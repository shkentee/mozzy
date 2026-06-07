# mozzy

[![mobile](https://github.com/shkentee/mozzy/actions/workflows/mobile.yml/badge.svg)](https://github.com/shkentee/mozzy/actions/workflows/mobile.yml)
[![firmware](https://github.com/shkentee/mozzy/actions/workflows/build-scratch.yml/badge.svg)](https://github.com/shkentee/mozzy/actions/workflows/build-scratch.yml)
[![tools](https://github.com/shkentee/mozzy/actions/workflows/tools.yml/badge.svg)](https://github.com/shkentee/mozzy/actions/workflows/tools.yml)

`mozzy` is the consolidated repository for the wearable recorder project:

- `app_mobile/`: `mojio`, the Flutter Android app for BLE connection, recording control, SD pull, and Google Drive upload.
- `firmware/`: `mojizo`, the Zephyr firmware/device identity for Seeed XIAO nRF52840 Sense.
- `tools/`: helper scripts for BLE/storage inspection and local processing.
- `docs/`: project notes and specs carried over from the earlier work.

## Manual

- Japanese user manual: [`docs/manual.html`](docs/manual.html)
- App README: [`app_mobile/README.md`](app_mobile/README.md)

## Current Status

The app and firmware have been consolidated from the previous local repositories. The currently verified flashed device firmware exposes the BLE services needed for connection, recording control, storage pull, battery, and time sync.

Verification on 2026-06-07 JST:

- BLE connection and device info read succeeded against device `FF:94:C9:1A:C9:B3`.
- SD recording control was verified: mojio showed recording ON, then `tools/ble_rec_control.py off` changed the device state from ON to OFF over BLE.
- SD file listing succeeded, and a sample file `1780826727.opus_sd` was pulled and decoded locally: 127,836 bytes, 29.76 seconds, 0 decode errors.
- The app now supports both the current mojizo windowed storage fetch protocol and the legacy verification-firmware whole-file fetch protocol.
- App-side SD pull and upload queue processing were verified on-device: mojio showed a completed 0.2 MB pull, no pending upload, and local uploaded markers for `1780826727.opus_sd:127836`, `1780829341.opus_sd:253371`, and `1780829401.opus_sd:242651`.
- Google Drive connector access to folder `1IPNXw8EzMz6u6nGUo5H1xtuwkI4NKayJ` was confirmed, but that connector saw an empty folder. This may be a Google account mismatch with the account signed into mojio. To avoid false "already uploaded" deletes, `uploadIfNew` now verifies the remote Drive file still exists before skipping a queued file.
- GitHub Actions builds were verified after push: `mobile`, `firmware`, and `tools` completed successfully.
- The GitHub Actions firmware artifact was flashed to mojizo. BLE advertising shows `mojizo`, mojio reconnects, and SD recording is OFF.
- Mic gain uses the OMI-compatible settings service (`19b10010` / `19b10012`) with 0..8 levels and OMI dB labels: `Mute`, `-20dB`, `-10dB`, `+0dB`, `+6dB`, `+10dB`, `+20dB`, `+30dB`, `+40dB`.
- mojizo maps those levels to OMI-style Nordic PDM gain bytes, with DevKit2's fixed `MIC_GAIN 64` used for level 6 (`+20dB`): `0x00`, `0x14`, `0x1E`, `0x28`, `0x2E`, `0x32`, `0x40`, `0x46`, `0x50`. Source notes are kept in `web-source/web_omi_gain_reference_20260607.md`.
- Latest DevKit2 `MIC_GAIN 64` alignment (`96ab55b`) is pushed and `mobile`, `firmware`, and `tools` Actions succeeded. The UF2 is downloaded under `artifacts/firmware/27093151287/.../firmware.uf2`; flashing is pending because the PC currently sees only the Android phone over USB, not the mojizo COM port or `XIAO-SENSE` UF2 drive.
- New-firmware SD pull was re-verified after flashing: `1780826727.opus_sd` downloaded as 127,836 bytes and decoded to a 29.76 s WAV with 0 errors.

## Build From A Phone

Once this repository is pushed to GitHub, APK and firmware builds can be started from GitHub Mobile or a phone browser:

1. Open `https://github.com/shkentee/mozzy/actions`.
2. Choose `mobile` to build the Android app, then tap `Run workflow`.
3. After the run succeeds, open the run and download `mozzy-release-<sha>`.
4. Unzip the artifact on the phone and install `app-release.apk`.

Firmware UF2 builds work the same way:

1. Open `Actions`.
2. Choose `firmware`, then tap `Run workflow`.
3. Download `mozzy-firmware-xiao-ble-<sha>`.
4. Copy `firmware.uf2` to the XIAO bootloader drive.

## Local App Build

```powershell
cd app_mobile
flutter pub get
flutter analyze
flutter test
flutter build apk --release
```

On this Windows machine, Android release builds may need Git's Unix tools in `PATH`:

```powershell
$env:PATH = 'C:\Program Files\Git\usr\bin;' + $env:PATH
$env:HOST_OS = 'windows'
flutter build apk --release
```

## Local Firmware Build

Local firmware builds require a Zephyr/NCS toolchain with `west`, `cmake`, and `ninja`. If those are not installed locally, use the GitHub Actions `firmware` workflow instead.

```powershell
west build -b xiao_ble/nrf52840/sense -p always firmware
```

## BLE Helper Tools

When the phone UI cannot be used, the PC can read or change the device recording state directly:

```powershell
python tools\ble_rec_control.py status --mac FF:94:C9:1A:C9:B3
python tools\ble_rec_control.py off --mac FF:94:C9:1A:C9:B3
python tools\ble_gain_control.py status --mac FF:94:C9:1A:C9:B3
python tools\ble_gain_control.py level 6 --mac FF:94:C9:1A:C9:B3
```

## Repository Notes

- Generated build output, `.dart_tool`, `.gradle`, and local APK/UF2 artifacts are ignored.
- `app_mobile/android/local.properties` must stay uncommitted because it contains local SDK paths.
- The Android Gradle wrapper is committed so a fresh clone can build without relying on a system Gradle install.
