"""One run that answers: on the camera's own Wi-Fi (Smartphone Connect), does a ZV-E10 let one computer record
AND read the memory card, switching between the two by command?

Run it while this Mac's Wi-Fi is joined to the camera's DIRECT-... network (the Mac is offline meanwhile):

    .venv/bin/python probe/smartphone_connect_test.py

Every step runs even when an earlier one fails, and everything is written to two files in logs/:
the report (what you see on screen) and the protocol log (every message to and from the camera).
Nothing on the card is changed or deleted; the test records one short clip and downloads it.
"""
import argparse
import os
import re
import socket
import struct
import sys
import threading
import time

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
sys.path.insert(0, ROOT)

from zve10 import codes as c                                                    # noqa: E402
from zve10 import datasets as ds                                                # noqa: E402
from zve10 import discovery                                                     # noqa: E402
from zve10.__main__ import client_guid, size_text                               # noqa: E402
from zve10.camera import REMOTE, TRANSFER, Camera, CameraError, newest_video    # noqa: E402
from zve10.ptpip import PORT, Link, LinkError, Trace                            # noqa: E402

PORTS = {15740: "PTP/IP (control and files)", 64321: "description", 60152: "device info", 10000: "old remote API",
         8080: "old remote API", 80: "http", 443: "https", 22: "ssh", 21: "ftp"}
FLAGS = ("X_ServerType", "X_ServerVersion", "X_PTP_Versions", "X_PTP_PairingNecessity", "X_PTP_MediaServerSupport",
         "X_PTP_RemoteControlSupport", "X_PTP_ContentsTransferSupport", "X_SSH_Support")
CARD = c.STORAGE_CARD
ERRORS = (CameraError, LinkError, OSError, struct.error, ValueError, IndexError, KeyError)


class Report:
    def __init__(self, path):
        self.file = open(path, "w", encoding="utf-8")
        self.results = []           # (step, True / False / None, detail)

    def say(self, text=""):
        print(text, flush=True)
        self.file.write(text + "\n")
        self.file.flush()

    def result(self, step, ok, detail=""):
        self.results.append((step, ok, detail))
        mark = {True: "YES", False: "NO ", None: "-- "}[ok]
        self.say(f"   => {mark} {step}" + (f": {detail}" if detail else ""))


def port_open(host, port, timeout=1.5):
    try:
        socket.create_connection((host, port), timeout=timeout).close()
        return True
    except OSError:
        return False


def scan_for_camera(report):
    """Addresses on this Mac's own networks that accept connections on the camera's control port."""
    hits, threads = [], []

    def check(host):
        if port_open(host, PORT, 1.5):
            hits.append(host)
    for ip in discovery._local_ipv4():
        base = ip.rsplit(".", 1)[0]
        for last in range(1, 255):
            host = f"{base}.{last}"
            if host != ip:
                threads.append(threading.Thread(target=check, args=(host,), daemon=True))
    for batch in range(0, len(threads), 128):
        for thread in threads[batch:batch + 128]:
            thread.start()
        for thread in threads[batch:batch + 128]:
            thread.join()
    report.say(f"   scan of this Mac's networks for port {PORT}: {hits or 'nothing answered'}")
    return hits


def find_camera(args, report, trace):
    report.say("\n[1] Network and camera")
    ips = discovery._local_ipv4()
    report.say(f"   this Mac's addresses: {ips or 'none'}")
    if not args.host and not any(ip.startswith("192.168.122.") for ip in ips):
        report.say("   NOTE: none of these is on 192.168.122.x, the camera's own network. If the Mac is still on the\n"
                   "   router, join the DIRECT-... network shown on the camera screen and run this again.")
    if args.host:
        found = discovery.describe_host(args.host) or discovery.Found(host=args.host)
    else:
        cameras, error = discovery.find_cameras(wait=4.0, trace=trace)
        if error:
            report.say(f"   search problem: {error}")
        found = cameras[0] if cameras else None
        if found is None:
            hits = scan_for_camera(report)
            if hits:
                found = discovery.describe_host(hits[0]) or discovery.Found(host=hits[0])
    if found is None:
        report.result("camera found", False, "nothing answers as a camera on this network")
        return None
    report.result("camera found", True, f"{found.model or 'camera'} at {found.host}")
    for flag in FLAGS:
        match = re.search(rf"<{flag}>([^<]*)</{flag}>", found.description or "")
        if match:
            report.say(f"   {flag}: {match.group(1)}")
    functions = re.findall(r'<X_Function name="([^"]+)"', found.description or "")
    if functions:
        report.say(f"   functions listed: {', '.join(functions)}")
    report.say(f"   service read from the description: {found.service or 'unknown (no description document)'}")
    if not args.port_given:
        listening = [f"{port} ({name})" for port, name in PORTS.items() if port_open(found.host, port)]
        report.say("   open ports: " + (", ".join(listening) or "none"))
    trace(f"description of {found.host}:\n{found.description}")
    return found


