"""Python equivalent of the mojio Flutter mobile app.

Single-file CLI that mirrors what `app_mobile` does on the phone:
  * scan / connect to the mojizo BLE peripheral
  * read battery level (0x180F / 0x2A19)
  * list SD-stored files via the Storage GATT service
  * download a file (SD framing -> WAV)
  * stream live audio (BLE 19b10001 reassembly -> SD-style frames)
  * decode any captured Opus stream to a playable WAV

Subcommands:
  scan
      Scan and print likely targets.
  info  [--mac MAC]
      Connect, print MTU + battery + service summary, disconnect.
  ls    [--mac MAC]
      List SD-card audio files via the Storage service.
  pull  FILENAME [--mac MAC] [--out FILE]
      Download FILENAME from SD over BLE; write SD-framed bytes and decode
      to WAV alongside.
  stream [--mac MAC] [--seconds N] [--out FILE]
      Stream live audio for N seconds; write SD-framed bytes and decode
      to WAV alongside.
  decode INPUT [--out FILE] [--format auto|sd|raw|ogg]
      Local decode-only path (delegates to opus_to_wav.py).

Requires:
    pip install bleak pyogg
"""
from __future__ import annotations

import argparse
import asyncio
import os
import sys
import time
from pathlib import Path
from typing import Optional

try:
    from bleak import BleakClient, BleakScanner
    from bleak.backends.characteristic import BleakGATTCharacteristic
    from bleak.exc import BleakError
except ImportError:
    print("bleak not installed. pip install bleak")
    sys.exit(1)

# Local modules
sys.path.insert(0, str(Path(__file__).parent))
from wr_storage_client import WrStorageClient  # noqa: E402
from ble_audio_receiver import AudioCollector, AUDIO_CHAR_UUID  # noqa: E402

# Reuse the Opus decoder + WAV writer from opus_to_wav.py
import opus_to_wav  # noqa: E402


DEFAULT_MAC      = os.environ.get("WR_MAC")
DEFAULT_NAME     = "mojizo"

BATTERY_SERVICE  = "0000180f-0000-1000-8000-00805f9b34fb"
BATTERY_LEVEL    = "00002a19-0000-1000-8000-00805f9b34fb"

DIS_SERVICE      = "0000180a-0000-1000-8000-00805f9b34fb"
MANUFACTURER     = "00002a29-0000-1000-8000-00805f9b34fb"
MODEL_NUMBER     = "00002a24-0000-1000-8000-00805f9b34fb"
HARDWARE_REV     = "00002a27-0000-1000-8000-00805f9b34fb"
FIRMWARE_REV     = "00002a26-0000-1000-8000-00805f9b34fb"

AUDIO_CODEC_UUID = "19b10002-e8f2-537e-4f6c-d104768a1214"


# ----------------------------------------------------------------------------
# helpers
# ----------------------------------------------------------------------------
async def find_device(name_hint: str = DEFAULT_NAME, timeout: int = 8):
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


async def resolve_target(mac: Optional[str]):
    """Returns (bleak target, address, label)."""
    if mac:
        print(f"Scanning 8s for address {mac}...")
        d = await BleakScanner.find_device_by_address(mac, timeout=8)
        if d is not None:
            return d, d.address, d.name or "(by MAC)"
        return mac, mac, "(by MAC)"
    d = await find_device()
    if not d:
        raise RuntimeError("mojizo device not found in scan.")
    return d, d.address, d.name or "(unnamed)"


async def safe_read(client: BleakClient, uuid: str) -> Optional[bytes]:
    try:
        return await client.read_gatt_char(uuid)
    except Exception:
        return None


