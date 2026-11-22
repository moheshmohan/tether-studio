#!/usr/bin/env python3
"""How fast does the camera send over its own Wi-Fi, with the board's USB cable out of the picture?

The board joins the camera's network as usual. This script opens a card session through it, then asks the
camera for pieces of the largest file on the card while the board counts the bytes that arrive and throws
them away (bridge program version 5 or later). Nothing is written anywhere and nothing on the card changes.

    .venv/bin/python esp32_bridge/camera_speed.py            # the app and relay.py must not be running
"""
import argparse
import os
import struct
import sys
import time

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
sys.path.insert(0, os.path.dirname(HERE))

import relay                                                        # noqa: E402
from zve10 import codes as c, ptpip                                 # noqa: E402
from zve10.__main__ import client_guid, open_card                   # noqa: E402
from zve10.camera import Camera                                     # noqa: E402

MB = 1024 * 1024


def main():
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--serial")
    parser.add_argument("--wifi-file", default=os.path.join(HERE, "camera_wifi.txt"))
    parser.add_argument("--sizes", default="3,3,3,3,16,16,48", help="piece sizes to ask for, in MB")
    args = parser.parse_args()

    port = args.serial or relay.find_port()
    if not port:
        sys.exit("No ESP32 board found on USB.")
    bridge = relay.Bridge(relay.open_serial(port), log=lambda text: print(text, flush=True))
    camera = None
    try:
        if not bridge.wait_for_board():
            sys.exit("The board does not answer.")
        if bridge.version < 5:
            sys.exit(f"The board runs bridge program version {bridge.version}; this test needs version 5.")
        name, secret = relay.read_wifi_file(args.wifi_file)
        state = bridge.join(name, secret)
        print(f"Camera network: {relay.describe_wifi(state)}", flush=True)
        if not state or state[0] != relay.WIFI_JOINED:
            sys.exit(1)
        bridge.listen(15740, lambda: bridge.wifi[3], 15740)

        camera = Camera("127.0.0.1", ptpip.Trace(), client_guid(os.path.join(os.path.dirname(HERE), ".zve10_client_guid")),
                        service="smartphone")
        for attempt in range(4):            # the camera may still be letting go of an earlier session
            try:
                listed = open_card(camera)
                break
            except ptpip.LinkError:
                if attempt == 3:
                    raise
                camera.link = None
                time.sleep(1.5)
        entries = [e for e in listed if not e.is_folder and e.size]
        big = max(entries, key=lambda e: e.size)
        print(f"Reading from {big.name} ({big.size / 1e6:.0f} MB); signal at the board {bridge.wifi[4]} dBm", flush=True)

        op = next(op for op in (c.SDIO_GET_PARTIAL_LARGE_OBJECT, c.SDIO_GET_PARTIAL_LARGE_OBJECT_OLD) if op in camera.ops)
        offset, results = 0, []
        for size in [int(float(s) * MB) for s in args.sizes.split(",")]:
            if offset + size > big.size:
                offset = 0
            link = camera.link

            def request():
                with link._lock:
                    tid, link._tid = link._tid, link._tid + 1
                    ptpip._send(link._cmd, ptpip.CMD_REQUEST, struct.pack(
                        "<IHI4I", 1, op, tid,
                        big.handle, offset & 0xFFFFFFFF, offset >> 32, size))
            got = bridge.drain(request)
            if not got:
                print(f"  {size / MB:5.0f} MB at {offset}: nothing arrived")
                break
            count, seconds = got
            whole = count >= size
            rate = count / 1e6 / max(seconds, 1e-6)
            print(f"  asked {size / MB:5.0f} MB at {offset:>11}: {count} bytes arrived in {seconds:6.2f} s = {rate:5.2f} MB/s"
                  + ("" if whole else "   (LESS than asked: the camera refused or cut the piece)"), flush=True)
            if whole:
                results.append((size, rate))
            offset += size
        if results:
            best = max(rate for _, rate in results)
            print(f"Fastest piece: {best:.2f} MB/s = {best * 8:.1f} Mbit/s (camera and board radio together, no USB)")
    finally:
        if camera is not None:
            try:
                camera.close()
            except Exception as err:               # the session may be out of step after a cut piece
                print(f"(closing the session: {err})")
        bridge.close()


if __name__ == "__main__":
    main()
