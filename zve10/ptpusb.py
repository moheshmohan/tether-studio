"""PTP over a USB cable (still-image class, bulk transport), for a camera set to PC Remote Cnct Method: USB.

Offers the same interface as ptpip.Link, so the session code does not care which one it talks through. Needs the
pyusb package and libusb. On macOS the system service ptpcamerad claims every camera that is plugged in; it is
stopped so that this link can have the camera (macOS starts it again by itself when needed).
"""
import os
import queue
import struct
import subprocess
import sys
import threading
import time

from .codes import CLOSE_SESSION, op_name, rc_name
from .ptpip import LinkError, Reply

SONY_VID = 0x054C
CLASS_PTP, CLASS_MASS_STORAGE, CLASS_VIDEO = 6, 8, 14
MODE_NAMES = {CLASS_PTP: "ptp", CLASS_MASS_STORAGE: "mass storage", CLASS_VIDEO: "streaming"}
COMMAND, DATA, RESPONSE = 1, 2, 3
HEADER = struct.Struct("<IHHI")         # length, container type, code, transaction ID
READ_SIZE = 1 << 20                     # a multiple of every bulk packet size, as libusb requires
CLAIM_ATTEMPTS = 25
LIBUSB_CANDIDATES = ("/opt/homebrew/lib/libusb-1.0.dylib", "/usr/local/lib/libusb-1.0.dylib")
NOT_PTP = ("the camera is connected in USB {mode} mode, which has no control channel. On the camera set Network > "
           "PC Remote Function > PC Remote: On and PC Remote Cnct Method: USB, then reconnect the cable")


def _pyusb():
    try:
        import usb.backend.libusb1
        import usb.core
        import usb.util
    except ImportError as err:
        raise LinkError("USB needs the pyusb package (pip install pyusb) and libusb (brew install libusb)") from err
    return usb


def find_camera():
    """(device, PTP interface or None, mode name) for the first Sony device on USB; all None when there is none."""
    usb = _pyusb()
    lib = next((path for path in LIBUSB_CANDIDATES if os.path.exists(path)), None)
    backend = usb.backend.libusb1.get_backend(find_library=(lambda _: lib) if lib else None)
    if backend is None:
        raise LinkError("libusb was not found (brew install libusb)")
    dev = usb.core.find(idVendor=SONY_VID, backend=backend)
    if dev is None:
        return None, None, None
    try:
        config = dev.get_active_configuration()
    except usb.core.USBError as err:
        raise LinkError(f"cannot read the camera's USB configuration: {err}") from err
    classes = [intf.bInterfaceClass for intf in config]
    ptp = next((intf for intf in config if intf.bInterfaceClass == CLASS_PTP), None)
    mode = next((MODE_NAMES[cls] for cls in MODE_NAMES if cls in classes), "unknown")
    return dev, ptp, mode


