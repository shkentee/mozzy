import 'dart:convert';
import 'dart:io';

import 'package:flutter/services.dart';
import 'package:path_provider/path_provider.dart';

import 'wr_drive_uploader.dart';
import 'wr_upload_outbox.dart';

class WrWiredFile {
  const WrWiredFile({
    required this.name,
    required this.sizeBytes,
  });

  final String name;
  final int sizeBytes;
}

class WrWiredRescueStatus {
  const WrWiredRescueStatus({
    required this.running,
    required this.status,
    required this.totalFiles,
    required this.queuedFiles,
    required this.totalBytes,
    required this.processedBytes,
    this.currentFile,
    this.lastError,
  });

  final bool running;
  final String status;
  final int totalFiles;
  final int queuedFiles;
  final int totalBytes;
  final int processedBytes;
  final String? currentFile;
  final String? lastError;

  factory WrWiredRescueStatus.fromMap(Map<dynamic, dynamic> map) {
    int asInt(Object? value) {
      if (value is int) return value;
      return int.tryParse('$value') ?? 0;
    }

    return WrWiredRescueStatus(
      running: map['running'] == true,
      status: (map['status'] ?? '').toString(),
      totalFiles: asInt(map['totalFiles']),
      queuedFiles: asInt(map['queuedFiles']),
      totalBytes: asInt(map['totalBytes']),
      processedBytes: asInt(map['processedBytes']),
      currentFile: map['currentFile']?.toString(),
      lastError: map['lastError']?.toString(),
    );
  }
}

class WrWiredUsb {
  WrWiredUsb({MethodChannel? channel})
      : _channel = channel ?? const MethodChannel('mojio/wired_usb');

  final MethodChannel _channel;

  Future<String> ping() async {
    final result = await _channel.invokeMethod<String>('ping');
    return result ?? '';
  }

  Future<String> pauseRecording() async {
    final result = await _channel.invokeMethod<String>('pauseRecording');
    return result ?? '';
  }

  Future<String> resumeRecording() async {
    final result = await _channel.invokeMethod<String>('resumeRecording');
    return result ?? '';
  }

  Future<String> diagnoseUsb() async {
    final result = await _channel.invokeMethod<String>('diagnoseUsb');
    return result ?? '';
  }

  Future<void> setKeepScreenOn(bool enabled) async {
    await _channel.invokeMethod<bool>('setKeepScreenOn', {
      'enabled': enabled,
    });
  }

  Future<void> startQueueAllInBackground() async {
    await _channel.invokeMethod<bool>('startQueueAll');
  }

  Future<void> startQueueOneInBackground(String name) async {
    await _channel.invokeMethod<bool>('startQueueOne', {
      'name': name,
    });
  }

  Future<WrWiredRescueStatus> getRescueStatus() async {
    final raw = await _channel.invokeMethod<Map<dynamic, dynamic>>(
      'getRescueStatus',
    );
    return WrWiredRescueStatus.fromMap(raw ?? const <dynamic, dynamic>{});
  }

  Future<List<WrWiredFile>> listFiles() async {
    final raw = await _channel.invokeMethod<List<dynamic>>('listFiles');
    return _parseFileList(raw);
  }

  Future<List<WrWiredFile>> listRescueCandidates() async {
    final raw =
        await _channel.invokeMethod<List<dynamic>>('listRescueCandidates');
    return _parseFileList(raw);
  }

  List<WrWiredFile> _parseFileList(List<dynamic>? raw) {
    return (raw ?? const <dynamic>[])
        .whereType<Map<dynamic, dynamic>>()
        .map((m) {
          final name = (m['name'] ?? '').toString();
          final size = m['size'];
          return WrWiredFile(
            name: name,
            sizeBytes: size is int ? size : int.tryParse('$size') ?? 0,
          );
        })
        .where((f) => f.name.isNotEmpty)
        .toList();
  }

  Future<File> fetchToTemp(WrWiredFile file) async {
    final dir = await getTemporaryDirectory();
    final out = File('${dir.path}/${file.name}');
    final received = await _channel.invokeMethod<int>('fetchFile', {
      'name': file.name,
      'path': out.path,
    });
    final length = await out.length();
    final nativeLength = received ?? length;
    if (file.sizeBytes > 0 && nativeLength != file.sizeBytes) {
      throw StateError(
          'USB fetch size mismatch: expected ${file.sizeBytes}, got $nativeLength');
    }
    return out;
  }

  int? _epochFromName(String name) {
    final match = RegExp(r'^(\d{10})\.opus_sd$').firstMatch(name);
    return match == null ? null : int.tryParse(match.group(1)!);
  }

  Future<void> _writeTimelineSidecar(
    File audioFile,
    String audioName, {
    required String originalName,
    required String source,
  }) async {
    final epoch = _epochFromName(audioName) ?? _epochFromName(originalName);
    if (epoch == null) return;
    final payload = <String, Object?>{
      'schema': 'mozzy.timeline.v1',
      'audio_file': audioName,
      'original_file': originalName,
      'recording_start_epoch': epoch,
      'recording_start_source': source,
      'created_at_epoch': DateTime.now().toUtc().millisecondsSinceEpoch ~/ 1000,
    };
    await File('${audioFile.path}.meta.json')
        .writeAsString(jsonEncode(payload), flush: true);
  }

  Future<int> fetchAndUploadAll({
    required WrDriveUploader uploader,
    void Function(String message)? onProgress,
  }) async {
    onProgress?.call('USBデバイス確認中...');
    await ping();
    onProgress?.call('録音を一時停止中...');
    await pauseRecording();
    try {
      final files = await listFiles();
      var uploaded = 0;

      for (final file in files) {
        onProgress?.call('USB吸出し中: ${file.name}');
        final local = await fetchToTemp(file);
        try {
          onProgress?.call('Drive送信中: ${file.name}');
          final id = await uploader.uploadIfNew(local, file.name);
          if (id != null) uploaded++;
        } finally {
          try {
            await local.delete();
          } catch (_) {}
        }
      }

      onProgress?.call(files.isEmpty
          ? 'USB側に送信対象ファイルはありません'
          : 'USB吸出し完了: $uploaded/${files.length}件をDriveへ送信');
      return uploaded;
    } finally {
      onProgress?.call('録音を再開中...');
      await resumeRecording();
    }
  }

  Future<int> fetchAndQueueAll({
    WrUploadOutbox outbox = const WrUploadOutbox(),
    void Function(String message)? onProgress,
  }) async {
    onProgress?.call('USB内の録音を確認中...');
    await ping();
    onProgress?.call('録音を一時停止中...');
    await pauseRecording();
    try {
      final files = await listFiles();
      var queued = 0;

      for (final file in files) {
        onProgress?.call('USB吸出し中: ${file.name}');
        final local = await fetchToTemp(file);
        final item = await outbox.enqueue(
          local,
          file.name,
          deleteSource: true,
        );
        await _writeTimelineSidecar(
          item.file,
          item.name,
          originalName: file.name,
          source: 'usb_epoch_filename',
        );
        if (!item.alreadyQueued) queued++;
        onProgress?.call(item.alreadyQueued
            ? '送信待ちに登録済み: ${item.name}'
            : '送信待ちへ追加: ${item.name}');
      }

      onProgress?.call(files.isEmpty
          ? 'USB側に吸出し対象ファイルはありません'
          : 'USB吸出し完了: ${files.length}件を送信待ちに入れました');
      return queued;
    } finally {
      onProgress?.call('録音を再開中...');
      await resumeRecording();
    }
  }
}
