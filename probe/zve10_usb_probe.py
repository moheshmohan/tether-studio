#!/usr/bin/env python3
"""Read-only USB probe for a Sony ZV-E10.

Reports which USB mode the camera is in and, when it exposes a PTP interface
(PC Remote or MTP), asks the firmware what it supports:

  1. GetDeviceInfo                      -> advertised operations
  2. remote-control session             -> SDIO handshake, protocol version, storages
  3. contents-transfer session attempt  -> SDIO_OpenSession(1, 1), SetContentsTransferMode(2, 1, 0)

Nothing is written, deleted or formatted, and no recording is started.

Usage:  .venv/bin/python probe/zve10_usb_probe.py
"""
import struct
import subprocess
import sys
import time

import usb.core
import usb.util
import usb.backend.libusb1

SONY_VID = 0x054C
LIBUSB_CANDIDATES = ("/opt/homebrew/lib/libusb-1.0.dylib", "/usr/local/lib/libusb-1.0.dylib")

OPS = {
    0x1001: "GetDeviceInfo", 0x1002: "OpenSession", 0x1003: "CloseSession", 0x1004: "GetStorageIDs",
    0x1005: "GetStorageInfo", 0x1006: "GetNumObjects", 0x1007: "GetObjectHandles", 0x1008: "GetObjectInfo",
    0x1009: "GetObject", 0x100A: "GetThumb", 0x100B: "DeleteObject", 0x100C: "SendObjectInfo",
    0x100D: "SendObject", 0x100F: "FormatStore", 0x1014: "GetDevicePropDesc", 0x1015: "GetDevicePropValue",
    0x1016: "SetDevicePropValue", 0x101B: "GetPartialObject",
    0x9201: "SDIO_Connect", 0x9202: "SDIO_GetExtDeviceInfo", 0x9203: "SONY_GetDevicePropDesc",
    0x9204: "SONY_GetDevicePropValue", 0x9205: "SDIO_SetExtDevicePropValue", 0x9206: "SONY_GetControlDeviceDesc",
    0x9207: "SDIO_ControlDevice", 0x9209: "SDIO_GetAllExtDevicePropInfo", 0x9210: "SDIO_OpenSession",
    0x9211: "SDIO_GetPartialLargeObject(old)", 0x9212: "SDIO_SetContentsTransferMode", 0x9213: "SDIO_GetDeviceLog",
    0x9215: "SDIO_GetDisplayStringList", 0x9219: "SDIO_GetPartialLargeObject", 0x9223: "SDIO_GetLensInformation",
    0x922F: "SDIO_OperationsResultsSupported",
    0x9280: "SonyDiExtCmd_write", 0x9281: "SonyDiExtCmd_read", 0x9282: "SonyReqReconnect",
    0x9283: "SonyGetBurstshotGroupNum", 0x9284: "SonyGetBurstshotObjectHandles", 0x9285: "SonyGetAVIndexID",
    0x9801: "GetObjectPropsSupported", 0x9802: "GetObjectPropDesc", 0x9803: "GetObjectPropValue",
    0x9805: "GetObjectPropList", 0x9810: "GetObjectReferences",
}
RCS = {
    0x2001: "OK", 0x2002: "GeneralError", 0x2003: "SessionNotOpen", 0x2004: "InvalidTransactionID",
    0x2005: "OperationNotSupported", 0x2006: "ParameterNotSupported", 0x2008: "InvalidStorageID",
    0x2009: "InvalidObjectHandle", 0x200F: "AccessDenied", 0x2013: "StoreNotAvailable",
    0x2019: "DeviceBusy", 0x201D: "InvalidParameter", 0x201E: "SessionAlreadyOpen",
    0xA101: "Sony_AuthenticationFailed", 0xA105: "Sony_TemporaryStorageFull", 0xA106: "Sony_CameraStatusError",
}
STORAGES = {0x00010001: "STORAGE_MEDIA_1 (memory card)", 0x00F10001: "VIRTUAL_MEDIA_1 (camera-selected images)"}


def name(table, code):
    return f"{table.get(code, '?')} (0x{code:04X})"


class PTPError(Exception):
    pass