class UsbLink:
    def __init__(self, trace, reply_timeout=30.0):
        self.trace, self.reply_timeout = trace, reply_timeout
        self.events = queue.Queue()     # kept for parity with ptpip.Link; the interrupt endpoint is not read
        self.camera_name = ""
        self._dev = self._intf = self._out = self._in = None
        self._tid = 0
        self._rx = bytearray()
        self._lock = threading.Lock()

    def connect(self, pairing_timeout=None):
        usb = _pyusb()
        dev, intf, mode = find_camera()
        if dev is None:
            raise LinkError("no Sony camera found on USB")
        if intf is None:
            raise LinkError(NOT_PTP.format(mode=mode))
        self._claim(usb, dev, intf)
        is_in = lambda ep: usb.util.endpoint_direction(ep.bEndpointAddress) == usb.util.ENDPOINT_IN
        bulk = [ep for ep in intf.endpoints() if usb.util.endpoint_type(ep.bmAttributes) == usb.util.ENDPOINT_TYPE_BULK]
        self._out = next((ep for ep in bulk if not is_in(ep)), None)
        self._in = next((ep for ep in bulk if is_in(ep)), None)
        if self._out is None or self._in is None:
            usb.util.dispose_resources(dev)
            raise LinkError("the camera's USB control interface has no bulk endpoints")
        self._dev, self._intf = dev, intf
        self._tid, self._rx = 0, bytearray()
        try:
            self.camera_name = dev.product or ""
        except (usb.core.USBError, ValueError):
            self.camera_name = ""
        self.trace(f"connected to '{self.camera_name}' on USB {dev.idVendor:04x}:{dev.idProduct:04x}, "
                   f"interface {intf.bInterfaceNumber}")
        # ptpcamerad opens a session when the camera is plugged in, and stopping it leaves that session open in
        # the camera, which then refuses ours with SessionAlreadyOpen (seen on a ZV-E10). Closing a session that
        # is not open is answered SessionNotOpen and changes nothing.
        self.transact(CLOSE_SESSION)

    def _claim(self, usb, dev, intf):
        error = None
        for attempt in range(CLAIM_ATTEMPTS):
            try:
                usb.util.claim_interface(dev, intf.bInterfaceNumber)
                return
            except usb.core.USBError as err:
                error = err
                if attempt == 0:
                    self.trace(f"USB interface busy ({err}); stopping ptpcamerad")
                if sys.platform == "darwin":
                    subprocess.run(["killall", "-9", "ptpcamerad"], capture_output=True)
                time.sleep(0.15)
        usb.util.dispose_resources(dev)
        raise LinkError(f"another program is holding the camera's USB connection ({error}). Quit Photos, Image "
                        "Capture and Imaging Edge and try again")

    def _write(self, data, ms):
        self._out.write(data, ms)
        if len(data) % self._out.wMaxPacketSize == 0:
            self._out.write(b"", ms)            # a zero-length packet marks the end of an exact-multiple transfer

    def _read_container(self, ms):
        while len(self._rx) < HEADER.size:
            self._rx += bytes(self._in.read(READ_SIZE, ms))
        length, ctype, code, _ = HEADER.unpack_from(self._rx)
        if length < HEADER.size:
            raise LinkError(f"bad USB container length {length}")
        while len(self._rx) < length:
            self._rx += bytes(self._in.read(READ_SIZE, ms))
        payload = bytes(self._rx[HEADER.size:length])
        del self._rx[:length]
        return ctype, code, payload

    def transact(self, op, params=(), data_out=None, tid=None, timeout=None):
        """Run one operation. `tid` overrides the transaction ID and restarts the counter after it."""
        if self._dev is None:
            raise LinkError("not connected")
        usb = _pyusb()
        with self._lock:
            if tid is None:
                tid = self._tid
            self._tid = tid + 1
            ms = int((timeout or self.reply_timeout) * 1000)
            sent = f" + {len(data_out)} bytes {data_out[:16].hex()}" if data_out is not None else ""
            self.trace(f"-> {op_name(op)} {list(params)} tid={tid}{sent}")
            try:
                self._write(HEADER.pack(HEADER.size + 4 * len(params), COMMAND, op, tid)
                            + b"".join(struct.pack("<I", p & 0xFFFFFFFF) for p in params), ms)
                if data_out is not None:
                    self._write(HEADER.pack(HEADER.size + len(data_out), DATA, op, tid) + data_out, ms)
                data = b""
                while True:
                    ctype, code, payload = self._read_container(ms)
                    if ctype == DATA:
                        data = payload
                    elif ctype == RESPONSE:
                        break
                    else:
                        self.trace(f"   (ignored USB container type {ctype}, {len(payload)} bytes)")
            except usb.core.USBError as err:
                self._rx = bytearray()
                self.trace(f"<- LINK FAILURE {err!r}")
                raise LinkError(f"USB transfer failed: {err}") from err
            rparams = list(struct.unpack_from(f"<{len(payload) // 4}I", payload))
            got = f" data={len(data)} bytes {data[:24].hex()}" if data else ""
            self.trace(f"<- {rc_name(code)} {rparams}{got}")
            return Reply(code, rparams, data)

    def close(self):
        if self._dev is not None:
            usb = _pyusb()
            try:
                usb.util.release_interface(self._dev, self._intf.bInterfaceNumber)
            except usb.core.USBError:
                pass
            usb.util.dispose_resources(self._dev)
        self._dev = self._intf = self._out = self._in = None
