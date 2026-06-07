"""Connect to the mojizo device and enumerate services.

Tests whether the BLE establishment that historically failed at 333ms
disconnect now actually completes. Connect → MTU → service discovery
→ stay connected for N seconds → graceful disconnect.

Usage: python ble_connect.py [--mac FF:94:C9:1A:C9:B3] [--hold 10]
"""
import argparse
import asyncio
import sys
import time

try:
    from bleak import BleakClient, BleakScanner
    from bleak.exc import BleakError
except ImportError:
    print("bleak not installed. pip install bleak")
    sys.exit(1)


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


async def main(mac: str | None, hold: int) -> int:
    if mac:
        target_addr = mac
        target_name = "(by MAC)"
    else:
        d = await find_device()
        if not d:
            print("mojizo device not found in scan.")
            return 2
        target_addr = d.address
        target_name = d.name

    print(f"\nTarget: {target_addr}  {target_name}\nConnecting...")

    t_start = time.monotonic()
    try:
        async with BleakClient(target_addr, timeout=10) as client:
            t_conn = time.monotonic() - t_start
            print(f"  connected in {t_conn:.2f}s, MTU={client.mtu_size}")

            # Enumerate services
            print("\nServices / characteristics:")
            for svc in client.services:
                print(f"  {svc.uuid}")
                for ch in svc.characteristics:
                    props = ",".join(ch.properties)
                    print(f"    {ch.uuid}  [{props}]")

            print(f"\nHolding connection for {hold}s...")
            await asyncio.sleep(hold)
            print("Disconnecting cleanly.")
        elapsed = time.monotonic() - t_start
        print(f"\nTotal session: {elapsed:.2f}s -- connection survived. [OK]")
        return 0
    except asyncio.TimeoutError:
        elapsed = time.monotonic() - t_start
        print(f"\nTimeout after {elapsed:.2f}s [FAIL]")
        return 1
    except BleakError as e:
        elapsed = time.monotonic() - t_start
        print(f"\nBleakError after {elapsed:.2f}s: {e} [FAIL]")
        return 1


if __name__ == "__main__":
    p = argparse.ArgumentParser()
    p.add_argument("--mac", help="MAC address (skip scan)")
    p.add_argument("--hold", type=int, default=10, help="seconds to hold connection")
    args = p.parse_args()
    sys.exit(asyncio.run(main(args.mac, args.hold)))
