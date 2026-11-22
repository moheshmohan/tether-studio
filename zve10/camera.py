"""Sony session logic on top of a PTP link (Wi-Fi or USB): remote control, recording, and contents transfer.

The camera offers two Wi-Fi services:
  * Smartphone Connect (the camera's own Wi-Fi Direct network): remote control and contents transfer. The mode is
    chosen when the session is opened, so switching means closing the connection and opening it again.
  * PC Remote (Wi-Fi Direct or the router the camera joined): remote control only.
PC Remote also runs over the USB cable (PC Remote Cnct Method: USB), through ptpusb.UsbLink.
"""
import os
import re
import struct
import time
from dataclasses import dataclass

from . import codes as c
from . import datasets as ds
from .ptpip import PORT, Link, LinkError

REMOTE, TRANSFER = 0, 1
MODE_NAMES = {REMOTE: "remote control", TRANSFER: "contents transfer"}
VIDEO_SUFFIXES = (".MP4", ".MXF", ".MTS", ".MOV")

VERIFY_WAIT = 10.0      # how long to wait for the recording state to follow the button (2-3 s on a real ZV-E10)
SETTLE = 1.5            # pause after recording stops, so the camera finishes writing the file
RECONNECT_PAUSE = 0.5   # pause between closing a connection and opening the next one
CARD_WAIT = 30.0        # how long to wait for the card to appear after asking for it
CARD_WAIT_PC_REMOTE = 6.0   # PC Remote never shows the card (30 s of refusals on a real ZV-E10), so give up sooner
CHUNK = 3 * 1024 * 1024
READ_SPACING = 1.0      # least time between the starts of two reads of one file: sooner than about 0.8 s and the
                        # ZV-E10 sometimes serves the second read from the first one's position (FINDINGS section 12h)


class CameraError(Exception):
    pass


class TransferUnavailable(CameraError):
    """The camera will not hand over files in its current mode."""


@dataclass
class FileEntry:
    handle: int
    name: str
    size: int           # None when the camera does not report it (4 GB or more)
    date: str
    parent: int
    is_folder: bool
    path: str = ""

    @property
    def is_video(self):
        return not self.is_folder and self.name.upper().endswith(VIDEO_SUFFIXES)


def newest_video(entries):
    """The clip with the highest file number; the camera clock may be unset, so dates only break ties."""
    def key(entry):
        digits = re.sub(r"\D", "", os.path.splitext(entry.name)[0])
        return (int(digits) if digits else -1, entry.date, entry.handle)
    videos = [e for e in entries if e.is_video]
    return max(videos, key=key) if videos else None


