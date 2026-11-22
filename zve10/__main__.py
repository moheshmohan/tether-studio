"""Command line: python -m zve10 {discover,info,record,list,pull,take,usbtake}"""
import argparse
import os
import subprocess
import sys
import time

from . import discovery, usbcopy
from .camera import REMOTE, SETTLE, TRANSFER, Camera, CameraError, TransferUnavailable, newest_video
from .ptpip import PORT, LinkError, Trace

SERVICE_NAMES = {"smartphone": "Smartphone Connect (record and transfer)",
                 "pcremote": "PC Remote (record only)", None: "unknown service"}
NOT_FOUND = """No camera found on this network.
  Same Wi-Fi as this computer:  camera Network > PC Remote Function > PC Remote: On,
                                PC Remote Cnct Method: Wi-Fi Access Point  (recording only)
  Camera's own Wi-Fi:           camera PC Remote: Off, then Network > Smartphone Connect Function > Connection,
                                and join the DIRECT-... network shown on its screen  (recording and transfer)
If the camera is on and connected, pass its address with --host."""
PC_REMOTE_TRANSFER = """The camera is in PC Remote mode, where the firmware does not hand over files.
To pull clips without touching the camera between takes, use Smartphone Connect instead:
PC Remote: Off, then Network > Smartphone Connect Function > Connection."""


def client_guid(path=".zve10_client_guid"):
    """A stable identity for this computer; the camera remembers it once paired."""
    if os.path.exists(path):
        with open(path, "rb") as fh:
            guid = fh.read()
        if len(guid) == 16:
            return guid
    guid = os.urandom(16)
    with open(path, "wb") as fh:
        fh.write(guid)
    return guid


def size_text(size):
    return "?" if size is None else f"{size / 1e6:,.1f} MB"


def locate(args, trace):
    if args.usb:
        args.found_service = "pcremote"
        print("Using the USB cable (camera: PC Remote Cnct Method: USB)", flush=True)
        return Camera(None, trace, client_guid(), service="pcremote", usb=True)
    if args.host:
        found = discovery.describe_host(args.host) if args.service == "auto" else None
        found = found or discovery.Found(host=args.host)
    else:
        cameras, error = discovery.find_cameras(trace=trace)
        if not cameras:
            raise CameraError(NOT_FOUND + (f"\n(search problem: {error})" if error else ""))
        found = cameras[0]
    if args.service != "auto":
        found.service = args.service
    args.found_service = found.service
    print(f"{found.model or 'Camera'} at {found.host}: {SERVICE_NAMES[found.service]}")
    return Camera(found.host, trace, client_guid(), service=found.service, port=args.port)


def record(camera, seconds):
    confirmed = camera.start_recording()
    print("Recording" + ("" if confirmed else " requested (the camera does not report its state)"), flush=True)
    end = time.monotonic() + seconds
    while time.monotonic() < end:
        time.sleep(min(1.0, max(0.0, end - time.monotonic())))
        if time.monotonic() < end and camera.recording() is False and confirmed:   # the poll also keeps the link alive
            raise CameraError("the camera stopped recording early (card full or recording limit?)")
    camera.stop_recording()
    print(f"Stopped after {seconds:g} s")
    time.sleep(SETTLE)


def open_card(camera):
    if camera.service == "pcremote":
        print("Asking for the memory card (PC Remote mode normally refuses this)...")
    if camera.link:
        camera.switch(TRANSFER)
    else:
        camera.open(TRANSFER)
    camera.expose_card()

    def progress(done, total):
        print(f"\r  reading file list {done}/{total or '?'}", end="", flush=True)
    entries = camera.list_files(progress)
    print()
    return entries


def pull(camera, entries, out_dir):
    for entry in entries:
        started, last = time.monotonic(), [0.0]

        def progress(done, total, entry=entry, started=started, last=last):
            if time.monotonic() - last[0] > 0.5 or done == total:
                last[0] = time.monotonic()
                rate = done / 1e6 / max(time.monotonic() - started, 1e-3)
                print(f"\r  {entry.name}: {size_text(done)} of {size_text(total)} at {rate:.1f} MB/s   ",
                      end="", flush=True)
        dest = camera.download(entry, out_dir, progress)
        print(f"\r  saved {dest} ({size_text(os.path.getsize(dest))})" + " " * 30)


