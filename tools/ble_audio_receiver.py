"""Connect to the mojizo BLE peripheral and dump Opus audio frames.

Subscribes to the audio characteristic (19b10001-...) on the mojizo device,
strips the 3-byte omi header (id LSB, id MSB, frame index) from each notify
packet, and appends the remaining Opus frame bytes to an output file.

The output file uses the SD-card-compatible framing: each captured Opus
frame is prefixed by a single length byte. Decode with
`opus_to_wav.py --format sd`. 100ms frames @ 16kHz mono 32kbps VBR
(i.e. ~10 frames per second of audio).

Usage:
    python ble_audio_receiver.py [--mac FF:94:C9:1A:C9:B3] [--seconds 30]
                                 [--out audio.opus_raw]
"""
import argparse
import asyncio
import sys
import time
from pathlib import Path

try:
    from bleak import BleakClient, BleakScanner
    from bleak.backends.characteristic import BleakGATTCharacteristic
    from bleak.exc import BleakError
except ImportError:
    print("bleak not installed. pip install bleak")
    sys.exit(1)


DEFAULT_MAC = "FF:94:C9:1A:C9:B3"
AUDIO_CHAR_UUID = "19b10001-e8f2-537e-4f6c-d104768a1214"
HEADER_LEN = 3  # omi: [id_lsb, id_msb, frame_index]


class AudioCollector:
    """Reassembles Opus frames from chunked BLE notifications.

    omi's pusher splits each Opus frame across multiple BLE notifies
    (per push_to_gatt in transport.c): each notify is `[id_lsb][id_msb]
    [chunk_index][...payload...]`, where chunk_index resets to 0 at the
    start of every new Opus frame. We accumulate chunks until index
    rolls back to 0, then emit the assembled frame as one SD-style
    `[length][opus_frame]` record so opus_to_wav.py --format sd can
    decode it.
    """

    def __init__(self, out_path: Path):
        self.out_path = out_path
        self.fp = open(out_path, "wb")
        self.packets = 0           # raw BLE notifies
        self.frames_written = 0    # reassembled Opus frames
        self.bytes_written = 0
        self.first_pkt_at: float | None = None
        self.last_pkt_at: float | None = None
        self.last_id: int | None = None
        self.gaps = 0
        self._frame_buf = bytearray()
        self._expected_index = 0

    def _flush_frame(self) -> None:
        if not self._frame_buf:
            return
        size = len(self._frame_buf)
        if 0 < size <= 255:
            self.fp.write(bytes([size]))
            self.fp.write(bytes(self._frame_buf))
            self.bytes_written += 1 + size
            self.frames_written += 1
        # else: oversize frame -- drop (shouldn't happen for 32 kbps / 100 ms)
        self._frame_buf.clear()

    def callback(self, sender: BleakGATTCharacteristic, data: bytearray) -> None:
        now = time.monotonic()
        if self.first_pkt_at is None:
            self.first_pkt_at = now
        self.last_pkt_at = now
        self.packets += 1

        if len(data) < HEADER_LEN:
            return

        pkt_id = data[0] | (data[1] << 8)
        chunk_idx = data[2]

        if self.last_id is not None:
            expected = (self.last_id + 1) & 0xFFFF
            if pkt_id != expected:
                self.gaps += 1
        self.last_id = pkt_id

        # New frame begins when chunk_index resets to 0. Flush whatever
        # was being built (the previous frame).
        if chunk_idx == 0:
            self._flush_frame()
            self._expected_index = 0

        # Sanity: missed chunk -> abandon current frame to avoid corruption
        if chunk_idx != self._expected_index:
            self._frame_buf.clear()
            # Resync only on the next chunk_idx == 0
            return

        self._frame_buf.extend(data[HEADER_LEN:])
        self._expected_index += 1

    def close(self) -> None:
        try:
            # Flush any in-progress final frame before closing.
            self._flush_frame()
            self.fp.flush()
            self.fp.close()
        except Exception:
            pass


async def find_device(name_hint: str = "mojizo", timeout: int = 8):
    print(f"Scanning {timeout}s for '{name_hint}'...")
    devices = await BleakScanner.discover(timeout=timeout)
    for d in devices:
        nm = d.name or ""
        if name_hint.lower() in nm.lower():
            return d
    for d in devices:
        nm = d.name or ""
        if any(k in nm.lower() for k in ("friend", "omi", "recorder")):
            return d
    return None