def describe_session(camera, report):
    report.say(f"   model {camera.info.model}, firmware {camera.info.version}, Sony protocol {camera.protocol}")
    report.say("   operations: " + " ".join(f"{op:04X}" for op in sorted(camera.ops)))
    report.say("   controls:   " + " ".join(f"{code:04X}" for code in sorted(camera.controls)))


def remote_and_record(camera, args, report):
    report.say(f"\n[2] Remote-control session and a {args.seconds:g} s recording")
    report.say("   If the camera shows a question now (pairing or connection), press OK on the camera.")
    started = time.monotonic()
    try:
        camera.open(REMOTE)
    except ERRORS as err:
        report.result("remote-control session", False, str(err))
        return False
    report.result("remote-control session", True, f"opened in {time.monotonic() - started:.1f} s")
    describe_session(camera, report)
    try:
        state = camera.recording()
        report.say(f"   recording state before: {state}")
        confirmed = camera.start_recording()
        end = time.monotonic() + args.seconds
        while time.monotonic() < end:
            time.sleep(0.5)
            camera.recording()                      # also keeps the connection alive
        camera.stop_recording()
        report.result("recording by command", True if confirmed else None,
                      "started and stopped, state confirmed by the camera" if confirmed
                      else "button sent, but the camera does not report its recording state here")
        time.sleep(2.0)                             # let the camera finish writing the clip
        return True
    except ERRORS as err:
        report.result("recording by command", False, str(err))
        try:
            camera._press_record(1)                 # make sure nothing keeps recording
        except ERRORS:
            pass
        return False


def card_and_download(camera, args, report):
    report.say("\n[3] Switch to file transfer, list the card, download the newest clip")
    started = time.monotonic()
    try:
        if camera.link:
            camera.switch(TRANSFER)
        else:
            camera.open(TRANSFER)
    except ERRORS as err:
        report.result("file-transfer session", False, str(err))
        return False
    report.result("file-transfer session", True, f"switched in {time.monotonic() - started:.1f} s")
    describe_session(camera, report)
    try:
        started = time.monotonic()
        card = camera.expose_card()
        report.result("memory card visible", True, f"storage {card:#010x} after {time.monotonic() - started:.1f} s")
    except ERRORS as err:
        report.result("memory card visible", False, str(err))
        return False
    try:
        started = time.monotonic()
        entries = camera.list_files()
        videos = [e for e in entries if e.is_video]
        report.result("file list", bool(entries), f"{len(entries)} entries, {len(videos)} clips, "
                                                  f"{time.monotonic() - started:.1f} s")
        for entry in videos[-5:]:
            report.say(f"      {entry.path}  {size_text(entry.size)}  {entry.date}")
        newest = newest_video(entries)
    except ERRORS as err:
        report.result("file list", False, str(err))
        return False
    if newest is None:
        report.result("download", None, "no clip on the card to download")
        return True
    if args.no_download:
        report.result("download", None, "skipped (--no-download)")
        return True
    try:
        started = time.monotonic()
        dest = camera.download(newest, args.out)
        seconds = max(time.monotonic() - started, 1e-3)
        size = os.path.getsize(dest)
        report.result("download", True, f"{newest.name}, {size_text(size)} in {seconds:.1f} s = "
                                        f"{size / 1e6 / seconds:.1f} MB/s, saved to {dest}")
    except ERRORS as err:
        report.result("download", False, str(err))
        return False
    return True


def back_to_remote(camera, report):
    report.say("\n[4] Switch back to remote control (what a second take would need)")
    started = time.monotonic()
    try:
        if camera.link:
            camera.switch(REMOTE)
        else:
            camera.open(REMOTE)
        state = camera.recording()
        report.result("back to remote control", True, f"in {time.monotonic() - started:.1f} s, recording state {state}")
        return True
    except ERRORS as err:
        report.result("back to remote control", False, str(err))
        return False


