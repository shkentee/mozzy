#!/usr/bin/env python3
"""
opus_to_wav.py — decode raw Opus frames (no Ogg container) to a playable WAV.

Designed for the mojizo / omi-devkit Zephyr firmware which encodes
audio with libopus at:
    sample rate : 16000 Hz
    channels    : 1 (mono)
    bitrate     : 32000 bps VBR
    application : OPUS_APPLICATION_RESTRICTED_LOWDELAY
    frame size  : 100 ms (1600 samples per frame at 16 kHz)
    LSB depth   : 16 bits

Two input formats are supported:

  1. SD-card format (omi devkit `a01.txt` and friends):
         [length_byte][opus_frame][length_byte][opus_frame]...
     Each frame is preceded by a single byte that tells you how many bytes
     the frame occupies. 0-length entries are skipped (firmware sometimes
     pads). This is the recommended format because frame boundaries are
     unambiguous.

  2. BLE-received raw format (`audio.opus_raw`):
         [opus_frame][opus_frame][opus_frame]...
     Frames are concatenated with NO length prefix. This format is
     INHERENTLY AMBIGUOUS — Opus is a self-synchronising codec only inside
     an Ogg/RTP container; once the framing is gone, you cannot reliably
     split the stream back into packets. We provide a fallback that ASSUMES
     a fixed bytes-per-frame value (`--frame-bytes N`); without that, raw
     mode will almost certainly fail.

     RECOMMENDED WORKFLOW: have the BLE receiver re-frame the stream into
     SD-style `[length][frame]` records during reception (one byte of
     overhead per ~100 ms frame is negligible), or log packet boundaries
     alongside the audio. Then feed the result to this script with
     `--format sd`.

CLI:
    python opus_to_wav.py INPUT [--format raw|sd|auto] [--out OUTPUT.wav]
                                [--rate 16000] [--channels 1]
                                [--frame-bytes N]

Dependencies:
    pip install opuslib
"""

from __future__ import annotations

import argparse
import os
import struct
import sys
import wave
from typing import Iterator, List, Optional, Tuple

# ----------------------------------------------------------------------------
# Opus decoder via pyogg (bundles libopus DLL on all platforms — no extra
# system deps needed). We talk to libopus through pyogg.opus's ctypes
# bindings directly, since pyogg itself doesn't expose a high-level raw
# Opus decoder class.
# ----------------------------------------------------------------------------
try:
    import ctypes
    import pyogg.opus as _opus  # type: ignore
except ImportError:
    sys.stderr.write(
        "ERROR: pyogg is not installed.\n"
        "       Install it with:    pip install pyogg\n"
    )
    sys.exit(2)


class _OpusDecoder:
    """Thin wrapper around pyogg's bundled libopus.

    Equivalent to opuslib.Decoder but uses pyogg's pre-bundled DLL so we
    don't need a system-wide libopus install on Windows.
    """

    def __init__(self, rate: int, channels: int):
        err = ctypes.c_int()
        self._dec = _opus.libopus.opus_decoder_create(
            rate, channels, ctypes.byref(err)
        )
        if err.value != _opus.OPUS_OK or not self._dec:
            raise RuntimeError(f"opus_decoder_create failed: {err.value}")
        self._channels = channels

    def decode(self, packet: bytes, max_samples: int) -> bytes:
        out = (ctypes.c_int16 * (max_samples * self._channels))()
        # opus_decode signature: pointer to unsigned char input + pointer
        # to int16 output. Build via from_buffer_copy (bytes -> c_ubyte
        # array) and cast to the pointer types pyogg's argtypes expect.
        in_arr = (ctypes.c_ubyte * len(packet)).from_buffer_copy(packet)
        in_ptr = ctypes.cast(in_arr, ctypes.POINTER(ctypes.c_ubyte))
        out_ptr = ctypes.cast(out, ctypes.POINTER(ctypes.c_int16))
        n = _opus.libopus.opus_decode(
            self._dec,
            in_ptr,
            len(packet),
            out_ptr,
            max_samples,
            0,  # decode_fec
        )
        if n < 0:
            raise RuntimeError(f"opus_decode failed: {n}")
        # n samples per channel returned; total int16s = n * channels.
        # Use string_at for raw bytes — bytes(c_int16_array) iterates ints
        # and chokes on negative samples.
        return ctypes.string_at(out, n * self._channels * ctypes.sizeof(ctypes.c_int16))

    def __del__(self):
        try:
            if getattr(self, "_dec", None):
                _opus.libopus.opus_decoder_destroy(self._dec)
        except Exception:
            pass