def _decode_to_wav(framed_path: Path, wav_path: Path, fmt: str) -> tuple[int, int, float]:
    """Decode an SD-framed (or other) blob to WAV. Returns (n_ok, n_err, dur_s)."""
    with open(framed_path, "rb") as f:
        buf = f.read()
    if fmt == "auto":
        fmt = opus_to_wav.detect_format(buf)
    if fmt == "sd":
        frame_iter = opus_to_wav.iter_sd_frames(buf)
    elif fmt == "ogg":
        frame_iter = opus_to_wav.iter_ogg_opus_packets(buf)
    else:
        raise ValueError(f"unsupported format for live decode: {fmt}")
    pcm, n_ok, n_err = opus_to_wav.decode_frames(
        frame_iter, opus_to_wav.DEFAULT_RATE, opus_to_wav.DEFAULT_CHANNELS
    )
    opus_to_wav.write_wav(
        str(wav_path), pcm, opus_to_wav.DEFAULT_RATE, opus_to_wav.DEFAULT_CHANNELS
    )
    n_samples = len(pcm) // (2 * opus_to_wav.DEFAULT_CHANNELS)
    dur = n_samples / float(opus_to_wav.DEFAULT_RATE)
    return n_ok, n_err, dur


# ----------------------------------------------------------------------------
# commands
# ----------------------------------------------------------------------------
async def cmd_scan(_args) -> int:
    print("Scanning 8s for BLE advertisements...\n")
    devices = await BleakScanner.discover(timeout=8)
    if not devices:
        print("No advertisements detected.")
        return 1
    for d in devices:
        nm = d.name or "(no name)"
        marker = ""
        if d.name and any(k in d.name.lower() for k in ("mojizo", "mojio", "friend", "omi", "recorder")):
            marker = "  <-- LIKELY OURS"
        print(f"  {d.address}  {nm}{marker}")
    return 0


async def cmd_info(args) -> int:
    target, addr, label = await resolve_target(args.mac)
    print(f"Target: {addr}  {label}\nConnecting...")
    async with BleakClient(target, timeout=10) as client:
        print(f"  connected, MTU={client.mtu_size}")

        bat = await safe_read(client, BATTERY_LEVEL)
        if bat:
            print(f"  battery level: {bat[0]}%")
        else:
            print("  battery level: (read failed)")

        codec = await safe_read(client, AUDIO_CODEC_UUID)
        if codec:
            print(f"  audio codec ID: {codec[0]} (raw bytes={codec.hex()})")

        for label_, uuid_ in (
            ("manufacturer", MANUFACTURER),
            ("model       ", MODEL_NUMBER),
            ("hw rev      ", HARDWARE_REV),
            ("fw rev      ", FIRMWARE_REV),
        ):
            v = await safe_read(client, uuid_)
            if v:
                try:
                    print(f"  {label_}: {v.decode('utf-8', errors='replace').strip()}")
                except Exception:
                    print(f"  {label_}: {v.hex()}")

        print("\n  Services:")
        for svc in client.services:
            print(f"    {svc.uuid}")
    return 0


async def cmd_ls(args) -> int:
    target, addr, label = await resolve_target(args.mac)
    print(f"Target: {addr}  {label}\nConnecting...")
    async with BleakClient(target, timeout=10) as client:
        print(f"  connected, MTU={client.mtu_size}\n")
        storage = WrStorageClient(client)
        try:
            files = await storage.list_files(timeout=20.0)
        finally:
            await storage.close()
    if not files:
        print("(no files reported by device)")
        return 0
    print(f"Files on SD ({len(files)}):")
    for f in files:
        print(f"  {f}")
    return 0


async def cmd_pull(args) -> int:
    target, addr, label = await resolve_target(args.mac)
    print(f"Target: {addr}  {label}\nConnecting...")
    out_path = Path(args.out) if args.out else Path(args.filename + ".opus_sd")
    wav_path = out_path.with_suffix(".wav")

    async with BleakClient(target, timeout=10) as client:
        print(f"  connected, MTU={client.mtu_size}")
        print(f"  fetching '{args.filename}' ...")
        storage = WrStorageClient(client)
        last_print = [0.0]
        t0 = time.monotonic()

        def progress(total: int) -> None:
            now = time.monotonic()
            if now - last_print[0] > 0.5:
                rate = total / max(0.001, now - t0)
                print(f"    {total:>9d} bytes ({rate/1024:.1f} KB/s)")
                last_print[0] = now

        try:
            data = await storage.fetch_file(
                args.filename, timeout=600.0, on_progress=progress
            )
        finally:
            await storage.close()

    out_path.write_bytes(data)
    elapsed = time.monotonic() - t0
    print(f"\nWrote {len(data)} bytes to {out_path} in {elapsed:.1f}s")

    print(f"\nDecoding to WAV ({wav_path}) ...")
    try:
        n_ok, n_err, dur = _decode_to_wav(out_path, wav_path, "sd")
        print(f"  decoded frames: {n_ok}  errors: {n_err}  duration: {dur:.2f}s")
    except Exception as e:
        print(f"  decode failed: {e}")
        return 1
    return 0