def raw_card_experiments(found, args, report, trace):
    """When the normal route did not reach the card: ask in every session type, and show each answer."""
    report.say("\n[5] The card was not reached; asking for it in every session type")

    def show(label, reply):
        extra = f" data={len(reply.data)}B {reply.data[:16].hex()}" if reply.data else ""
        report.say(f"      {label:<42} {c.rc_name(reply.code)} {reply.params}{extra}")
        return reply

    def session(title, open_op, open_params):
        report.say(f"   [{title}]")
        link = Link(found.host, client_guid(os.path.join(ROOT, ".zve10_client_guid")), "ZVE10-App", trace,
                    port=args.port, reply_timeout=15)
        try:
            link.connect(pairing_timeout=30)
            info = link.transact(c.GET_DEVICE_INFO)
            ops = set(ds.parse_device_info(info.data).ops) if info.ok else set()
            tid = 0 if open_op == c.OPEN_SESSION else None
            if not show(f"{c.op_name(open_op)} {list(open_params)}", link.transact(open_op, open_params, tid=tid)).ok:
                return
            if c.SDIO_CONNECT in ops:
                for phase in (1, 2):
                    show(f"SDIO_Connect({phase})", link.transact(c.SDIO_CONNECT, (phase, 0, 0)))
                show("SDIO_GetExtDeviceInfo(300)", link.transact(c.SDIO_GET_EXT_DEVICE_INFO, (300,)))
                show("SDIO_Connect(3)", link.transact(c.SDIO_CONNECT, (3, 0, 0)))
            show("GetStorageIDs", link.transact(c.GET_STORAGE_IDS))
            if c.SDIO_SET_CONTENTS_TRANSFER_MODE in ops:
                for select in (2, 1):
                    show(f"SetContentsTransferMode({select},1,0)",
                         link.transact(c.SDIO_SET_CONTENTS_TRANSFER_MODE, (select, 1, 0)))
                    end, reply = time.monotonic() + 6, None
                    while time.monotonic() < end:
                        reply = link.transact(c.GET_STORAGE_IDS)
                        if reply.ok and len(reply.data) > 4:
                            break
                        time.sleep(0.5)
                    show("GetStorageIDs after waiting", reply)
                    show("GetObjectHandles(card)", link.transact(c.GET_OBJECT_HANDLES, (CARD, 0, 0)))
                    show(f"SetContentsTransferMode({select},0,0)",
                         link.transact(c.SDIO_SET_CONTENTS_TRANSFER_MODE, (select, 0, 0)))
            show("CloseSession", link.transact(c.CLOSE_SESSION))
        except ERRORS as err:
            report.say(f"      FAILED: {err}")
        finally:
            link.close()
            time.sleep(1.0)

    session("plain session", c.OPEN_SESSION, (1,))
    session("Sony session, file transfer (1, 1)", c.SDIO_OPEN_SESSION, (1, 1))
    session("Sony session, remote control with transfer (1, 2)", c.SDIO_OPEN_SESSION, (1, 2))


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--host", help="camera address; found automatically when omitted")
    parser.add_argument("--port", type=int, help=argparse.SUPPRESS)
    parser.add_argument("--seconds", type=float, default=5.0, help="length of the test recording (default: 5)")
    parser.add_argument("--no-download", action="store_true", help="list the card but do not download the clip")
    parser.add_argument("--out", default=os.path.join(ROOT, "downloads", "smartphone-test"),
                        help="folder for the downloaded clip")
    parser.add_argument("--log-dir", default=os.path.join(ROOT, "logs"), help=argparse.SUPPRESS)
    args = parser.parse_args(argv)
    args.port_given = args.port is not None
    args.port = args.port or PORT

    logs = args.log_dir
    os.makedirs(logs, exist_ok=True)
    stem = os.path.join(logs, time.strftime("smartphone-test-%Y%m%d-%H%M%S"))
    report, trace = Report(stem + ".txt"), Trace(stem + ".log")
    report.say(f"ZV-E10 Smartphone Connect test, {time.strftime('%Y-%m-%d %H:%M:%S')}")

    found = find_camera(args, report, trace)
    if found is not None:
        camera = Camera(found.host, trace, client_guid(os.path.join(ROOT, ".zve10_client_guid")),
                        service=found.service, port=args.port)
        try:
            remote_and_record(camera, args, report)
            reached = card_and_download(camera, args, report)
            back_to_remote(camera, report)
        finally:
            try:
                camera.close()
            except ERRORS:
                pass
        if not reached:
            time.sleep(1.0)
            raw_card_experiments(found, args, report, trace)

    report.say("\nSummary")
    for step, ok, detail in report.results:
        report.say(f"   {({True: 'YES', False: 'NO ', None: '-- '}[ok])} {step}" + (f": {detail}" if detail else ""))
    report.say(f"\nReport:       {stem}.txt\nProtocol log: {stem}.log")
    report.say("Now put the Mac back on your router Wi-Fi.")
    return 0 if report.results and all(ok is not False for _, ok, _ in report.results) else 1


if __name__ == "__main__":
    sys.exit(main())