def cmd_discover(args, trace):
    cameras, error = discovery.find_cameras(trace=trace)
    if not cameras:
        raise CameraError(NOT_FOUND + (f"\n(search problem: {error})" if error else ""))
    for found in cameras:
        print(f"{found.model or 'camera'} at {found.host}: {SERVICE_NAMES[found.service]}")


def cmd_info(args, trace):
    camera = locate(args, trace)
    camera.open(REMOTE)
    try:
        state = camera.recording()
        info = camera.info
        print(f"Model {info.model}, firmware {info.version}, Sony protocol {camera.protocol}")
        print(f"Recording: {'yes' if state else 'no' if state is not None else 'state not reported'}")
        can = lambda op: "yes" if op in camera.ops else "no"
        print(f"Advertises contents-transfer session: {can(0x9210)}, card request: {can(0x9212)}, "
              f"chunked download: {can(0x9219)}")
    finally:
        camera.close()


def cmd_record(args, trace):
    camera = locate(args, trace)
    camera.open(REMOTE)
    try:
        record(camera, args.seconds)
    finally:
        camera.close()


def cmd_list(args, trace):
    camera = locate(args, trace)
    try:
        for entry in open_card(camera):
            if not entry.is_folder:
                print(f"{size_text(entry.size):>12}  {entry.date:<16} {entry.path}")
    finally:
        camera.close()


def cmd_pull(args, trace):
    camera = locate(args, trace)
    try:
        entries = open_card(camera)
        if args.names:
            wanted = {n.upper() for n in args.names}
            chosen = [e for e in entries if not e.is_folder and e.name.upper() in wanted]
            missing = wanted - {e.name.upper() for e in chosen}
            if missing:
                raise CameraError("not on the card: " + ", ".join(sorted(missing)))
        else:
            newest = newest_video(entries)
            if newest is None:
                raise CameraError("no video files on the card")
            chosen = [newest]
        pull(camera, chosen, args.out)
    finally:
        camera.close()


def wait_for_camera(args, trace, timeout):
    """Wait until the camera answers on Wi-Fi (it is off the network while a USB data cable is connected)."""
    deadline = time.monotonic() + timeout
    while time.monotonic() < deadline:
        if args.host:
            if discovery._port_open(args.host, args.port):
                return True
            time.sleep(1.0)
        elif discovery.find_cameras(wait=2.0, trace=trace)[0]:
            return True
    return False


def usb_switch(command, instruction):
    """Run the user's command for a switchable USB port, or ask for the cable to be moved by hand."""
    if command:
        subprocess.run(command, shell=True, check=True)
    else:
        print(f">>> {instruction}", flush=True)


def cmd_usbtake(args, trace):
    """Record over Wi-Fi, then copy the new clip over USB once the card is connected."""
    before = -1
    for volume in usbcopy.card_volumes():           # the card is mounted, so the camera is in USB mode now
        clip = usbcopy.newest_clip(volume)
        before = max(before, usbcopy.clip_number(os.path.basename(clip)) if clip else -1)
        usbcopy.eject(volume)
    usb_switch(args.usb_off, "Disconnect the USB cable from the camera")
    started = time.monotonic()
    if not wait_for_camera(args, trace, args.wait):
        raise CameraError("the camera is not on Wi-Fi. The USB cable must be disconnected, and after USB mode "
                          "the camera stays off Wi-Fi until it is switched off and on again")
    print(f"Camera on Wi-Fi after {time.monotonic() - started:.0f} s")
    camera = locate(args, trace)
    for attempt in range(3):                        # the camera can answer discovery a moment before it accepts
        try:
            camera.open(REMOTE)
            break
        except LinkError as err:
            trace(f"connect attempt {attempt + 1} failed: {err}")
            if attempt == 2:
                raise
            time.sleep(2.0)
    try:
        record(camera, args.seconds)
    finally:
        camera.close()

    usb_switch(args.usb_on, "Connect the USB cable to the camera")
    started = time.monotonic()
    volume = usbcopy.wait_for_card(args.wait)
    if volume is None:
        raise CameraError("the memory card did not appear over USB")
    print(f"Card mounted after {time.monotonic() - started:.0f} s")
    clip = usbcopy.newest_clip(volume)
    if clip is None or usbcopy.clip_number(os.path.basename(clip)) <= before:
        raise CameraError("no new clip on the card")
    started = time.monotonic()
    dest = usbcopy.copy(clip, args.out)
    seconds = max(time.monotonic() - started, 1e-3)
    size = os.path.getsize(dest)
    print(f"  saved {dest} ({size_text(size)}) in {seconds:.1f} s, {size / 1e6 / seconds:.0f} MB/s")
    usbcopy.eject(volume)
    usb_switch(args.usb_off, "Disconnect the USB cable")
    print("Switch the camera off and on before the next take; it does not rejoin Wi-Fi by itself after USB mode.")


