import 'dart:io';

import 'package:flutter/services.dart';
import 'package:path_provider/path_provider.dart';

import 'wr_drive_uploader.dart';

class WrWiredFile {
  const WrWiredFile({
    required this.name,
    required this.sizeBytes,
  });

  final String name;
  final int sizeBytes;
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

  Future<List<WrWiredFile>> listFiles() async {
    final raw = await _channel.invokeMethod<List<dynamic>>('listFiles');
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
}
