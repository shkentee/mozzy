import 'dart:io';
import 'dart:typed_data';

import 'package:opus_dart/opus_dart.dart';
import 'package:opus_flutter/opus_flutter.dart' as opus_flutter;

/// Decodes mojizo dump files (`.bin` = concatenated raw omi
/// notifies) into a playable 16 kHz mono PCM WAV, on-device.
///
/// The `.bin` has NO length framing (see wr_packet_sink.dart): each notify is
/// `[packetId_lo, packetId_hi, frameId] + opus_payload`, simply concatenated.
/// We recover frame boundaries from two redundant signals:
///   * packetId (uint16 LE, byte 0..1) is monotonic, +1 per notify, wraps 0xFFFF
///   * every Opus frame from this fixed encoder starts with TOC byte 0xB0
/// so the next header is the next position whose `[.., frameId==0, 0xB0]`
/// carries the expected next packetId (tolerating small dropped-packet gaps).
class WrOpusDecoder {
  WrOpusDecoder._();

  static const int sampleRate = 16000;
  static const int channels = 1;
  static const int _toc = 0xB0; // fixed encoder TOC (16k/mono/lowdelay)
  static const int _maxGap = 64; // tolerate this many dropped packets

  static bool _initialised = false;

  /// Loads libopus (bundled by opus_flutter) and initialises opus_dart.
  /// Idempotent; safe to call from app start and again lazily.
  static Future<void> ensureInit() async {
    if (_initialised) return;
    initOpus(await opus_flutter.load());
    _initialised = true;
  }

  /// Splits a raw dump into individual Opus frame byte-strings.
  static List<Uint8List> framesFromDump(Uint8List b) {
    final frames = <Uint8List>[];
    final n = b.length;
    if (n < 4) return frames;
    int pos = 0;
    int pid = b[0] | (b[1] << 8);
    while (pos + 3 <= n) {
      final payloadStart = pos + 3;
      final j = _findNextHeader(b, payloadStart + 1, pid);
      if (j < 0) {
        if (payloadStart < n) {
          frames.add(Uint8List.sublistView(b, payloadStart, n));
        }
        break;
      }
      if (j > payloadStart) {
        frames.add(Uint8List.sublistView(b, payloadStart, j));
      }
      pid = b[j] | (b[j + 1] << 8);
      pos = j;
    }
    return frames;
  }

  static int _findNextHeader(Uint8List b, int start, int pid) {
    final n = b.length;
    for (int j = start; j + 4 <= n; j++) {
      if (b[j + 2] == 0 && b[j + 3] == _toc) {
        final cand = b[j] | (b[j + 1] << 8);
        final delta = (cand - pid) & 0xFFFF;
        if (delta >= 1 && delta <= _maxGap) return j;
      }
    }
    return -1;
  }

  /// Decodes [dumpFile] to a 16 kHz mono WAV at [outPath]. Reports progress
  /// (0..1) via [onProgress] and yields to the event loop periodically so the
  /// UI stays responsive. Returns the written WAV file.
  static Future<File> decodeDumpToWav(
    File dumpFile,
    String outPath, {
    void Function(double progress)? onProgress,
  }) async {
    await ensureInit();
    final bytes = await dumpFile.readAsBytes();
    final frames = framesFromDump(bytes);
    final decoder =
        SimpleOpusDecoder(sampleRate: sampleRate, channels: channels);
    final pcm = BytesBuilder(copy: false);
    try {
      for (int i = 0; i < frames.length; i++) {
        if (frames[i].isEmpty) continue;
        try {
          final Int16List out = decoder.decode(input: frames[i]);
          pcm.add(out.buffer.asUint8List(out.offsetInBytes, out.lengthInBytes));
        } catch (_) {
          // Skip a corrupt frame and keep going.
        }
        if ((i & 0x3FF) == 0) {
          onProgress?.call(frames.isEmpty ? 1 : i / frames.length);
          await Future<void>.delayed(Duration.zero);
        }
      }
    } finally {
      decoder.destroy();
    }
    onProgress?.call(1.0);
    final wav = _wrapWav(pcm.toBytes(), sampleRate, channels);
    final out = File(outPath);
    await out.writeAsBytes(wav, flush: true);
    return out;
  }

  static Uint8List _wrapWav(Uint8List pcm, int rate, int ch) {
    final dataLen = pcm.length;
    final byteRate = rate * ch * 2;
    final out = Uint8List(44 + dataLen);
    final bd = ByteData.view(out.buffer);
    void str(int off, String x) {
      for (int i = 0; i < x.length; i++) {
        out[off + i] = x.codeUnitAt(i);
      }
    }

    str(0, 'RIFF');
    bd.setUint32(4, 36 + dataLen, Endian.little);
    str(8, 'WAVE');
    str(12, 'fmt ');
    bd.setUint32(16, 16, Endian.little); // fmt chunk size
    bd.setUint16(20, 1, Endian.little); // PCM
    bd.setUint16(22, ch, Endian.little);
    bd.setUint32(24, rate, Endian.little);
    bd.setUint32(28, byteRate, Endian.little);
    bd.setUint16(32, ch * 2, Endian.little); // block align
    bd.setUint16(34, 16, Endian.little); // bits per sample
    str(36, 'data');
    bd.setUint32(40, dataLen, Endian.little);
    out.setAll(44, pcm);
    return out;
  }
}