# ----------------------------------------------------------------------------
# Constants matching the firmware encoder
# ----------------------------------------------------------------------------
DEFAULT_RATE     = 16000
DEFAULT_CHANNELS = 1
FRAME_MS         = 100                                  # 100 ms frames
SAMPLES_PER_FRAME_AT_16K = DEFAULT_RATE * FRAME_MS // 1000   # 1600
# Maximum decoded samples we ever ask libopus to produce per packet.
# 120 ms at 48 kHz is the libopus upper bound for a single packet.
MAX_DECODE_SAMPLES = 48000 * 120 // 1000                # 5760


# ----------------------------------------------------------------------------
# Format detection
# ----------------------------------------------------------------------------
OGG_MAGIC = b"OggS"


def detect_format(buf: bytes) -> str:
    """Return 'ogg', 'sd', or 'raw' based on a quick heuristic."""
    if not buf:
        return "raw"
    if buf.startswith(OGG_MAGIC):
        return "ogg"
    # SD format: first byte is a length byte, typically << 128 (frames at
    # 32 kbps VBR / 100 ms are ~50–100 bytes). Raw frames begin with a TOC
    # byte whose top bits encode mode/bandwidth/channels; for our encoder
    # settings the TOC is usually >= 0x78 (>=120). The 128 cutoff is the
    # heuristic the spec asks for.
    return "sd" if buf[0] < 128 else "raw"


# ----------------------------------------------------------------------------
# Frame iterators
# ----------------------------------------------------------------------------
def iter_sd_frames(buf: bytes) -> Iterator[bytes]:
    """Yield Opus frames from an SD-format buffer.

    Format: [length_byte][frame_bytes...] repeated. 0-length entries are
    skipped (omi firmware pads with zero bytes occasionally).
    """
    i = 0
    n = len(buf)
    while i < n:
        length = buf[i]
        i += 1
        if length == 0:
            # padding / terminator — keep scanning
            continue
        end = i + length
        if end > n:
            sys.stderr.write(
                f"WARN: truncated SD frame at offset {i-1}: "
                f"declared {length} bytes, only {n-i} remaining; stopping.\n"
            )
            break
        yield buf[i:end]
        i = end


def iter_raw_fixed_frames(buf: bytes, frame_bytes: int) -> Iterator[bytes]:
    """Yield Opus frames assuming a fixed bytes-per-frame size.

    This is a best-effort fallback for the un-framed BLE stream and is
    almost guaranteed to produce garbage with VBR encoding. Use only when
    you know the encoder was running CBR with the exact frame size you
    pass in.
    """
    if frame_bytes <= 0:
        raise ValueError("--frame-bytes must be > 0 for raw mode")
    n = len(buf)
    i = 0
    while i + frame_bytes <= n:
        yield buf[i:i + frame_bytes]
        i += frame_bytes
    leftover = n - i
    if leftover:
        sys.stderr.write(
            f"WARN: raw mode dropped {leftover} trailing bytes "
            f"(not a multiple of frame_bytes={frame_bytes}).\n"
        )


# ----------------------------------------------------------------------------
# Decoder driver
# ----------------------------------------------------------------------------
def decode_frames(
    frames: Iterator[bytes],
    rate: int,
    channels: int,
) -> Tuple[bytes, int, int]:
    """Decode an iterable of Opus packets into an interleaved 16-bit PCM
    blob. Returns (pcm_bytes, num_frames_decoded, num_decode_errors)."""
    decoder = _OpusDecoder(rate, channels)

    pcm_chunks: List[bytes] = []
    n_ok = 0
    n_err = 0
    for idx, packet in enumerate(frames):
        if not packet:
            continue
        try:
            pcm = decoder.decode(packet, MAX_DECODE_SAMPLES)
        except Exception as e:
            n_err += 1
            sys.stderr.write(
                f"WARN: decode error on packet #{idx} "
                f"({len(packet)} bytes): {e}\n"
            )
            continue
        pcm_chunks.append(pcm)
        n_ok += 1

    return b"".join(pcm_chunks), n_ok, n_err


# ----------------------------------------------------------------------------
# Optional Ogg/Opus container support
# ----------------------------------------------------------------------------
def iter_ogg_opus_packets(buf: bytes) -> Iterator[bytes]:
    """Minimal Ogg page parser that yields Opus packet payloads.

    Skips the two header packets (OpusHead + OpusTags). Handles packet
    continuation across pages via the segment table.
    """
    i = 0
    n = len(buf)
    pending = bytearray()
    header_packets_seen = 0
    while i + 27 <= n:
        if buf[i:i+4] != OGG_MAGIC:
            sys.stderr.write(f"WARN: lost Ogg sync at offset {i}\n")
            return
        # Ogg page header layout (27 bytes + segment table):
        #   0..3  "OggS"
        #   4     stream structure version
        #   5     header type flag
        #   6..13 granule position
        #   14..17 bitstream serial number
        #   18..21 page sequence number
        #   22..25 CRC checksum
        #   26    page segments (n)
        #   27..27+n segment lengths
        n_segs = buf[i + 26]
        seg_table_end = i + 27 + n_segs
        if seg_table_end > n:
            return
        seg_lengths = buf[i + 27:seg_table_end]
        data_start = seg_table_end
        cursor = data_start
        # Re-assemble packets from segments.
        for seg_len in seg_lengths:
            pending.extend(buf[cursor:cursor + seg_len])
            cursor += seg_len
            if seg_len < 255:
                # packet boundary
                if pending:
                    if header_packets_seen < 2:
                        header_packets_seen += 1
                    else:
                        yield bytes(pending)
                pending = bytearray()
        i = cursor