async def cmd_stream(args) -> int:
    target, addr, label = await resolve_target(args.mac)
    print(f"Target: {addr}  {label}\nConnecting...")
    out_path = Path(args.out)
    wav_path = out_path.with_suffix(".wav")
    collector = AudioCollector(out_path)
    t_start = time.monotonic()

    try:
        async with BleakClient(target, timeout=10) as client:
            print(f"  connected, MTU={client.mtu_size}")
            await client.start_notify(AUDIO_CHAR_UUID, collector.callback)
            print(f"  streaming for {args.seconds}s -> {out_path}\n")

            t_stream = time.monotonic()
            last_p, last_b = 0, 0
            elapsed = 0.0
            try:
                while elapsed < args.seconds:
                    await asyncio.sleep(1.0)
                    elapsed = time.monotonic() - t_stream
                    dp = collector.packets - last_p
                    db = collector.bytes_written - last_b
                    last_p, last_b = collector.packets, collector.bytes_written
                    print(
                        f"  t={elapsed:5.1f}s  packets={collector.packets:5d} "
                        f"(+{dp:3d}/s)  bytes={collector.bytes_written:7d} "
                        f"(+{db:5d}/s)  gaps={collector.gaps}"
                    )
            except KeyboardInterrupt:
                print("\n  interrupted -- stopping early.")
            try:
                await client.stop_notify(AUDIO_CHAR_UUID)
            except Exception:
                pass
    except (asyncio.TimeoutError, BleakError) as e:
        print(f"\nBLE error: {e}")
        collector.close()
        return 1
    finally:
        collector.close()

    print(f"\nWrote {collector.frames_written} frames "
          f"({collector.bytes_written} bytes) to {out_path}")
    print(f"Decoding to WAV ({wav_path}) ...")
    try:
        n_ok, n_err, dur = _decode_to_wav(out_path, wav_path, "sd")
        print(f"  decoded frames: {n_ok}  errors: {n_err}  duration: {dur:.2f}s")
    except Exception as e:
        print(f"  decode failed: {e}")
        return 1
    return 0


async def cmd_record(args) -> int:
    """Long-running BLE → PC recording with automatic rotation.

    Equivalent to what the on-device SD recording was supposed to do,
    but with the PC as the storage backend. Runs until Ctrl+C and
    rotates output files every `--rotate-min` minutes (default 10).

    Each rotation produces:
      <prefix>_NNN.opus_sd  (raw SD-style frame format)
      <prefix>_NNN.wav      (decoded 16 kHz mono)

    Use this when the on-device SD path is broken/unreliable but you
    still need continuous recording — the BLE link is the only writer.
    """
    target, addr, label = await resolve_target(args.mac)
    print(f"Target: {addr}  {label}\nConnecting...")
    prefix = Path(args.prefix)
    rotate_seconds = max(60, int(args.rotate_min * 60))
    chunk_idx = 0

    def make_collector(idx: int):
        out_path = prefix.parent / f"{prefix.name}_{idx:03d}.opus_sd"
        return out_path, AudioCollector(out_path)

    try:
        async with BleakClient(target, timeout=10) as client:
            print(f"  connected, MTU={client.mtu_size}")
            print(f"  recording -> {prefix}_NNN.opus_sd  (rotate every {rotate_seconds}s)")
            print(f"  Ctrl+C to stop\n")

            out_path, collector = make_collector(chunk_idx)
            await client.start_notify(AUDIO_CHAR_UUID, collector.callback)

            t_start = time.monotonic()
            t_rotate = t_start
            last_p, last_b = 0, 0

            try:
                while True:
                    await asyncio.sleep(1.0)
                    now = time.monotonic()
                    total_elapsed = now - t_start
                    chunk_elapsed = now - t_rotate
                    dp = collector.packets - last_p
                    db = collector.bytes_written - last_b
                    last_p, last_b = collector.packets, collector.bytes_written
                    print(
                        f"  T={total_elapsed:6.0f}s  chunk={chunk_idx:03d} "
                        f"t={chunk_elapsed:5.0f}s  +{dp:3d}p/s  +{db:5d}B/s  "
                        f"gaps={collector.gaps}"
                    )
                    if chunk_elapsed >= rotate_seconds:
                        # rotate: stop current, decode, start fresh
                        try:
                            await client.stop_notify(AUDIO_CHAR_UUID)
                        except Exception:
                            pass
                        collector.close()
                        last_p, last_b = 0, 0
                        wav_path = out_path.with_suffix(".wav")
                        try:
                            n_ok, n_err, dur = _decode_to_wav(out_path, wav_path, "sd")
                            print(f"  rotated: {out_path.name} "
                                  f"({n_ok} frames, {dur:.1f}s) -> {wav_path.name}")
                        except Exception as e:
                            print(f"  rotate decode failed: {e}")
                        chunk_idx += 1
                        out_path, collector = make_collector(chunk_idx)
                        await client.start_notify(AUDIO_CHAR_UUID, collector.callback)
                        t_rotate = time.monotonic()
            except KeyboardInterrupt:
                print("\n  Ctrl+C -- finalising last chunk.")
            try:
                await client.stop_notify(AUDIO_CHAR_UUID)
            except Exception:
                pass
    except (asyncio.TimeoutError, BleakError) as e:
        print(f"\nBLE error: {e}")
        collector.close()
        return 1
    finally:
        collector.close()

    # Decode the final chunk
    wav_path = out_path.with_suffix(".wav")
    print(f"\nFinal chunk {out_path.name}: {collector.frames_written} frames")
    try:
        n_ok, n_err, dur = _decode_to_wav(out_path, wav_path, "sd")
        print(f"  decoded -> {wav_path.name}: {n_ok} frames, {dur:.2f}s, errors={n_err}")
    except Exception as e:
        print(f"  decode failed: {e}")
    return 0


