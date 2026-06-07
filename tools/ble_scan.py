"""Quick BLE scan to verify the mojizo device is advertising.

Usage: python ble_scan.py [--seconds 8]

Looks for mojizo plus legacy names (Friend, omi, Omi, Recorder) and prints all
advertisements with name + RSSI + MAC.
"""
import argparse
import asyncio
import sys

try:
    from bleak import BleakScanner
except ImportError:
    print("bleak not installed. pip install bleak")
    sys.exit(1)


async def main(seconds: int) -> None:
    print(f"Scanning {seconds} seconds for BLE advertisements...\n")
    seen: dict[str, tuple[str | None, int]] = {}

    def cb(device, adv) -> None:
        name = adv.local_name or device.name
        seen[device.address] = (name, adv.rssi)

    scanner = BleakScanner(detection_callback=cb)
    await scanner.start()
    await asyncio.sleep(seconds)
    await scanner.stop()

    if not seen:
        print("No advertisements detected in window.")
        return

    print(f"Detected {len(seen)} unique devices:")
    likely = []
    for addr, (name, rssi) in sorted(seen.items(), key=lambda x: x[1][1] or -200, reverse=True):
        nm = name or "(no name)"
        marker = ""
        if name and any(k in name.lower() for k in ("mojizo", "mojio", "friend", "omi", "recorder", "wearable")):
            marker = "  <-- LIKELY OURS"
            likely.append((addr, name, rssi))
        print(f"  {addr}  RSSI {rssi:>4} dBm  {nm}{marker}")

    if likely:
        print(f"\nLikely mojizo device(s): {len(likely)}")
        for addr, name, rssi in likely:
            print(f"  -> {addr}  {name}  RSSI {rssi}")
    else:
        print("\nNo mojizo-like names. The board may not be advertising -- check transport_start log.")


if __name__ == "__main__":
    p = argparse.ArgumentParser()
    p.add_argument("--seconds", type=int, default=8)
    args = p.parse_args()
    asyncio.run(main(args.seconds))
