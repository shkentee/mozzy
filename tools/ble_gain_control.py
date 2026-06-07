"""Read or change mojizo mic gain over BLE.

mojizo exposes an OMI-compatible gain characteristic:
  service 19b10010..., characteristic 19b10012..., value 0..8

It also keeps a mojizo diagnostic raw-gain characteristic:
  service/characteristic 19b10007..., raw Nordic PDM gain byte

Usage:
    python ble_gain_control.py status [--mac FF:94:C9:1A:C9:B3]
    python ble_gain_control.py level 5 [--mac FF:94:C9:1A:C9:B3]
    python ble_gain_control.py raw 64  [--mac FF:94:C9:1A:C9:B3]
"""
from __future__ import annotations

import argparse
import asyncio
import sys

try:
    from bleak import BleakClient, BleakScanner
except ImportError:
    print("bleak not installed. pip install bleak")
    sys.exit(1)


OMI_GAIN_CHAR = "19b10012-e8f2-537e-4f6c-d104768a1214"
RAW_GAIN_CHAR = "19b10007-e8f2-537e-4f6c-d104768a1214"
DEFAULT_NAME = "mojizo"
GAIN_LABELS = [
    "Mute",
    "-20dB",
    "-10dB",
    "+0dB",
    "+6dB",
    "+10dB",
    "+20dB",
    "+30dB",
    "+40dB",
]
RAW_GAIN_BY_LEVEL = [0, 20, 30, 40, 46, 50, 64, 70, 80]


async def find_device(name_hint: str = DEFAULT_NAME, timeout: int = 8):
    print(f"Scanning {timeout}s for '{name_hint}'...")
    devices = await BleakScanner.discover(timeout=timeout)
    for d in devices:
        name = d.name or ""
        if name_hint.lower() in name.lower():
            return d
    for d in devices:
        name = d.name or ""
        if any(k in name.lower() for k in ("friend", "omi", "recorder")):
            return d
    return None


async def resolve_target(mac: str | None):
    if mac:
        print(f"Scanning 8s for address {mac}...")
        device = await BleakScanner.find_device_by_address(mac, timeout=8)
        if device is not None:
            return device, device.address, device.name or "(by MAC)"
        return mac, mac, "(by MAC)"
    device = await find_device()
    if device is None:
        raise RuntimeError("mojizo device not found in scan.")
    return device, device.address, device.name or "(unnamed)"


def level_from_raw_gain(raw_gain: int) -> int:
    return min(
        range(len(RAW_GAIN_BY_LEVEL)),
        key=lambda i: abs(RAW_GAIN_BY_LEVEL[i] - raw_gain),
    )


def describe_raw_gain(raw_gain: int) -> str:
    level = level_from_raw_gain(raw_gain)
    return f"raw_gain=0x{raw_gain:02x}({raw_gain}) level={level} {GAIN_LABELS[level]}"


def find_char(client: BleakClient, uuid: str):
    uuid = uuid.lower()
    for svc in client.services:
        for ch in svc.characteristics:
            if str(ch.uuid).lower() == uuid:
                return ch
    return None


def describe_omi(level: int) -> str:
    level = max(0, min(level, len(GAIN_LABELS) - 1))
    raw_gain = RAW_GAIN_BY_LEVEL[level]
    return f"omi_level={level} {GAIN_LABELS[level]} raw_gain=0x{raw_gain:02x}({raw_gain})"


async def read_omi_gain(client: BleakClient) -> int:
    ch = find_char(client, OMI_GAIN_CHAR)
    if ch is None:
        raise RuntimeError("OMI gain characteristic not found")
    data = await client.read_gatt_char(ch)
    if not data:
        raise RuntimeError("empty OMI gain value")
    return int(data[0])


async def read_raw_gain(client: BleakClient) -> int:
    ch = find_char(client, RAW_GAIN_CHAR)
    if ch is None:
        raise RuntimeError("raw gain characteristic not found")
    data = await client.read_gatt_char(ch)
    if not data:
        raise RuntimeError("empty raw gain value")
    return int(data[0])


async def read_preferred_gain(client: BleakClient) -> tuple[str, int]:
    try:
        return "omi", await read_omi_gain(client)
    except Exception:
        return "raw", await read_raw_gain(client)


async def main() -> int:
    parser = argparse.ArgumentParser()
    sub = parser.add_subparsers(dest="command", required=True)

    sp = sub.add_parser("status")
    sp.add_argument("--mac", help="MAC address (skip scan)")

    sp = sub.add_parser("level")
    sp.add_argument("value", type=int, choices=range(0, len(RAW_GAIN_BY_LEVEL)))
    sp.add_argument("--mac", help="MAC address (skip scan)")

    sp = sub.add_parser("raw")
    sp.add_argument("value", type=int, choices=range(0, 81))
    sp.add_argument("--mac", help="MAC address (skip scan)")

    sp = sub.add_parser("q4")
    sp.add_argument("value", type=int, choices=range(0, 81))
    sp.add_argument("--mac", help="MAC address (skip scan)")

    args = parser.parse_args()

    target, address, label = await resolve_target(args.mac)
    print(f"Target: {address} {label}")

    async with BleakClient(target, timeout=10) as client:
        protocol, before = await read_preferred_gain(client)
        if protocol == "omi":
            print(f"Before: {describe_omi(before)}")
        else:
            print(f"Before: {describe_raw_gain(before)}")

        if args.command == "level":
            ch = find_char(client, OMI_GAIN_CHAR)
            if ch is not None:
                await client.write_gatt_char(ch, bytes([args.value]), response=True)
            else:
                ch = find_char(client, RAW_GAIN_CHAR)
                if ch is None:
                    raise RuntimeError("no writable gain characteristic found")
                await client.write_gatt_char(
                    ch, bytes([RAW_GAIN_BY_LEVEL[args.value]]), response=True
                )
            await asyncio.sleep(0.5)
        elif args.command in ("raw", "q4"):
            ch = find_char(client, RAW_GAIN_CHAR)
            if ch is None:
                raise RuntimeError("raw gain characteristic not found")
            await client.write_gatt_char(ch, bytes([args.value]), response=True)
            await asyncio.sleep(0.5)

        protocol, after = await read_preferred_gain(client)
        if protocol == "omi":
            print(f"After: {describe_omi(after)}")
        else:
            print(f"After: {describe_raw_gain(after)}")

    return 0


if __name__ == "__main__":
    sys.exit(asyncio.run(main()))