async def cmd_reset(args) -> int:
    """Hard-reset the board by re-flashing the staged UF2.

    Useful when SD recording has decayed into a fs_close -EIO state and
    `ls` returns ERROR. Wraps `flash.ps1 <UF2>` so the recovery flow is
    one command instead of "drop to PowerShell, find UF2, run script".

    The UF2 path defaults to `firmware_2026-05-02.uf2` in the project dir;
    override with --uf2.
    """
    import shutil
    repo_root = Path(__file__).resolve().parents[1]
    uf2 = Path(args.uf2)
    if not uf2.is_absolute():
        candidates = [Path.cwd() / uf2, repo_root / uf2]
        uf2 = next((p for p in candidates if p.is_file()), candidates[0])
    if not uf2.is_file():
        print(f"UF2 not found: {uf2}")
        print("Hint: run `gh run download <run-id> -D /tmp/uf2_dl` from "
              "the mozzy repo, then copy firmware.uf2 here, "
              "or pass --uf2 <path>.")
        return 1
    flash_ps1 = repo_root / "flash.ps1"
    if not flash_ps1.is_file():
        print(f"flash.ps1 not found at {flash_ps1}")
        return 1
    pwsh = shutil.which("powershell") or "powershell"
    print(f"Flashing {uf2.name} via flash.ps1 ...")
    proc = await asyncio.create_subprocess_exec(
        pwsh, "-NoProfile", "-File", str(flash_ps1), str(uf2),
        stdout=asyncio.subprocess.PIPE,
        stderr=asyncio.subprocess.STDOUT,
    )
    out_b, _ = await proc.communicate()
    out = out_b.decode("utf-8", errors="replace")
    print(out)
    if proc.returncode != 0:
        return proc.returncode
    print("\nWaiting 5s for SD init, then reading omi-info ...")
    await asyncio.sleep(5)
    # Reuse cmd_omi_info to confirm post-reset state
    class _A:
        mac = args.mac
    try:
        await cmd_omi_info(_A())
    except Exception as e:
        print(f"post-reset omi-info failed: {e}")
        return 1
    return 0


