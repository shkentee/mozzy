# mojio mobile app

Flutter Android app for the mojizo recorder. It connects to the BLE device, controls recording, pulls files from device storage, and uploads recordings to Google Drive.

Full Japanese manual: [`../docs/manual.html`](../docs/manual.html)

## Remote APK Build

The repository includes a GitHub Actions workflow that can be started from GitHub Mobile:

1. Open `https://github.com/shkentee/mozzy/actions/workflows/mobile.yml`.
2. Tap `Run workflow`.
3. Download `mozzy-release-<sha>` from the completed run.
4. Unzip it and install `app-release.apk` on Android.

## Local Build

```powershell
flutter pub get
flutter analyze
flutter test
flutter build apk --release
```

The Android scaffold is committed, including the Gradle wrapper. `android/local.properties` is generated locally and intentionally ignored.

## Runtime Notes

- The app scans using the standard Battery Service advertisement filter because the current firmware advertises standard services.
- The app auto-scans on first launch when no saved device ID exists.
- Google Drive upload defaults to folder ID `1IPNXw8EzMz6u6nGUo5H1xtuwkI4NKayJ`.
- Mic gain UI is hidden unless the connected firmware exposes a compatible gain characteristic. Fresh mojizo firmware uses the Q4 gain service; older Omi-compatible firmware can use the 0..8 level service.
