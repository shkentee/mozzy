"""Read or change mojizo mic gain over BLE.

mojizo exposes mic gain as a Q4 fixed-point byte:
  16 = 1.0x, 32 = 2.0x, 96 = 6.0x

Usage:
    python ble_gain_control.py status [--mac FF:94:C9:1A:C9:B3]
    python ble_gain_control.py level 5 [--mac FF:94:C9:1A:C9:B3]
    python ble_gain_control.py q4 32  [--mac FF:94:C9:1A:C9:B3]
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


GAIN_CHAR = "19b10007-e8f2-537e-4f6c-d104768a1214"
DEFAULT_NAME = "mojizo"
Q4_BY_LEVEL = [4, 8, 12, 16, 24, 32, 48, 64, 96]


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


def level_from_q4(q4: int) -> int:
    return min(range(len(Q4_BY_LEVEL)), key=lambda i: abs(Q4_BY_LEVEL[i] - q4))


def describe(q4: int) -> str:
    level = level_from_q4(q4)
    return f"q4={q4} level={level} ({q4 / 16:.2f}x)"


async def read_gain(client: BleakClient) -> int:
    data = await client.read_gatt_char(GAIN_CHAR)
    if not data:
        raise RuntimeError("empty gain value")
    return int(data[0])


async def main() -> int:
    parser = argparse.ArgumentParser()
    sub = parser.add_subparsers(dest="command", required=True)

    sp = sub.add_parser("status")
    sp.add_argument("--mac", help="MAC address (skip scan)")

    sp = sub.add_parser("level")
    sp.add_argument("value", type=int, choices=range(0, len(Q4_BY_LEVEL)))
    sp.add_argument("--mac", help="MAC address (skip scan)")

    sp = sub.add_parser("q4")
    sp.add_argument("value", type=int, choices=range(1, 256))
    sp.add_argument("--mac", help="MAC address (skip scan)")

    args = parser.parse_args()

    target, address, label = await resolve_target(args.mac)
    print(f"Target: {address} {label}")

    async with BleakClient(target, timeout=10) as client:
        before = await read_gain(client)
        print(f"Before: {describe(before)}")

        if args.command == "level":
            await client.write_gatt_char(
                GAIN_CHAR, bytes([Q4_BY_LEVEL[args.value]]), response=True
            )
            await asyncio.sleep(0.5)
        elif args.command == "q4":
            await client.write_gatt_char(GAIN_CHAR, bytes([args.value]), response=True)
            await asyncio.sleep(0.5)

        after = await read_gain(client)
        print(f"After: {describe(after)}")

    return 0


if __name__ == "__main__":
    sys.exit(asyncio.run(main()))