async def cmd_omi_info(args) -> int:
    """Read omi-original Storage service file_num_array for diagnostics.

    omi's original storage service exposes the read characteristic
    (30295782, props=['read','notify']) which returns file_num_array[2]
    as 8 raw bytes (two little-endian uint32). This works even if the
    wr_storage path returned ERROR — it's a different code path that
    only needs file_num_array (populated at mount), not fs_opendir.
    """
    target, addr, label = await resolve_target(args.mac)
    print(f"Target: {addr}  {label}\nConnecting...")
    async with BleakClient(target, timeout=10) as client:
        print(f"  connected, MTU={client.mtu_size}\n")
        # Find the omi-original storage read char (props=['notify','read'])
        target_ch = None
        for svc in client.services:
            if str(svc.uuid).lower() != "30295780-4301-eabd-2904-2849adfeae43":
                continue
            for ch in svc.characteristics:
                if (str(ch.uuid).lower() == "30295782-4301-eabd-2904-2849adfeae43"
                        and "read" in ch.properties):
                    target_ch = ch
                    break
            if target_ch:
                break
        if not target_ch:
            print("omi-original storage read char not found")
            return 1
        data = await client.read_gatt_char(target_ch)
        print(f"  raw {len(data)} bytes: {data.hex()}")
        if len(data) >= 8:
            import struct
            a, b = struct.unpack("<II", data[:8])
            print(f"  file_num_array[0] = {a}  (a01.txt size in bytes)")
            print(f"  file_num_array[1] = {b}  (saved offset)")
            total = a + b
            approx_audio_s = total * 8 / 32000
            print(f"  total bytes = {total}  ~= {approx_audio_s:.1f}s of audio")
        # Patch 0035: extended diagnostic counters (24 more bytes)
        if len(data) >= 32:
            wts, wtf, wtf_open_fail, wtf_open_last_ret_u, wtf_write_fail, wtf_close_fail = struct.unpack("<IIIIII", data[8:32])
            wtf_open_last_ret = struct.unpack("<i", struct.pack("<I", wtf_open_last_ret_u))[0]
            print(f"  --- write path counters (patch 0035) ---")
            print(f"  write_to_storage calls : {wts}")
            print(f"  write_to_file calls    : {wtf}")
            print(f"  fs_open failures       : {wtf_open_fail}")
            print(f"  fs_open last return    : {wtf_open_last_ret}")
            print(f"  fs_write < 0 count     : {wtf_write_fail}")
            print(f"  fs_close non-zero      : {wtf_close_fail}")
        # Patch 0042: SD sector 0 OEM ID (8 more bytes)
        if len(data) >= 40:
            oem_bytes = data[32:40]
            print(f"  --- SD boot sector (patch 0042) ---")
            print(f"  sector0 OEM ID raw : {oem_bytes.hex()}")
            try:
                ascii_repr = oem_bytes.decode('ascii', errors='replace')
                print(f"  sector0 OEM ID ASCII: {ascii_repr!r}")
                if "EXFAT" in ascii_repr:
                    print("  *** card is exFAT ***")
                elif "MSDOS" in ascii_repr or "MSWIN" in ascii_repr or "mkfs.fat" in ascii_repr:
                    print("  *** card is FAT (FAT32 likely) ***")
            except Exception:
                pass
    return 0