async def run(mac: str | None, seconds: int, out_path: Path) -> int:
    if mac:
        target_addr = mac
        target_name = "(by MAC)"
    else:
        d = await find_device()
        if not d:
            print("mojizo device not found in scan.")
            return 2
        target_addr = d.address
        target_name = d.name or "(unnamed)"

    print(f"Target: {target_addr}  {target_name}")
    print(f"Output: {out_path}")
    print(f"Audio characteristic: {AUDIO_CHAR_UUID}")
    print(f"Streaming for {seconds}s ...\n")

    collector = AudioCollector(out_path)
    t_start = time.monotonic()

    try:
        async with BleakClient(target_addr, timeout=10) as client:
            t_conn = time.monotonic() - t_start
            print(f"  connected in {t_conn:.2f}s, MTU={client.mtu_size}")

            await client.start_notify(AUDIO_CHAR_UUID, collector.callback)
            print("  subscribed to audio notifications. Streaming...\n")

            t_stream_start = time.monotonic()
            last_packets = 0
            last_bytes = 0
            elapsed = 0.0

            try:
                while elapsed < seconds:
                    await asyncio.sleep(1.0)
                    elapsed = time.monotonic() - t_stream_start
                    dp = collector.packets - last_packets
                    db = collector.bytes_written - last_bytes
                    last_packets = collector.packets
                    last_bytes = collector.bytes_written
                    print(
                        f"  t={elapsed:5.1f}s  "
                        f"packets={collector.packets:5d} (+{dp:3d}/s)  "
                        f"bytes={collector.bytes_written:7d} (+{db:5d}/s)  "
                        f"gaps={collector.gaps}"
                    )
            except KeyboardInterrupt:
                print("\n  Ctrl-C received -- stopping early.")

            try:
                await client.stop_notify(AUDIO_CHAR_UUID)
            except Exception as e:
                print(f"  stop_notify warning: {e}")

            print("\nDisconnecting cleanly.")
    except asyncio.TimeoutError:
        elapsed = time.monotonic() - t_start
        print(f"\nTimeout after {elapsed:.2f}s [FAIL]")
        collector.close()
        return 1
    except BleakError as e:
        elapsed = time.monotonic() - t_start
        print(f"\nBleakError after {elapsed:.2f}s: {e} [FAIL]")
        collector.close()
        return 1
    except KeyboardInterrupt:
        print("\nKeyboardInterrupt at top level -- closing file.")
    finally:
        collector.close()

    # Summary
    total = time.monotonic() - t_start
    if collector.first_pkt_at and collector.last_pkt_at:
        stream_window = collector.last_pkt_at - collector.first_pkt_at
    else:
        stream_window = 0.0
    approx_audio_sec = collector.frames_written / 10.0  # 100ms frames

    print("\n=== Summary ===")
    print(f"  Session total:    {total:.2f}s")
    print(f"  Stream window:    {stream_window:.2f}s (first->last packet)")
    print(f"  BLE notifies:     {collector.packets}")
    print(f"  Opus frames:      {collector.frames_written} (reassembled)")
    print(f"  Bytes written:    {collector.bytes_written}")
    print(f"  Detected gaps:    {collector.gaps} (non-contiguous packet ids)")
    print(f"  Saved to:         {out_path.resolve()}")
    print(
        f"  Approx ~{approx_audio_sec:.1f}s of audio "
        f"(at 100ms frames, 10 frames/sec)"
    )
    return 0


def main() -> int:
    p = argparse.ArgumentParser(description=__doc__)
    p.add_argument(
        "--mac",
        default=DEFAULT_MAC,
        help=f"MAC address of mojizo device (default: {DEFAULT_MAC}). "
             "Pass empty string to force a scan.",
    )
    p.add_argument(
        "--seconds",
        type=int,
        default=30,
        help="How many seconds to stream before disconnecting (default: 30).",
    )
    p.add_argument(
        "--out",
        default="audio.opus_raw",
        help="Output file path for raw Opus frames (default: audio.opus_raw).",
    )
    args = p.parse_args()

    mac = args.mac if args.mac else None
    out_path = Path(args.out)

    try:
        return asyncio.run(run(mac, args.seconds, out_path))
    except KeyboardInterrupt:
        print("\nInterrupted.")
        return 130


if __name__ == "__main__":
    sys.exit(main())