def cmd_take(args, trace):
    camera = locate(args, trace)
    try:
        camera.open(REMOTE)
        record(camera, args.seconds)
        newest = newest_video(open_card(camera))
        if newest is None:
            raise CameraError("no video files on the card")
        pull(camera, [newest], args.out)
    finally:
        camera.close()


def main(argv=None):
    parser = argparse.ArgumentParser(
        prog="python -m zve10",
        description="Record on a Sony ZV-E10 over Wi-Fi and pull the clip off the card.")
    parser.add_argument("--host", help="camera address; found automatically when omitted")
    parser.add_argument("--port", type=int, default=PORT, help=argparse.SUPPRESS)
    parser.add_argument("--usb", action="store_true",
                        help="use the USB cable instead of Wi-Fi (camera: PC Remote Cnct Method: USB)")
    parser.add_argument("--service", choices=("auto", "smartphone", "pcremote"), default="auto",
                        help="which camera Wi-Fi service to assume (default: ask the camera)")
    parser.add_argument("--out", default="downloads", help="folder for downloaded clips (default: downloads)")
    parser.add_argument("--log-dir", default="logs", help="folder for the protocol log (default: logs)")
    parser.add_argument("-v", "--verbose", action="store_true", help="print every protocol message")
    sub = parser.add_subparsers(dest="command", required=True)
    sub.add_parser("discover", help="find the camera and show which Wi-Fi service it is running")
    sub.add_parser("info", help="connect and show model, firmware and what the camera offers")
    for name, text in (("record", "record for a while (the clip stays on the card)"),
                       ("take", "record, then download the new clip")):
        p = sub.add_parser(name, help=text)
        p.add_argument("--seconds", type=float, default=10.0, help="recording length (default: 10)")
    p = sub.add_parser("usbtake", help="record over Wi-Fi, then copy the new clip over the USB cable")
    p.add_argument("--seconds", type=float, default=10.0, help="recording length (default: 10)")
    p.add_argument("--usb-on", metavar="CMD", help="shell command that connects the camera's USB port")
    p.add_argument("--usb-off", metavar="CMD", help="shell command that disconnects the camera's USB port")
    p.add_argument("--wait", type=float, default=180.0, help="seconds to wait for Wi-Fi or the card (default: 180)")
    sub.add_parser("list", help="list the files on the memory card")
    p = sub.add_parser("pull", help="download files by name, or the newest clip when no name is given")
    p.add_argument("names", nargs="*", help="file names, e.g. C0178.MP4")
    args = parser.parse_args(argv)

    os.makedirs(args.log_dir, exist_ok=True)
    log_path = os.path.join(args.log_dir, time.strftime("zve10-%Y%m%d-%H%M%S.log"))
    trace = Trace(log_path, echo=args.verbose)
    trace(f"command: {args.command} {vars(args)}")
    try:
        globals()[f"cmd_{args.command}"](args, trace)
        return 0
    except TransferUnavailable as err:
        trace(f"TRANSFER UNAVAILABLE: {err}")
        print(f"\nTransfer not possible: {err}", file=sys.stderr)
        if getattr(args, "found_service", None) != "smartphone":
            print(PC_REMOTE_TRANSFER, file=sys.stderr)
        code = 3
    except (CameraError, LinkError, OSError, subprocess.SubprocessError) as err:
        trace(f"ERROR: {err}")
        print(f"\nError: {err}", file=sys.stderr)
        code = 1
    except KeyboardInterrupt:
        print("\nInterrupted", file=sys.stderr)
        code = 130
    print(f"Protocol log: {log_path}", file=sys.stderr)
    return code


if __name__ == "__main__":
    sys.exit(main())
