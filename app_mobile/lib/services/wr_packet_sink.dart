import 'dart:async';
import 'dart:io';

/// Append-only binary dump of audioCodec notify packets.
///
/// Each call to [add] writes the raw notify bytes verbatim — i.e. the
/// 3-byte omi header followed by the Opus payload. PC-side tooling can
/// then re-parse the file by walking [WrAudioPacket]-style headers, or
/// strip headers to feed an Opus decoder.
///
/// We deliberately do **not** wrap each packet with an extra length
/// prefix here: the omi header already gives us packet_id / frame_id
/// continuity and the consumer can recover frame boundaries by
/// re-running the same decode logic that lives in
/// `wr_audio_packet.dart`. Keeping the on-disk format as "concatenated
/// raw notifies" matches what we'd get if we just `cat`'d the BLE
/// notifications into a file, which is the simplest possible contract.
///
/// The sink is single-writer; concurrent [add] calls are serialised
/// through an internal [Future] chain so writes land in arrival order
/// and `bytesWritten` stays consistent.
class WrPacketSink {
  WrPacketSink(this.file);

  /// Destination file. Opened lazily on first [add] in append mode so
  /// callers can construct sinks during BLE setup without paying the
  /// I/O cost until packets actually arrive.
  final File file;

  IOSink? _sink;
  Future<void> _writeChain = Future.value();
  int _bytesWritten = 0;
  bool _closed = false;

  /// Total bytes appended to [file] through this sink. Useful for the
  /// DevicePage "Saved bytes" readout.
  int get bytesWritten => _bytesWritten;

  /// True once [close] has been called. Further [add]s become no-ops
  /// (rather than throwing) so a late-arriving notify after teardown
  /// doesn't tear down the BLE listener.
  bool get isClosed => _closed;

  /// Append [bytes] to the dump file.
  ///
  /// Returns a future that completes when the bytes have been handed to
  /// the OS-level sink. The future is chained to previous writes so the
  /// on-disk order matches call order even if callers don't `await`.
  Future<void> add(List<int> bytes) {
    if (_closed || bytes.isEmpty) {
      return Future.value();
    }
    final next = _writeChain.then((_) async {
      final sink = await _ensureSink();
      sink.add(bytes);
      _bytesWritten += bytes.length;
    });
    // Swallow errors on the chain so one failed write doesn't poison
    // every subsequent add(); surface them on the returned future only.
    _writeChain = next.catchError((_) {});
    return next;
  }

  Future<IOSink> _ensureSink() async {
    final existing = _sink;
    if (existing != null) return existing;
    // Create the parent dir lazily — the docs dir always exists, but
    // tests construct sinks under a temp dir + nested subpath.
    final parent = file.parent;
    if (!await parent.exists()) {
      await parent.create(recursive: true);
    }
    final sink = file.openWrite(mode: FileMode.append);
    _sink = sink;
    return sink;
  }

  /// Flush and close the underlying file. Safe to call multiple times.
  Future<void> close() async {
    if (_closed) return;
    _closed = true;
    // Wait for any in-flight writes before flushing/closing.
    await _writeChain.catchError((_) {});
    final sink = _sink;
    if (sink != null) {
      await sink.flush();
      await sink.close();
      _sink = null;
    }
  }
}
