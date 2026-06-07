"""BLE client for the mojizo Storage GATT service.

Mirrors `app_mobile/lib/services/wr_storage_client.dart`. Talks to the
custom service exposed by `app/src/wr_storage_service.c` to:
  * LIST files on the device SD card
  * FETCH a named file as a contiguous byte blob
  * ABORT an in-flight transfer

Wire protocol (mirror of wr_storage_service.c):

  control writes (storageReadControl):
    0x00                       -> LIST
    0x01 + filename (ascii)    -> FETCH
    0xFF                       -> ABORT

  stream notifies (storageStream):
    0x01 + filename            -> file entry  (during LIST)
    0x02 + payload             -> data chunk  (during FETCH)
    0x03                       -> END         (terminator)
    0x04 + uint32_le size      -> file size   (during FETCH; optional)
    0xFF                       -> ERROR
"""
from __future__ import annotations

import asyncio
import sys
from typing import List, Optional

try:
    from bleak import BleakClient
except ImportError:
    print("bleak not installed. pip install bleak")
    sys.exit(1)


STORAGE_SERVICE       = "30295780-4301-eabd-2904-2849adfeae43"
STORAGE_STREAM_UUID   = "30295781-4301-eabd-2904-2849adfeae43"
STORAGE_CONTROL_UUID  = "30295782-4301-eabd-2904-2849adfeae43"

CMD_LIST  = 0x00
CMD_FETCH = 0x01
CMD_ABORT = 0xFF

NOTIF_FILE_ENTRY = 0x01
NOTIF_DATA       = 0x02
NOTIF_END        = 0x03
NOTIF_FILE_SIZE  = 0x04
NOTIF_ERROR      = 0xFF


def _resolve_storage_chars(client: BleakClient):
    """Pick the storage service whose chars match the expected properties.

    The firmware exposes two services with the same UUID (omi's original
    plus our own wr_storage_service); only one has the correct property
    set (notify-only stream + write-without-response control).
    Returns (stream_char, control_char) by handle to avoid UUID lookup
    ambiguity in bleak's resolver.
    """
    candidates = []
    for svc in client.services:
        if str(svc.uuid).lower() != STORAGE_SERVICE.lower():
            continue
        stream = ctrl = None
        for ch in svc.characteristics:
            uuid = str(ch.uuid).lower()
            if uuid == STORAGE_STREAM_UUID.lower():
                stream = ch
            elif uuid == STORAGE_CONTROL_UUID.lower():
                ctrl = ch
        if stream is not None and ctrl is not None:
            candidates.append((svc, stream, ctrl))

    if not candidates:
        raise RuntimeError("Storage service not found on device")

    for svc, stream, ctrl in candidates:
        if "notify" in stream.properties and "write-without-response" in ctrl.properties:
            return stream, ctrl

    svc, stream, ctrl = candidates[0]
    return stream, ctrl


class WrStorageClient:
    """Async BLE client for Storage service operations.

    Construct with an already-connected `BleakClient`. Subscribes to the
    stream characteristic on first use; call `close()` when done to send
    an ABORT and unsubscribe.
    """

    def __init__(self, client: BleakClient):
        self._client = client
        self._stream_ch, self._ctrl_ch = _resolve_storage_chars(client)
        self._sub_active = False
        self._handler = None  # set per-operation
        self._loop = asyncio.get_event_loop()

    async def _ensure_subscribed(self) -> None:
        if self._sub_active:
            return
        await self._client.start_notify(self._stream_ch, self._dispatch)
        self._sub_active = True

    def _dispatch(self, _sender, data: bytearray) -> None:
        if self._handler is not None:
            self._handler(bytes(data))

    async def list_files(self, timeout: float = 30.0) -> List[str]:
        files: List[str] = []
        done: asyncio.Future[None] = self._loop.create_future()

        def on_pkt(data: bytes) -> None:
            if not data:
                return
            tag = data[0]
            if tag == NOTIF_FILE_ENTRY:
                if len(data) > 1:
                    try:
                        files.append(data[1:].decode("utf-8", errors="replace"))
                    except Exception:
                        pass
            elif tag == NOTIF_END:
                if not done.done():
                    done.set_result(None)
            elif tag == NOTIF_ERROR:
                if not done.done():
                    done.set_exception(RuntimeError("Storage service error during LIST"))

        self._handler = on_pkt
        await self._ensure_subscribed()
        await self._client.write_gatt_char(
            self._ctrl_ch, bytearray([CMD_LIST]), response=False
        )
        try:
            await asyncio.wait_for(done, timeout=timeout)
        finally:
            self._handler = None
        return files

    async def fetch_file(
        self,
        filename: str,
        timeout: float = 300.0,
        on_progress=None,
    ) -> bytes:
        chunks: List[bytes] = []
        total = 0
        expected_size: Optional[int] = None
        done: asyncio.Future[None] = self._loop.create_future()

        def on_pkt(data: bytes) -> None:
            nonlocal total, expected_size
            if not data:
                return
            tag = data[0]
            if tag == NOTIF_DATA:
                if len(data) > 1:
                    payload = data[1:]
                    chunks.append(payload)
                    total += len(payload)
                    if on_progress is not None:
                        try:
                            on_progress(total)
                        except Exception:
                            pass
            elif tag == NOTIF_FILE_SIZE:
                if len(data) >= 5:
                    expected_size = int.from_bytes(data[1:5], "little")
            elif tag == NOTIF_END:
                if not done.done():
                    if expected_size is not None and total != expected_size:
                        done.set_exception(
                            RuntimeError(
                                f"Storage transfer incomplete for {filename}: "
                                f"received {total} of {expected_size} bytes"
                            )
                        )
                    else:
                        done.set_result(None)
            elif tag == NOTIF_ERROR:
                if not done.done():
                    done.set_exception(
                        RuntimeError(f"File not found on device: {filename}")
                    )

        self._handler = on_pkt
        await self._ensure_subscribed()

        cmd = bytearray([CMD_FETCH]) + filename.encode("ascii")
        await self._client.write_gatt_char(
            self._ctrl_ch, cmd, response=False
        )
        try:
            await asyncio.wait_for(done, timeout=timeout)
        finally:
            self._handler = None
        return b"".join(chunks)

    async def abort(self) -> None:
        try:
            await self._client.write_gatt_char(
                self._ctrl_ch, bytearray([CMD_ABORT]), response=False
            )
        except Exception:
            pass

    async def close(self) -> None:
        await self.abort()
        if self._sub_active:
            try:
                await self._client.stop_notify(self._stream_ch)
            except Exception:
                pass
            self._sub_active = False
