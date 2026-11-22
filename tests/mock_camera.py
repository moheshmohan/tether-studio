"""A stand-in ZV-E10 that speaks PTP/IP on localhost.

It encodes the camera behaviour described in the reverse-engineering notes this project is based on (tested by their
author on firmware 2.03). It catches bugs in the client; it cannot prove that the real camera behaves this way.
"""
import hashlib
import socket
import struct
import threading
import time

from zve10 import codes as c
from zve10 import datasets as ds
from zve10 import ptpip

# The list a real ZV-E10 (firmware 2.03) advertises in PC Remote mode over Wi-Fi.
OPS = [0x1001, 0x1002, 0x1003, 0x1004, 0x1005, 0x1006, 0x1007, 0x1008, 0x1009, 0x100A, 0x100D, 0x101B, 0x9201,
       0x9202, 0x9205, 0x9207, 0x9209, 0x920A, 0x920B, 0x920C, 0x920D, 0x920E, 0x920F, 0x9210, 0x9211, 0x9212,
       0x9214, 0x9801, 0x9802, 0x9803, 0x9805]
GENERAL_ERROR, ACCESS_DENIED, INVALID_PARAMETER, INVALID_HANDLE = 0x2002, 0x200F, 0x201D, 0x2009
ROOT = 0xFFFFFFFF