async def cmd_omi_pull(args) -> int:
    """Pull a01.txt from SD via omi-original Storage service (UUID 30295781).

    Bypasses wr_storage entirely. Talks the omi protocol:
      C->P  WRITE  [0, file_num, size_be32]  (READ_COMMAND)
      P->C  NOTIFY 1-byte result ack         (0=ok, 3/4/5/6=err)
      P->C  NOTIFY up to 440-byte data chunks
      P->C  NOTIFY 1-byte {100} = done

    Works on the live a01.txt because omi's storage_write thread reads
    via fs_open(read_only) on a separate handle from the persistent
    write handle. SD_BLE_SIZE = 440.
    """
    SD_BLE_SIZE = 440
    READ_COMMAND = 0
    DONE_BYTE = 100

    target, addr, label = await resolve_target(args.mac)
    print(f"Target: {addr}  {label}\nConnecting...")
    out_path = Path(args.out) if args.out else Path(f"a{args.file_num:02d}.opus_sd")
    wav_path = out_path.with_suffix(".wav")

    async with BleakClient(target, timeout=10) as client:
        print(f"  connected, MTU={client.mtu_size}")

        # Find omi-original Storage service write/notify char (30295781)
        ctrl_ch = None
        for svc in client.services:
            if str(svc.uuid).lower() != "30295780-4301-eabd-2904-2849adfeae43":
                continue
            for ch in svc.characteristics:
                if (str(ch.uuid).lower() == "30295781-4301-eabd-2904-2849adfeae43"
                        and "write" in ch.properties
                        and "notify" in ch.properties):
                    ctrl_ch = ch
                    break
            if ctrl_ch:
                break
        if ctrl_ch is None:
            print("ERROR: omi-original Storage write/notify char not found")
            return 1

        # Pre-read file size (so we know how much to expect)
        size_ch = None
        for svc in client.services:
            if str(svc.uuid).lower() != "30295780-4301-eabd-2904-2849adfeae43":
                continue
            for ch in svc.characteristics:
                if (str(ch.uuid).lower() == "30295782-4301-eabd-2904-2849adfeae43"
                        and "read" in ch.properties):
                    size_ch = ch
                    break
            if size_ch:
                break
        expected_size = None
        if size_ch is not None:
            data = await client.read_gatt_char(size_ch)
            if len(data) >= 8:
                import struct
                a, _b = struct.unpack("<II", data[:8])
                expected_size = a
                print(f"  expected size: {a} bytes (~{a*8/32000:.1f}s)")

        # Receive buffer
        buf = bytearray()
        done_evt = asyncio.Event()
        ack_evt = asyncio.Event()
        ack_val = [None]
        last_print = [0.0]
        t0 = time.monotonic()

        def on_notify(_sender, data: bytearray) -> None:
            n = len(data)
            if n == 1:
                v = data[0]
                if not ack_evt.is_set():
                    ack_val[0] = v
                    ack_evt.set()
                    return
                # post-ack 1-byte = control: 100=done, 200=delete-done
                if v == DONE_BYTE:
                    done_evt.set()
                # otherwise ignore
                return
            # data chunk (typically 440 bytes, last may be smaller)
            buf.extend(data)
            now = time.monotonic()
            if now - last_print[0] > 0.5:
                rate = len(buf) / max(0.001, now - t0)
                print(f"    {len(buf):>9d} bytes ({rate/1024:.1f} KB/s)")
                last_print[0] = now

        await client.start_notify(ctrl_ch, on_notify)
        try:
            # Build [READ_COMMAND, file_num, size_be32]; size=0 means start from beginning
            cmd = bytes([READ_COMMAND, args.file_num,
                         0, 0, 0, 0])
            print(f"  sending READ file_num={args.file_num} from offset=0...")
            await client.write_gatt_char(ctrl_ch, cmd, response=False)
            await asyncio.wait_for(ack_evt.wait(), timeout=10.0)
            if ack_val[0] != 0:
                print(f"ERROR: omi storage rejected READ (ack={ack_val[0]})")
                return 2

            # Wait for data + done
            try:
                await asyncio.wait_for(done_evt.wait(), timeout=args.timeout)
            except asyncio.TimeoutError:
                if expected_size is not None and len(buf) >= expected_size - SD_BLE_SIZE:
                    print(f"  (timeout but got {len(buf)} bytes ~= expected {expected_size})")
                else:
                    print(f"WARN: timeout after {len(buf)} bytes (expected {expected_size})")
        finally:
            try:
                await client.stop_notify(ctrl_ch)
            except Exception:
                pass

    elapsed = time.monotonic() - t0
    out_path.write_bytes(bytes(buf))
    print(f"\nWrote {len(buf)} bytes to {out_path} in {elapsed:.1f}s")

    # SD framing on a01.txt is raw [length:u32 LE][frame] entries
    print(f"\nDecoding to WAV ({wav_path}) ...")
    try:
        n_ok, n_err, dur = _decode_to_wav(out_path, wav_path, "sd")
        print(f"  decoded frames: {n_ok}  errors: {n_err}  duration: {dur:.2f}s")
    except Exception as e:
        print(f"  decode failed: {e}")
        return 1
    return 0


