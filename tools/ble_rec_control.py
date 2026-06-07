"""Read or change mojizo SD recording state over BLE.

Usage:
    python ble_rec_control.py status [--mac FF:94:C9:1A:C9:B3]
    python ble_rec_control.py off    [--mac FF:94:C9:1A:C9:B3]
    python ble_rec_control.py on     [--mac FF:94:C9:1A:C9:B3]
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


REC_CONTROL_CHAR = "19b10006-e8f2-537e-4f6c-d104768a1214"
DEFAULT_NAME = "mojizo"


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
        return mac, "(by MAC)"
    device = await find_device()
    if device is None:
        raise RuntimeError("mojizo device not found in scan.")
    return device.address, device.name or "(unnamed)"


async def read_state(client: BleakClient) -> bool:
    data = await client.read_gatt_char(REC_CONTROL_CHAR)
    return bool(data and data[0] != 0)


async def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("command", choices=["status", "on", "off"])
    parser.add_argument("--mac", help="MAC address (skip scan)")
    args = parser.parse_args()

    address, label = await resolve_target(args.mac)
    print(f"Target: {address} {label}")

    async with BleakClient(address, timeout=10) as client:
        before = await read_state(client)
        print(f"Before: {'on' if before else 'off'}")

        if args.command != "status":
            await client.write_gatt_char(
                REC_CONTROL_CHAR,
                bytes([1 if args.command == "on" else 0]),
                response=True,
            )
            await asyncio.sleep(0.5)

        after = await read_state(client)
        print(f"After: {'on' if after else 'off'}")

    return 0


if __name__ == "__main__":
    sys.exit(asyncio.run(main()))
