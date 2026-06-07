import 'dart:io';

import 'package:path_provider/path_provider.dart';

/// A locally-saved recording dump (one BLE session) under `wr_dumps/`.
class WrRecording {
  WrRecording(this.file, this.sizeBytes, this.modified);

  final File file;
  final int sizeBytes;
  final DateTime modified;

  String get name => file.uri.pathSegments.last;

  /// Best-effort start time parsed from the `<MAC>-<epochMs>.bin` filename,
  /// falling back to the file's mtime.
  DateTime get startedAt {
    final m = RegExp(r'-(\d{10,})\.bin$').firstMatch(name);
    if (m != null) {
      final ms = int.tryParse(m.group(1)!);
      if (ms != null) return DateTime.fromMillisecondsSinceEpoch(ms);
    }
    return modified;
  }

  /// Rough duration: omi notify ≈ 3-byte header + ~39-byte Opus frame @ 10 ms.
  Duration get approxDuration =>
      Duration(milliseconds: (sizeBytes / 42 * 10).round());
}

/// Lists and locates the app's local recording dumps.
class WrLocalRecordings {
  static Future<Directory> dumpsDir() async {
    final docs = await getApplicationDocumentsDirectory();
    return Directory('${docs.path}/wr_dumps');
  }

  /// All `.bin` dumps, most-recent first.
  static Future<List<WrRecording>> list() async {
    final dir = await dumpsDir();
    if (!await dir.exists()) return [];
    final out = <WrRecording>[];
    await for (final e in dir.list()) {
      if (e is File && e.path.endsWith('.bin')) {
        final st = await e.stat();
        out.add(WrRecording(e, st.size, st.modified));
      }
    }
    out.sort((a, b) => b.modified.compareTo(a.modified));
    return out;
  }
}