def clip_bytes(name, size):
    """Deterministic content, so a download can be checked byte for byte."""
    block = hashlib.sha256(name.encode()).digest()
    return (block * (size // len(block) + 1))[:size]


class MockZVE10:
    def __init__(self, service="smartphone", clip_size=7_500_000):
        self.service = service          # "smartphone" or "pcremote"
        self.stale_reads = True         # the camera's read fault, see _handle
        self.stale_served = 0
        self.button_delay = 0.3         # seconds before the recording state follows the record button
        self.refuse_record = False      # True: the button does nothing (card full, wrong mode, ...)
        self.presses = []
        self.clip_size = clip_size
        self.flat_listing = True        # False: answer "all objects" with nothing, forcing a folder walk
        self.recording = False
        self.requests = []              # (opcode, params) of every operation received
        self.objects = {}               # handle -> (name, parent, data or None for a folder)
        self._next_handle = 0x40000001
        private = self._add("PRIVATE", ROOT)
        self.clip_folder = self._add("CLIP", self._add("M4ROOT", private))
        self._add("100MSDCF", self._add("DCIM", ROOT))
        self._clip_number = 177
        self._add_clip()
        self._server = socket.socket()
        self._server.bind(("127.0.0.1", 0))
        self._server.listen(4)
        self.port = self._server.getsockname()[1]
        self._event_sock = None
        threading.Thread(target=self._accept, daemon=True).start()

    def _add(self, name, parent, data=None):
        handle, self._next_handle = self._next_handle, self._next_handle + 1
        self.objects[handle] = (name, parent, data)
        return handle

    def _add_clip(self):
        self._clip_number += 1
        name = f"C{self._clip_number:04d}.MP4"
        self._add(name, self.clip_folder, clip_bytes(name, self.clip_size))
        self._add(name.replace(".MP4", "M01.XML"), self.clip_folder, b"<xml/>")
        return name

    def newest_clip(self):
        name = f"C{self._clip_number:04d}.MP4"
        return name, clip_bytes(name, self.clip_size)

    def close(self):
        self._server.close()

    # ---- network ----------------------------------------------------------------------------------------------

    def _accept(self):
        while True:
            try:
                sock, _ = self._server.accept()
            except OSError:
                return
            threading.Thread(target=self._serve, args=(sock,), daemon=True).start()

    def _serve(self, sock):
        try:
            ptype, body = ptpip._recv(sock)
            if ptype == ptpip.INIT_EVT_REQ:
                ptpip._send(sock, ptpip.INIT_EVT_ACK)
                self._event_sock = sock
                return
            ptpip._send(sock, ptpip.INIT_CMD_ACK, struct.pack("<I", 1) + bytes(16)
                        + "ZV-E10\0".encode("utf-16-le") + struct.pack("<I", 0x00010000))
            session = {"mode": None, "auth": 0, "wedged": False, "card_at": None, "listed": False, "last_read": None}
            while True:
                ptype, body = ptpip._recv(sock)
                if ptype != ptpip.CMD_REQUEST:
                    continue
                phase, op, tid = struct.unpack_from("<IHI", body)
                params = list(struct.unpack_from(f"<{(len(body) - 10) // 4}I", body, 10))
                data_out = b""
                if phase == 2:
                    while True:
                        ptype, body = ptpip._recv(sock)
                        if ptype in (ptpip.DATA, ptpip.END_DATA):
                            data_out += body[4:]
                        if ptype == ptpip.END_DATA:
                            break
                self.requests.append((op, params))
                code, data = self._handle(session, op, params, data_out)
                if data is not None:
                    ptpip._send(sock, ptpip.START_DATA, struct.pack("<IQ", tid, len(data)))
                    pieces = [data[i:i + 700_000] for i in range(0, len(data), 700_000)] or [b""]
                    for piece in pieces[:-1]:
                        ptpip._send(sock, ptpip.DATA, struct.pack("<I", tid) + piece)
                    ptpip._send(sock, ptpip.END_DATA, struct.pack("<I", tid) + pieces[-1])
                ptpip._send(sock, ptpip.CMD_RESPONSE, struct.pack("<HI", code, tid))
        except (OSError, ptpip.LinkError):
            pass
        finally:
            sock.close()

    def _event(self, code, *params):
        if self._event_sock:
            try:
                ptpip._send(self._event_sock, ptpip.EVENT,
                            struct.pack("<HI", code, 0) + b"".join(struct.pack("<I", p) for p in params))
            except OSError:
                pass

    # ---- behaviour --------------------------------------------------------------------------------------------

    def _handle(self, s, op, params, data_out):
        if s["wedged"]:
            return GENERAL_ERROR, None
        if op not in OPS:                   # the real camera then fails everything until the session is reopened
            s["wedged"] = True
            return INVALID_PARAMETER, None
        if op == c.GET_DEVICE_INFO:
            info = ds.DeviceInfo("Sony PTP Extensions", OPS, [0x4004, 0xC203], "Sony Corporation", "ZV-E10",
                                 "2.00", "00000000000000000000000000000000")
            return c.OK, ds.pack_device_info(info)
        if op in (c.OPEN_SESSION, c.SDIO_OPEN_SESSION):
            if s["mode"] is not None:
                return c.SESSION_ALREADY_OPEN, None
            mode = params[1] if op == c.SDIO_OPEN_SESSION else 0
            if mode not in (0, 1):
                return INVALID_PARAMETER, None      # the real camera's answer to mode 2
            s["mode"] = mode
            return c.OK, None
        if op == c.CLOSE_SESSION:
            s.update(mode=None, auth=0, card_at=None)
            return c.OK, None
        if s["mode"] is None:
            return 0x2003, None
        if op == c.SDIO_CONNECT:
            s["auth"] = params[0]
            return c.OK, bytes(8)
        if op == c.SDIO_GET_EXT_DEVICE_INFO:
            if params[0] not in (200, 300):
                return INVALID_PARAMETER, None
            return c.OK, (struct.pack("<H", 300) + ds.pack_array("H", [0x5007, 0xD21D, 0xD218])
                          + ds.pack_array("H", [0xD2C1, 0xD2C2, 0xD2C8]))
        if s["auth"] != 3:
            return ACCESS_DENIED, None
        card_visible = s["card_at"] is not None and time.monotonic() >= s["card_at"]
        if op == c.SDIO_GET_ALL_PROPS:
            blob = struct.pack("<II", 4, 0)
            blob += ds.pack_prop(0x5007, 4, 280, enum=[280, 400, 560], second_list=[280, 400])
            blob += ds.pack_prop(0xD218, 1, 75, value_range=(0, 100, 1))
            blob += ds.pack_prop(0xD21D, 4, 1 if self.recording else 0, enum=[0, 1, 2])
            blob += ds.pack_prop(0xD2C8, 4, 1)
            return c.OK, blob
        if op == c.SDIO_CONTROL_DEVICE:
            if s["mode"] != 0 or params[0] != c.CONTROL_MOVIE_REC:
                return ACCESS_DENIED, None
            self._button(struct.unpack("<H", data_out)[0])
            return c.OK, None
        if op == c.SDIO_SET_CONTENTS_TRANSFER_MODE:
            if params[1] == 1 and s["mode"] == 1 and self.service == "smartphone":
                s["card_at"] = time.monotonic() + 0.6
            elif params[1] == 0:
                s["card_at"] = None
            return c.OK, None               # PC Remote accepts the request but never shows the card (as observed)
        if op == c.GET_STORAGE_IDS:
            return (c.OK, ds.pack_array("I", [c.STORAGE_CARD])) if card_visible else (c.STORE_NOT_AVAILABLE, None)
        if not card_visible:
            return c.STORE_NOT_AVAILABLE, None
        if op == c.GET_OBJECT_HANDLES:
            s["listed"] = True
            parent = params[2]
            if parent == 0 and not self.flat_listing:
                return c.OK, ds.pack_array("I", [])
            return c.OK, ds.pack_array("I", [h for h, (_, p, _) in self.objects.items() if parent in (0, p)])
        if params[0] not in self.objects:
            return INVALID_HANDLE, None
        name, parent, data = self.objects[params[0]]
        if op == c.GET_OBJECT_INFO and not s["listed"]:
            # As on the real ZV-E10 (18 Nov 2026): before the list has been asked for in a session,
            # a file is "described" with OK and an empty description.
            return c.OK, ds.pack_object_info(ds.ObjectInfo(0, 0, 0, 0, "", ""))
        if op == c.GET_OBJECT_INFO:
            info = ds.ObjectInfo(c.STORAGE_CARD, 0x3001 if data is None else 0xB982, len(data or b""),
                                 0 if parent == ROOT else parent, name, "20210101T000000")
            return c.OK, ds.pack_object_info(info)
        if op == c.SDIO_GET_PARTIAL_LARGE_OBJECT_OLD:
            offset = params[1] | params[2] << 32
            # As on the real ZV-E10 (18 Nov 2026), only always instead of sometimes: a read of the same file
            # that starts within 0.6 s of the previous read's start is served from that read's position.
            now, last = time.monotonic(), s["last_read"]
            if self.stale_reads and last and last[0] == params[0] and now - last[1] < 0.6:
                self.stale_served += 1
                offset = last[2]
            s["last_read"] = (params[0], now, offset)
            return c.OK, data[offset:offset + params[3]]
        if op == c.GET_PARTIAL_OBJECT:
            return c.OK, data[params[1]:params[1] + params[2]]
        return c.OK, data                   # GetObject

    def _button(self, value):
        """2 starts and 1 stops, as on the real camera, which also takes a moment to follow."""
        self.presses.append(value)
        if self.refuse_record:
            return
        wanted = value == 2

        def apply():
            if self.recording and not wanted:
                self._add_clip()
            if self.recording != wanted:
                self.recording = wanted
                self._event(0xC203, 0)
        threading.Timer(self.button_delay, apply).start()