async def cmd_diag_poll(args) -> int:
    """Poll file_num_array via repeated short BLE connects.

    Diagnoses whether SD writes are happening on-device:
      * Each iteration: connect briefly, read omi storage read char
        (file_num_array[2] = uint32 LE pair), disconnect.
      * Every fresh BLE connect makes the firmware mark
        `file_size_updated = false`, so the next pusher iteration calls
        update_file_size() → fresh get_file_size("audio/a01.txt") →
        fresh fs_stat. So each poll is a real probe of disk state.
      * Run for `--seconds` total at `--interval` s between polls.

    Output: a CSV-like table of (t_s, file_num_array[0], file_num_array[1]).
    If [0] grows over time, SD writes are happening (patch 0032 worked).
    If it stays 0 forever, write_to_storage is still not reaching disk.
    """
    target, addr, label = await resolve_target(args.mac)
    print(f"Target: {addr}  {label}")
    print("t_s  array[0]  array[1]")
    t0 = time.monotonic()
    deadline = t0 + args.seconds
    while time.monotonic() < deadline:
        elapsed = time.monotonic() - t0
        try:
            async with BleakClient(target, timeout=10) as client:
                target_ch = None
                for svc in client.services:
                    if str(svc.uuid).lower() != "30295780-4301-eabd-2904-2849adfeae43":
                        continue
                    for ch in svc.characteristics:
                        if (str(ch.uuid).lower() == "30295782-4301-eabd-2904-2849adfeae43"
                                and "read" in ch.properties):
                            target_ch = ch
                            break
                    if target_ch:
                        break
                if not target_ch:
                    print(f"{elapsed:5.1f}  (no storage read char)")
                else:
                    data = await client.read_gatt_char(target_ch)
                    if len(data) >= 8:
                        import struct
                        a, b = struct.unpack("<II", data[:8])
                        print(f"{elapsed:5.1f}  {a:8d}  {b:8d}")
                    else:
                        print(f"{elapsed:5.1f}  short read ({len(data)} bytes)")
        except Exception as e:
            print(f"{elapsed:5.1f}  ERR: {e}")
        # Sleep between polls; this is also when the device records
        # without a BLE client gating SD writes.
        await asyncio.sleep(args.interval)
    return 0


async def cmd_play(args) -> int:
    """Play back a WAV file (or auto-decode an .opus_sd) via PC speakers.

    Useful for verifying captured audio sounds right. Uses the OS's
    default audio device — winsound on Windows, aplay on Linux,
    afplay on macOS — to avoid heavy deps.
    """
    in_path = Path(args.input)
    if not in_path.is_file():
        print(f"input not found: {in_path}")
        return 1

    # Auto-decode .opus_sd to a temporary WAV first.
    if in_path.suffix == ".opus_sd":
        wav_path = in_path.with_suffix(".wav")
        if not wav_path.is_file() or wav_path.stat().st_mtime < in_path.stat().st_mtime:
            print(f"  decoding {in_path.name} -> {wav_path.name} ...")
            n_ok, n_err, dur = _decode_to_wav(in_path, wav_path, "sd")
            print(f"  decoded: {n_ok} frames, {dur:.2f}s, errors={n_err}")
        in_path = wav_path

    if in_path.suffix.lower() != ".wav":
        print(f"unsupported format: {in_path.suffix}")
        return 1

    print(f"playing {in_path.name} ...")
    import platform
    sys_name = platform.system()
    if sys_name == "Windows":
        import winsound
        winsound.PlaySound(str(in_path), winsound.SND_FILENAME)
    elif sys_name == "Linux":
        import subprocess
        subprocess.run(["aplay", str(in_path)])
    elif sys_name == "Darwin":
        import subprocess
        subprocess.run(["afplay", str(in_path)])
    else:
        print(f"unknown OS: {sys_name}")
        return 1
    print("  done.")
    return 0


async def cmd_decode(args) -> int:
    in_path = Path(args.input)
    if not in_path.is_file():
        print(f"input not found: {in_path}")
        return 1
    out_path = Path(args.out) if args.out else in_path.with_suffix(".wav")
    n_ok, n_err, dur = _decode_to_wav(in_path, out_path, args.format)
    print(f"decoded frames: {n_ok}  errors: {n_err}  duration: {dur:.2f}s")
    print(f"output: {out_path}")
    return 0 if n_ok > 0 else 2


