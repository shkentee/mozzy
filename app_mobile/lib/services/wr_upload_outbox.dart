import 'dart:io';

import 'package:path_provider/path_provider.dart';

class WrQueuedFile {
  const WrQueuedFile({
    required this.file,
    required this.name,
    required this.sizeBytes,
    required this.alreadyQueued,
  });

  final File file;
  final String name;
  final int sizeBytes;
  final bool alreadyQueued;
}

class WrUploadOutbox {
  const WrUploadOutbox();

  static Future<Directory> dir() async {
    final base = await getApplicationSupportDirectory();
    final outbox = Directory('${base.path}/outbox');
    if (!await outbox.exists()) await outbox.create(recursive: true);
    return outbox;
  }

  Future<WrQueuedFile> enqueue(
    File source,
    String desiredName, {
    bool deleteSource = false,
  }) async {
    final outbox = await dir();
    final safeName = _safeName(desiredName);
    final sourceLength = await source.length();
    var target = File('${outbox.path}/$safeName');
    var queueName = safeName;

    if (await target.exists()) {
      final targetLength = await target.length();
      if (targetLength == sourceLength) {
        if (deleteSource) await _deleteQuietly(source);
        return WrQueuedFile(
          file: target,
          name: queueName,
          sizeBytes: targetLength,
          alreadyQueued: true,
        );
      }

      final ext = _extension(safeName);
      final base = _basenameWithoutExtension(safeName);
      final stamp = DateTime.now().millisecondsSinceEpoch;
      queueName = '${base}_usb_$stamp$ext';
      target = File('${outbox.path}/$queueName');
    }

    final tmp = File('${target.path}.tmp');
    if (await tmp.exists()) await tmp.delete();
    await source.copy(tmp.path);
    if (await target.exists()) await target.delete();
    await tmp.rename(target.path);
    if (deleteSource) await _deleteQuietly(source);

    return WrQueuedFile(
      file: target,
      name: queueName,
      sizeBytes: await target.length(),
      alreadyQueued: false,
    );
  }

  static String _safeName(String name) {
    final normalized = name.trim().replaceAll('\\', '/');
    final base = normalized.split('/').last;
    if (base.isEmpty || base == '.' || base == '..') {
      throw ArgumentError.value(name, 'name', 'Invalid outbox file name');
    }
    return base;
  }

  static String _extension(String name) {
    final dot = name.lastIndexOf('.');
    if (dot <= 0 || dot == name.length - 1) return '';
    return name.substring(dot);
  }

  static String _basenameWithoutExtension(String name) {
    final dot = name.lastIndexOf('.');
    if (dot <= 0) return name;
    return name.substring(0, dot);
  }

  static Future<void> _deleteQuietly(File file) async {
    try {
      await file.delete();
    } catch (_) {}
  }
}