# ----------------------------------------------------------------------------
# WAV writer
# ----------------------------------------------------------------------------
def write_wav(path: str, pcm: bytes, rate: int, channels: int) -> None:
    with wave.open(path, "wb") as w:
        w.setnchannels(channels)
        w.setsampwidth(2)        # 16-bit
        w.setframerate(rate)
        w.writeframes(pcm)


# ----------------------------------------------------------------------------
# Main
# ----------------------------------------------------------------------------
def parse_args(argv: Optional[List[str]] = None) -> argparse.Namespace:
    p = argparse.ArgumentParser(
        description=(
            "Decode raw Opus frames (BLE or SD-card capture from the "
            "mojizo firmware) into a playable WAV file."
        ),
        formatter_class=argparse.RawDescriptionHelpFormatter,
        epilog=(
            "Note on raw mode: the BLE-received `audio.opus_raw` stream has\n"
            "no frame boundaries, which is fundamentally ambiguous for Opus.\n"
            "Prefer SD-card capture (`--format sd`), or modify the BLE\n"
            "receiver to prepend a 1-byte length to each packet before\n"
            "writing it to disk. Raw mode here is a best-effort fallback\n"
            "that requires `--frame-bytes N` to split the stream.\n"
        ),
    )
    p.add_argument("input", help="Path to .opus_raw / a01.txt / .opus file")
    p.add_argument(
        "--format",
        choices=("auto", "raw", "sd", "ogg"),
        default="auto",
        help="Input framing (default: auto-detect)",
    )
    p.add_argument(
        "--out", "-o",
        default=None,
        help="Output WAV path (default: alongside input, .wav extension)",
    )
    p.add_argument(
        "--rate", type=int, default=DEFAULT_RATE,
        help=f"Decoder sample rate in Hz (default: {DEFAULT_RATE})",
    )
    p.add_argument(
        "--channels", type=int, default=DEFAULT_CHANNELS,
        help=f"Channel count (default: {DEFAULT_CHANNELS})",
    )
    p.add_argument(
        "--frame-bytes", type=int, default=0,
        help="Bytes per Opus frame for raw mode (required for raw input)",
    )
    return p.parse_args(argv)


def main(argv: Optional[List[str]] = None) -> int:
    args = parse_args(argv)

    in_path = args.input
    if not os.path.isfile(in_path):
        sys.stderr.write(f"ERROR: input not found: {in_path}\n")
        return 1

    with open(in_path, "rb") as f:
        buf = f.read()
    in_bytes = len(buf)

    fmt = args.format
    if fmt == "auto":
        fmt = detect_format(buf)
        sys.stderr.write(f"INFO: auto-detected format: {fmt}\n")

    if fmt == "sd":
        frame_iter = iter_sd_frames(buf)
    elif fmt == "ogg":
        frame_iter = iter_ogg_opus_packets(buf)
    elif fmt == "raw":
        if args.frame_bytes <= 0:
            sys.stderr.write(
                "ERROR: raw format requires --frame-bytes N "
                "(the BLE stream has no frame boundaries; this is a known\n"
                "       limitation — see --help). Recommended workaround:\n"
                "       re-record using the SD-card path, OR have the BLE\n"
                "       receiver prepend a 1-byte length per packet and\n"
                "       run with `--format sd`.\n"
            )
            return 2
        frame_iter = iter_raw_fixed_frames(buf, args.frame_bytes)
    else:
        sys.stderr.write(f"ERROR: unknown format: {fmt}\n")
        return 2

    pcm, n_ok, n_err = decode_frames(frame_iter, args.rate, args.channels)

    out_path = args.out or (os.path.splitext(in_path)[0] + ".wav")
    write_wav(out_path, pcm, args.rate, args.channels)

    n_samples = len(pcm) // (2 * args.channels)
    duration_s = n_samples / float(args.rate) if args.rate else 0.0

    print("---- opus_to_wav stats ----")
    print(f"input file       : {in_path}")
    print(f"input bytes      : {in_bytes}")
    print(f"format           : {fmt}")
    print(f"frames decoded   : {n_ok}")
    print(f"decode errors    : {n_err}")
    print(f"output samples   : {n_samples}")
    print(f"output duration  : {duration_s:.3f} s")
    print(f"output file      : {out_path}")
    return 0 if n_ok > 0 else 3


if __name__ == "__main__":
    raise SystemExit(main())