class Camera:
    def __init__(self, host, trace, guid, service=None, port=PORT, client_name="ZVE10-App", usb=False):
        self.host, self.port, self.trace, self.guid = host, port, trace, guid
        self.usb = usb                      # talk over the USB cable instead of the network
        self.service = service              # "smartphone", "pcremote" or None when unknown
        self.client_name = client_name
        self.link = None
        self.mode = None
        self.info = None
        self.ops = set()
        self.controls = set()
        self.protocol = None
        self.card = None
        self.recording_failed = False
        self._transfer_requested = False
        self._info_cache = {}

    # ---- connection and session -------------------------------------------------------------------------------

    def open(self, mode):
        if self.usb:
            from .ptpusb import UsbLink     # imported here so Wi-Fi use does not need pyusb
            self.link = UsbLink(self.trace)
        else:
            self.link = Link(self.host, self.guid, self.client_name, self.trace, port=self.port)
        self.link.connect()
        try:
            self._open_session(mode)
        except (CameraError, LinkError):
            self.link.close()
            self.link = None
            raise

    def _open_session(self, mode):
        self.info = self._read_device_info()
        self.ops = set(self.info.ops)
        has_sdio_open = c.SDIO_OPEN_SESSION in self.ops
        if mode == TRANSFER and not has_sdio_open and c.SDIO_CONNECT in self.ops:
            raise TransferUnavailable("the camera does not offer contents-transfer sessions in this mode")
        opened = False
        if mode == TRANSFER or (has_sdio_open and self.service != "pcremote"):
            reply = self.link.transact(c.SDIO_OPEN_SESSION, (1, mode))
            opened = reply.ok
            if not opened and mode == TRANSFER:
                raise TransferUnavailable(f"the camera refused a contents-transfer session: {c.rc_name(reply.code)}")
        if not opened:
            reply = self.link.transact(c.OPEN_SESSION, (1,), tid=0)
            if reply.code not in (c.OK, c.SESSION_ALREADY_OPEN):
                raise CameraError(f"OpenSession failed: {c.rc_name(reply.code)}")
        self.mode = mode
        try:
            self._handshake()
        except CameraError as err:
            if mode == TRANSFER:
                raise TransferUnavailable(f"the camera refused the contents-transfer handshake: {err}") from err
            raise
        self.trace(f"session open: {MODE_NAMES[mode]}, protocol {self.protocol}, {len(self.controls)} controls")
        self.trace(f"model {self.info.model} firmware {self.info.version}; advertised operations: "
                   + " ".join(f"{op:04X}" for op in sorted(self.ops)))
        self.trace("controls: " + " ".join(f"{code:04X}" for code in sorted(self.controls)))

    def _read_device_info(self):
        reply = self.link.transact(c.GET_DEVICE_INFO)
        if not reply.ok:
            raise CameraError(f"GetDeviceInfo failed: {c.rc_name(reply.code)}")
        return ds.parse_device_info(reply.data)

    def _handshake(self):
        for phase in (1, 2):
            self._op(c.SDIO_CONNECT, (phase, 0, 0))
        reply = self.link.transact(c.SDIO_GET_EXT_DEVICE_INFO, (300,))
        if not reply.ok:
            reply = self.link.transact(c.SDIO_GET_EXT_DEVICE_INFO, (200,))
        if not reply.ok:
            raise CameraError(f"SDIO_GetExtDeviceInfo failed: {c.rc_name(reply.code)}")
        self.protocol, _, controls = ds.parse_ext_device_info(reply.data)
        self.controls = set(controls)
        self._op(c.SDIO_CONNECT, (3, 0, 0))
        self.ops |= set(self._read_device_info().ops)   # the list can grow once the session is authenticated

    def _ask(self, op, params=(), data_out=None, timeout=None):
        """Send an operation and return the reply whatever its code. Unadvertised operations are never sent: the
        ZV-E10 answers one with an error and then fails every later command on the session."""
        if op not in self.ops:
            raise CameraError(f"the camera does not advertise {c.op_name(op)}")
        return self.link.transact(op, params, data_out=data_out, timeout=timeout)

    def _op(self, op, params=(), data_out=None, timeout=None):
        """An operation that must succeed."""
        reply = self._ask(op, params, data_out=data_out, timeout=timeout)
        if not reply.ok:
            raise CameraError(f"{c.op_name(op)} failed: {c.rc_name(reply.code)}")
        return reply

    def close(self):
        if self.link is None:
            return
        try:
            if self._transfer_requested:
                self.link.transact(c.SDIO_SET_CONTENTS_TRANSFER_MODE, (2, 0, 0))
            self.link.transact(c.CLOSE_SESSION)
        except LinkError:
            pass
        self.link.close()
        self.link = self.mode = self.card = None
        self._transfer_requested = False

    def switch(self, mode):
        self.close()
        time.sleep(RECONNECT_PAUSE)
        self.open(mode)

    # ---- recording --------------------------------------------------------------------------------------------

    def recording(self):
        """True or False, or None when the camera does not report a recording state."""
        props = ds.parse_all_props(self._op(c.SDIO_GET_ALL_PROPS).data)
        prop = props.get(c.PROP_RECORDING_STATE)
        if prop is None:
            return None
        self.recording_failed = prop.value == 2
        return prop.value == 1

    def _press_record(self, value):
        if c.CONTROL_MOVIE_REC not in self.controls:
            raise CameraError("the camera does not offer the movie record control in this mode")
        self._op(c.SDIO_CONTROL_DEVICE, (c.CONTROL_MOVIE_REC,), data_out=struct.pack("<H", value))

    def _wait_recording(self, wanted):
        deadline = time.monotonic() + VERIFY_WAIT
        while time.monotonic() < deadline:
            if self.recording() == wanted:
                return True
            time.sleep(0.25)
        return False

    def start_recording(self):
        """Returns True when the camera confirmed it is recording, None when it cannot be confirmed."""
        state = self.recording()
        if state:
            raise CameraError("the camera is already recording")
        self._press_record(2)
        if state is None:
            return None
        if self._wait_recording(True):
            return True
        self._press_record(1)           # release, so nothing starts recording later unnoticed
        reason = "it reports that recording failed" if self.recording_failed else "no change in its recording state"
        raise CameraError(f"the camera did not start recording ({reason}); check the card, free space and screen")

    def stop_recording(self):
        known = self.recording() is not None
        self._press_record(1)
        if known and not self._wait_recording(False):
            raise CameraError("the camera did not confirm that recording stopped; check the camera")

    # ---- contents transfer ------------------------------------------------------------------------------------

    def expose_card(self):
        """Ask the camera to show the memory card to this session. Returns its storage ID."""
        self._op(c.SDIO_SET_CONTENTS_TRANSFER_MODE, (2, 1, 0))
        self._transfer_requested = True
        deadline = time.monotonic() + (CARD_WAIT_PC_REMOTE if self.service == "pcremote" else CARD_WAIT)
        last = None
        while time.monotonic() < deadline:
            reply = self._ask(c.GET_STORAGE_IDS)
            last = reply.code
            if reply.ok:
                ids = ds.u32_array(reply.data)
                cards = [i for i in ids if i & 0xFFFF and i >> 16 != c.STORAGE_VIRTUAL >> 16]
                if cards:
                    self.card = c.STORAGE_CARD if c.STORAGE_CARD in cards else cards[0]
                    return self.card
            time.sleep(0.5)
        raise TransferUnavailable("the camera accepted the request but never exposed the memory card "
                                  f"(last answer to GetStorageIDs: {c.rc_name(last)})")

    def object_info(self, handle):
        if handle not in self._info_cache:
            info = ds.parse_object_info(self._op(c.GET_OBJECT_INFO, (handle,)).data)
            size = None if info.size == 0xFFFFFFFF else info.size
            self._info_cache[handle] = FileEntry(handle, info.name, size, info.date, info.parent,
                                                 info.fmt == ds.FORMAT_FOLDER)
        return self._info_cache[handle]

    def _handles(self, parent):
        reply = self._ask(c.GET_OBJECT_HANDLES, (self.card, 0, parent), timeout=60)
        return ds.u32_array(reply.data) if reply.ok else []

    def list_files(self, progress=None):
        """Every object on the card, with its folder path."""
        handles = self._handles(0)                      # 0 = all objects, whatever the folder
        entries = {}
        if handles:
            for index, handle in enumerate(handles, 1):
                entries[handle] = self.object_info(handle)
                if progress:
                    progress(index, len(handles))
        else:                                           # walk the folders from the root instead
            pending = [0xFFFFFFFF]
            while pending:
                for handle in self._handles(pending.pop()):
                    if handle not in entries:
                        entries[handle] = self.object_info(handle)
                        if entries[handle].is_folder:
                            pending.append(handle)
                        if progress:
                            progress(len(entries), 0)
        for entry in entries.values():
            parts, parent, seen = [entry.name], entry.parent, set()
            while parent in entries and parent not in seen:
                seen.add(parent)
                parts.append(entries[parent].name)
                parent = entries[parent].parent
            entry.path = "/".join(reversed(parts))
        return sorted(entries.values(), key=lambda e: e.path)

    def download(self, entry, out_dir, progress=None):
        """Copy one file to out_dir, resuming a partial download. Returns the destination path."""
        os.makedirs(out_dir, exist_ok=True)
        dest = os.path.join(out_dir, entry.name)
        if entry.size is not None and os.path.exists(dest) and os.path.getsize(dest) == entry.size:
            return dest
        part = dest + ".part"
        offset = os.path.getsize(part) if os.path.exists(part) else 0
        if entry.size is not None and offset > entry.size:
            offset = 0
        large = next((op for op in (c.SDIO_GET_PARTIAL_LARGE_OBJECT, c.SDIO_GET_PARTIAL_LARGE_OBJECT_OLD)
                      if op in self.ops), None)
        with open(part, "r+b" if offset else "wb") as out:
            out.seek(offset)
            if large is None and c.GET_PARTIAL_OBJECT not in self.ops:
                out.seek(0)
                out.truncate()
                out.write(self._op(c.GET_OBJECT, (entry.handle,), timeout=600).data)
                offset = out.tell()
            else:
                last_start = 0.0
                while entry.size is None or offset < entry.size:
                    want = CHUNK if entry.size is None else min(CHUNK, entry.size - offset)
                    time.sleep(max(0.0, READ_SPACING - (time.monotonic() - last_start)))
                    last_start = time.monotonic()
                    if large is not None:
                        params = (entry.handle, offset & 0xFFFFFFFF, offset >> 32, want)
                        data = self._op(large, params, timeout=120).data
                    else:
                        data = self._op(c.GET_PARTIAL_OBJECT, (entry.handle, offset, want), timeout=120).data
                    out.write(data)
                    offset += len(data)
                    if progress:
                        progress(offset, entry.size)
                    if len(data) < want:
                        break
        if entry.size is not None and offset != entry.size:
            raise CameraError(f"{entry.name}: got {offset} of {entry.size} bytes; run again to resume")
        os.replace(part, dest)
        return dest
