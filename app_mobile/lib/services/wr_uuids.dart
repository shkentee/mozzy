/// GATT UUID definitions used by the mojizo firmware.
///
/// Mirrored from `third_party/omi/omi/firmware/devkit/src/transport.c`
/// (see also docs/phase6-plan-draft.md §3) so the mobile client can
/// filter / subscribe without depending on the omi Flutter app.
class WrUuids {
  // Audio service.
  static const String audioService = '19b10000-e8f2-537e-4f6c-d104768a1214';
  static const String audioData = '19b10001-e8f2-537e-4f6c-d104768a1214';
  static const String audioCodec = '19b10002-e8f2-537e-4f6c-d104768a1214';
  static const String audioStatus = '19b10003-e8f2-537e-4f6c-d104768a1214';

  // DFU service (nrf standard).
  static const String dfuService = '00001530-1212-efde-1523-785feabcd123';

  // Time-sync service (D7): write 8-byte LE64 Unix epoch to sync firmware clock.
  // Service UUID doubles as the characteristic UUID (single-characteristic service).
  static const String timeSyncService = '19b10005-e8f2-537e-4f6c-d104768a1214';
  static const String timeSyncChar = '19b10005-e8f2-537e-4f6c-d104768a1214';

  // Recording on/off control (D9): READ 1 byte state (1=recording, 0=paused),
  // WRITE 1 byte (0=pause SD recording, non-zero=resume). Single-char service.
  static const String recControlService =
      '19b10006-e8f2-537e-4f6c-d104768a1214';
  static const String recControlChar = '19b10006-e8f2-537e-4f6c-d104768a1214';

  // OMI-compatible settings service: mic gain is READ/WRITE 1 byte, level 0..8.
  // mojizo maps these levels to the UI gain steps 0.25x..6.0x.
  static const String settingsService = '19b10010-e8f2-537e-4f6c-d104768a1214';
  static const String micGainChar = '19b10012-e8f2-537e-4f6c-d104768a1214';

  // mojizo diagnostic gain service: READ/WRITE 1 byte, Q4 fixed point
  // software gain where 16 = 1.0x. Service UUID doubles as characteristic.
  static const String q4GainService = '19b10007-e8f2-537e-4f6c-d104768a1214';
  static const String q4GainChar = '19b10007-e8f2-537e-4f6c-d104768a1214';

  // Storage data stream service (chunk fetch).
  static const String storageService = '30295780-4301-eabd-2904-2849adfeae43';
  static const String storageStream = '30295781-4301-eabd-2904-2849adfeae43';
  static const String storageReadControl =
      '30295782-4301-eabd-2904-2849adfeae43';

  // Bluetooth standard Battery Service (0x180F) + Battery Level char (0x2A19).
  // Exposed by wr_battery_service.c; value is uint8 0–100 (percent).
  static const String batteryService = '0000180f-0000-1000-8000-00805f9b34fb';
  static const String batteryLevel = '00002a19-0000-1000-8000-00805f9b34fb';

  // Default device name advertised by mojizo firmware.
  static const String defaultDeviceName = 'mojizo';
}