class PTP:
    def __init__(self, dev, intf):
        self.dev = dev
        eps = intf.endpoints()
        is_in = lambda e: usb.util.endpoint_direction(e.bEndpointAddress) == usb.util.ENDPOINT_IN
        kind = lambda e: usb.util.endpoint_type(e.bmAttributes)
        self.ep_out = next(e for e in eps if not is_in(e) and kind(e) == usb.util.ENDPOINT_TYPE_BULK)
        self.ep_in = next(e for e in eps if is_in(e) and kind(e) == usb.util.ENDPOINT_TYPE_BULK)
        self.ep_evt = next((e for e in eps if is_in(e) and kind(e) == usb.util.ENDPOINT_TYPE_INTR), None)
        self.tid = 0

    def _read_container(self, timeout):
        buf = bytes(self.ep_in.read(1024 * 1024, timeout))
        while len(buf) < 12:
            buf += bytes(self.ep_in.read(1024 * 1024, timeout))
        length, ctype, code, _tid = struct.unpack_from("<IHHI", buf)
        while len(buf) < length:
            buf += bytes(self.ep_in.read(1024 * 1024, timeout))
        return ctype, code, buf[12:length]

    def tx(self, op, params=(), timeout=5000):
        """Run one transaction with no data-out phase. Returns (response_code, response_params, data)."""
        tid, self.tid = self.tid, self.tid + 1
        cmd = struct.pack("<IHHI", 12 + 4 * len(params), 1, op, tid) + b"".join(struct.pack("<I", p) for p in params)
        self.ep_out.write(cmd, timeout)
        data = b""
        ctype, code, payload = self._read_container(timeout)
        if ctype == 2:
            data = payload
            ctype, code, payload = self._read_container(timeout)
        if ctype != 3:
            raise PTPError(f"unexpected container type {ctype}")
        return code, list(struct.unpack(f"<{len(payload) // 4}I", payload[: len(payload) // 4 * 4])), data

    def drain_events(self, wait_ms=300):
        out = []
        if not self.ep_evt:
            return out
        while True:
            try:
                raw = bytes(self.ep_evt.read(64, wait_ms))
            except usb.core.USBError:
                return out
            if len(raw) >= 12:
                out.append(struct.unpack_from("<H", raw, 6)[0])


def ptp_string(buf, off):
    n = buf[off]
    return buf[off + 1: off + 1 + 2 * n].decode("utf-16-le").rstrip("\0"), off + 1 + 2 * n


def ptp_array16(buf, off):
    (n,) = struct.unpack_from("<I", buf, off)
    return list(struct.unpack_from(f"<{n}H", buf, off + 4)), off + 4 + 2 * n


def parse_device_info(d):
    info, off = {}, 8
    info["vendor_ext_desc"], off = ptp_string(d, off)
    off += 2
    for key in ("ops", "events", "props", "capture_formats", "image_formats"):
        info[key], off = ptp_array16(d, off)
    for key in ("manufacturer", "model", "device_version", "serial"):
        info[key], off = ptp_string(d, off)
    return info


def show(label, rc, extra=""):
    print(f"    {label:<46} -> {name(RCS, rc)} {extra}")


def storage_ids(ptp, label):
    rc, _, data = ptp.tx(0x1004)
    ids = []
    if rc == 0x2001 and len(data) >= 4:
        (n,) = struct.unpack_from("<I", data)
        ids = list(struct.unpack_from(f"<{n}I", data, 4))
    show(label, rc, ", ".join(f"0x{i:08X} {STORAGES.get(i, '')}" for i in ids))
    return rc, ids


def sdio_handshake(ptp):
    for phase in (1, 2):
        rc, _, _ = ptp.tx(0x9201, (phase, 0, 0))
        show(f"SDIO_Connect({phase})", rc)
        if rc != 0x2001:
            return None
    rc, _, data = ptp.tx(0x9202, (300,))
    version = struct.unpack_from("<H", data)[0] if len(data) >= 2 else None
    show("SDIO_GetExtDeviceInfo(300)", rc, f"protocol version {version}")
    ext = None
    if rc == 0x2001 and len(data) > 6:
        props, off = ptp_array16(data, 2)
        controls, _ = ptp_array16(data, off) if off + 4 <= len(data) else ([], off)
        ext = {"version": version, "props": props, "controls": controls}
    rc, _, _ = ptp.tx(0x9201, (3, 0, 0))
    show("SDIO_Connect(3)", rc)
    return ext


def try_contents_transfer(ptp, ops):
    """Ask the firmware to expose the card. Returns True if the memory card storage appeared."""
    storage_ids(ptp, "GetStorageIDs (before)")
    if 0x9212 not in ops:
        print("    SDIO_SetContentsTransferMode is not advertised; skipping")
        return False
    rc, _, _ = ptp.tx(0x9212, (2, 1, 0))
    show("SDIO_SetContentsTransferMode(2, 1, 0)", rc)
    found = False
    for _ in range(8):
        time.sleep(0.5)
        events = ptp.drain_events(100)
        if events:
            print("    events:", ", ".join(f"0x{e:04X}" for e in events))
        rc, ids = storage_ids(ptp, "GetStorageIDs (after)")
        if 0x00010001 in ids:
            found = True
            rc, _, data = ptp.tx(0x1007, (0x00010001, 0, 0xFFFFFFFF), timeout=20000)
            count = struct.unpack_from("<I", data)[0] if len(data) >= 4 else 0
            show("GetObjectHandles(card)", rc, f"{count} objects")
            break
        if rc not in (0x2013, 0x2019):
            break
    rc, _, _ = ptp.tx(0x9212, (2, 0, 0))
    show("SDIO_SetContentsTransferMode(2, 0, 0)", rc)
    return found


def open_device():
    lib = next((p for p in LIBUSB_CANDIDATES if __import__("os").path.exists(p)), None)
    backend = usb.backend.libusb1.get_backend(find_library=(lambda _: lib) if lib else None)
    return usb.core.find(idVendor=SONY_VID, backend=backend)


def claim(dev, intf):
    for attempt in range(6):
        try:
            usb.util.claim_interface(dev, intf.bInterfaceNumber)
            return
        except usb.core.USBError as e:
            if attempt == 0:
                print(f"  interface busy ({e}); stopping macOS ptpcamerad so the probe can talk to the camera")
            subprocess.run(["killall", "-9", "ptpcamerad"], capture_output=True)
            time.sleep(0.15)
    raise SystemExit("Could not claim the PTP interface. Quit Imaging Edge / Photos / Image Capture and retry.")


def main():
    dev = open_device()
    if dev is None:
        raise SystemExit("No Sony USB device found.")
    print(f"Device: {dev.product}  VID:PID {dev.idVendor:04x}:{dev.idProduct:04x}  bcdDevice {dev.bcdDevice:04x}")
    cfg = dev.get_active_configuration()
    classes = [(i.bInterfaceClass, i.bInterfaceSubClass, i.bInterfaceProtocol) for i in cfg]
    print("Interfaces (class, subclass, protocol):", classes)
    ptp_intf = next((i for i in cfg if i.bInterfaceClass == 6), None)
    if ptp_intf is None:
        mode = "Mass Storage" if any(c[0] == 8 for c in classes) else "USB Streaming (UVC)" if any(
            c[0] == 14 for c in classes) else "unknown"
        print(f"\nRESULT: camera is in {mode} mode. There is no PTP control channel in this mode,")
        print("so an app cannot start recording or change mode from here.")
        return

    claim(dev, ptp_intf)
    ptp = PTP(dev, ptp_intf)
    try:
        rc, _, data = ptp.tx(0x1001)
        if rc != 0x2001:
            raise SystemExit(f"GetDeviceInfo failed: {name(RCS, rc)}")
        info = parse_device_info(data)
        ops = info["ops"]
        print(f"\nModel {info['model']}  firmware {info['device_version']}  ext '{info['vendor_ext_desc']}'")
        print("Advertised operations:")
        for op in ops:
            print(f"    {name(OPS, op)}")
        remote = 0x9201 in ops
        print(f"\nMode: {'PC Remote (remote control available)' if remote else 'MTP (file access only, no remote control)'}")
        if not remote:
            rc, _, _ = ptp.tx(0x1002, (1,))
            show("OpenSession", rc)
            storage_ids(ptp, "GetStorageIDs")
            ptp.tx(0x1003)
            print("\nRESULT: MTP mode gives file access but advertises no record/remote-control operations.")
            return

        print("\n[A] Remote-control session (what an app uses to start/stop recording)")
        ptp.tid = 0
        rc, _, _ = ptp.tx(0x1002, (1,))
        show("OpenSession", rc)
        ext = sdio_handshake(ptp)
        if ext:
            rec = 0xD2C8 in ext["controls"]
            print(f"    {len(ext['props'])} properties, {len(ext['controls'])} controls; "
                  f"movie record control 0xD2C8 {'present' if rec else 'MISSING'}")
            print("    controls:", " ".join(f"{c:04X}" for c in ext["controls"]))
        card_a = try_contents_transfer(ptp, ops)
        show("CloseSession", ptp.tx(0x1003)[0])

        card_b = False
        if 0x9210 in ops:
            print("\n[B] Contents-transfer session: SDIO_OpenSession(1, mode=1)")
            ptp.tid = 0
            rc, _, _ = ptp.tx(0x9210, (1, 1))
            show("SDIO_OpenSession(1, 1)", rc)
            if rc == 0x2001:
                sdio_handshake(ptp)
                card_b = try_contents_transfer(ptp, ops)
                show("CloseSession", ptp.tx(0x1003)[0])
        else:
            print("\n[B] SDIO_OpenSession (0x9210) is not advertised; contents-transfer session not attempted")

        print("\nRESULT:")
        if card_a or card_b:
            print("  The firmware exposed the memory card over USB while in PC Remote mode.")
            print("  An app CAN record and then pull files over the same USB connection.")
        else:
            print("  The firmware does NOT expose the memory card over USB in PC Remote mode.")
            print("  Recording works here, but files cannot be pulled without leaving PC Remote.")
        if 0x9282 in ops:
            print("  Note: SonyReqReconnect (0x9282) is advertised in this mode (undocumented USB mode switch).")
    finally:
        usb.util.release_interface(dev, ptp_intf.bInterfaceNumber)


if __name__ == "__main__":
    try:
        main()
    except usb.core.USBError as e:
        sys.exit(f"USB error: {e}")
