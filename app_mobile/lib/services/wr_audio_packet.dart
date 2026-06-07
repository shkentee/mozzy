/// Decoded audioCodec notify packet from a mojizo / omi-compatible device.
///
/// Wire format mirrored from the omi devkit firmware
/// (`third_party/omi/omi/firmware/devkit/src/transport.c`) and confirmed
/// against the omi Flutter client at
/// `third_party/omi/app/lib/services/audio_sources/ble_device_source.dart`:
///
/// ```
/// byte 0..1  packet_id (uint16, little-endian) — monotonic, wraps at 0xFFFF
/// byte 2     frame_id  (uint8)                 — chunk index within packet
/// byte 3..   payload                           — raw Opus frame bytes
/// ```
///
/// We keep the API decode-only (no allocation of a separate payload buffer
/// where the caller already has the underlying list) so that
/// [WrPacketSink] can persist the original bytes verbatim while UI / future
/// decode paths read structured fields off the same packet.
class WrAudioPacket {
  /// Number of bytes occupied by the omi 3-byte header.
  static const int headerSize = 3;

  /// Monotonic packet id from the firmware (uint16 LE). Wraps at 0xFFFF.
  final int packetId;

  /// Chunk / frame index within the packet (uint8).
  final int frameId;

  /// Opus frame payload (everything after the 3-byte header).
  ///
  /// The list is an unmodifiable view onto the bytes that were passed to
  /// [parse]; treat it as read-only.
  final List<int> payload;

  const WrAudioPacket({
    required this.packetId,
    required this.frameId,
    required this.payload,
  });

  /// Decode an audioCodec notify packet.
  ///
  /// Throws [ArgumentError] when the buffer is shorter than [headerSize] —
  /// such a packet cannot carry the firmware header and is treated as a
  /// protocol violation rather than silently dropped, since the caller
  /// (typically `WrBleDevice._onPacket`) will want to surface it.
  ///
  /// A zero-length payload is *valid* (header present, no Opus frame) and
  /// will produce a [WrAudioPacket] with an empty [payload].
  factory WrAudioPacket.parse(List<int> bytes) {
    if (bytes.length < headerSize) {
      throw ArgumentError.value(
        bytes.length,
        'bytes.length',
        'audioCodec packet shorter than $headerSize-byte header',
      );
    }
    final packetId = bytes[0] | (bytes[1] << 8);
    final frameId = bytes[2];
    // sublist() copies; wrap unmodifiable so callers can't mutate behind us.
    final payload = bytes.length == headerSize
        ? const <int>[]
        : List<int>.unmodifiable(bytes.sublist(headerSize));
    return WrAudioPacket(
      packetId: packetId,
      frameId: frameId,
      payload: payload,
    );
  }

  @override
  String toString() =>
      'WrAudioPacket(packetId: $packetId, frameId: $frameId, payload: ${payload.length}B)';
}
