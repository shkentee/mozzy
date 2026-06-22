import 'dart:io';

import 'package:connectivity_plus/connectivity_plus.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'wr_drive_uploader.dart';
import 'wr_sd_sync.dart' show kDriveUploadAutoKey, kWifiOnlyKey;
import 'wr_upload_outbox.dart';

class WrOutboxDrainResult {
  const WrOutboxDrainResult({
    required this.uploadedFiles,
    required this.alreadyUploadedFiles,
    required this.uploadedBytes,
    required this.remainingFiles,
    required this.remainingBytes,
    this.autoUploadDisabled = false,
    this.blockedNoWifi = false,
    this.lastError,
  });

  final int uploadedFiles;
  final int alreadyUploadedFiles;
  final int uploadedBytes;
  final int remainingFiles;
  final int remainingBytes;
  final bool autoUploadDisabled;
  final bool blockedNoWifi;
  final String? lastError;

  bool get didWork => uploadedFiles > 0 || alreadyUploadedFiles > 0;
}

class WrUploadQueueDrainer {
  WrUploadQueueDrainer({WrDriveUploader? uploader})
      : _uploader = uploader ?? WrDriveUploader();

  final WrDriveUploader _uploader;

  Future<List<({File file, int length})>> _pendingFiles() async {
    final dir = await WrUploadOutbox.dir();
    final files =
        await dir.list().where((e) => e is File).cast<File>().toList();
    files.sort((a, b) => a.path.compareTo(b.path));

    final pending = <({File file, int length})>[];
    for (final f in files) {
      try {
        final length = await f.length();
        if (length > 0) pending.add((file: f, length: length));
      } catch (_) {}
    }
    return pending;
  }

  Future<WrOutboxDrainResult> drain({
    bool force = false,
    void Function(String message)? onProgress,
  }) async {
    final prefs = await SharedPreferences.getInstance();
    final autoUpload = prefs.getBool(kDriveUploadAutoKey) ?? true;
    if (!force && !autoUpload) {
      final pending = await _pendingFiles();
      return WrOutboxDrainResult(
        uploadedFiles: 0,
        alreadyUploadedFiles: 0,
        uploadedBytes: 0,
        remainingFiles: pending.length,
        remainingBytes: pending.fold<int>(0, (sum, p) => sum + p.length),
        autoUploadDisabled: true,
      );
    }

    final wifiOnly = prefs.getBool(kWifiOnlyKey) ?? false;
    if (wifiOnly) {
      final result = await Connectivity().checkConnectivity();
      if (!result.contains(ConnectivityResult.wifi)) {
        final pending = await _pendingFiles();
        return WrOutboxDrainResult(
          uploadedFiles: 0,
          alreadyUploadedFiles: 0,
          uploadedBytes: 0,
          remainingFiles: pending.length,
          remainingBytes: pending.fold<int>(0, (sum, p) => sum + p.length),
          blockedNoWifi: true,
        );
      }
    }

    var pending = await _pendingFiles();
    var uploadedFiles = 0;
    var alreadyUploadedFiles = 0;
    var uploadedBytes = 0;
    String? lastError;

    for (final item in pending) {
      final file = item.file;
      final name = file.uri.pathSegments.last;
      onProgress?.call('Drive送信中: $name');
      try {
        final id = await _uploader.uploadIfNew(file, name);
        if (id == null) {
          alreadyUploadedFiles++;
        } else {
          uploadedFiles++;
        }
        uploadedBytes += item.length;
        await file.delete();
      } catch (e) {
        lastError = '$name: $e';
        break;
      }
    }

    pending = await _pendingFiles();
    return WrOutboxDrainResult(
      uploadedFiles: uploadedFiles,
      alreadyUploadedFiles: alreadyUploadedFiles,
      uploadedBytes: uploadedBytes,
      remainingFiles: pending.length,
      remainingBytes: pending.fold<int>(0, (sum, p) => sum + p.length),
      lastError: lastError,
    );
  }
}