# ----------------------------------------------------------------------------
# entrypoint
# ----------------------------------------------------------------------------
def build_parser() -> argparse.ArgumentParser:
    p = argparse.ArgumentParser(description=__doc__,
                                formatter_class=argparse.RawDescriptionHelpFormatter)
    sub = p.add_subparsers(dest="cmd", required=True)

    sp = sub.add_parser("scan", help="BLE scan")
    sp.set_defaults(func=cmd_scan)

    sp = sub.add_parser("info", help="connect and print device info")
    sp.add_argument("--mac", default=DEFAULT_MAC)
    sp.set_defaults(func=cmd_info)

    sp = sub.add_parser("ls", help="list SD-stored audio files")
    sp.add_argument("--mac", default=DEFAULT_MAC)
    sp.set_defaults(func=cmd_ls)

    sp = sub.add_parser("pull", help="download a file from SD over BLE")
    sp.add_argument("filename")
    sp.add_argument("--mac", default=DEFAULT_MAC)
    sp.add_argument("--out", default=None,
                    help="output path for the SD-framed blob (default: <filename>.opus_sd)")
    sp.set_defaults(func=cmd_pull)

    sp = sub.add_parser("stream", help="stream live audio for N seconds")
    sp.add_argument("--mac", default=DEFAULT_MAC)
    sp.add_argument("--seconds", type=int, default=30)
    sp.add_argument("--out", default="audio_stream.opus_sd")
    sp.set_defaults(func=cmd_stream)

    sp = sub.add_parser("omi-info", help="read omi-original storage file count (works when ls fails)")
    sp.add_argument("--mac", default=DEFAULT_MAC)
    sp.set_defaults(func=cmd_omi_info)

    sp = sub.add_parser("omi-pull",
                        help="pull a01.txt via omi-original Storage service (bypasses wr_storage)")
    sp.add_argument("--mac", default=DEFAULT_MAC)
    sp.add_argument("--file-num", type=int, default=1,
                    dest="file_num", help="omi file num (1 = a01.txt)")
    sp.add_argument("--out", default=None)
    sp.add_argument("--timeout", type=float, default=180.0,
                    help="overall transfer timeout seconds (default 180)")
    sp.set_defaults(func=cmd_omi_pull)

    sp = sub.add_parser("record", help="long-running BLE recording with PC-side rotation")
    sp.add_argument("--mac", default=DEFAULT_MAC)
    sp.add_argument("--prefix", default="rec",
                    help="output filename prefix (chunks become <prefix>_NNN.opus_sd)")
    sp.add_argument("--rotate-min", type=float, default=10.0,
                    help="rotate to a new file every N minutes (default 10, min 1)")
    sp.set_defaults(func=cmd_record)

    sp = sub.add_parser("reset", help="re-flash UF2 to recover from SD broken state")
    sp.add_argument("--uf2", default="artifacts/boot_cmd/firmware.uf2")
    sp.add_argument("--mac", default=DEFAULT_MAC)
    sp.set_defaults(func=cmd_reset)

    sp = sub.add_parser("diag-poll", help="repeatedly poll file_num_array to track SD writes over time")
    sp.add_argument("--mac", default=DEFAULT_MAC)
    sp.add_argument("--seconds", type=int, default=60)
    sp.add_argument("--interval", type=float, default=5.0,
                    help="seconds between polls (default 5)")
    sp.set_defaults(func=cmd_diag_poll)

    sp = sub.add_parser("play", help="play a captured WAV (or auto-decode .opus_sd) via PC speakers")
    sp.add_argument("input")
    sp.set_defaults(func=cmd_play)

    sp = sub.add_parser("decode", help="decode a captured stream to WAV")
    sp.add_argument("input")
    sp.add_argument("--out", default=None)
    sp.add_argument("--format", choices=("auto", "sd", "raw", "ogg"), default="auto")
    sp.set_defaults(func=cmd_decode)

    return p


def main() -> int:
    args = build_parser().parse_args()
    try:
        return asyncio.run(args.func(args))
    except KeyboardInterrupt:
        print("\nInterrupted.")
        return 130
    except (asyncio.TimeoutError, BleakError, OSError) as e:
        print(f"\nBLE error: {e}")
        return 1
    except RuntimeError as e:
        print(f"\nERROR: {e}")
        return 1


if __name__ == "__main__":
    sys.exit(main())
