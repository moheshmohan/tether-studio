"""PTP over TCP/IP (CIPA DC-005): the two-socket handshake, transactions with data phases, and events."""
import errno
import queue
import socket
import struct
import sys
import threading
import time
from dataclasses import dataclass

from .codes import OK, event_name, op_name, rc_name

PORT = 15740
INIT_CMD_REQ, INIT_CMD_ACK, INIT_EVT_REQ, INIT_EVT_ACK, INIT_FAIL = 1, 2, 3, 4, 5
CMD_REQUEST, CMD_RESPONSE, EVENT, START_DATA, DATA, CANCEL, END_DATA, PING, PONG = 6, 7, 8, 9, 10, 11, 12, 13, 14
MAX_PACKET = 64 * 1024 * 1024


class LinkError(Exception):
    """The connection to the camera failed or was refused."""


class Trace:
    """Timestamped protocol log: always to the file, and to stderr when echo is on."""

    def __init__(self, path=None, echo=False):
        self.path, self.echo = path, echo
        self._file = open(path, "a", encoding="utf-8") if path else None
        self._start = time.monotonic()

    def __call__(self, text):
        if self._file:
            self._file.write(f"{time.monotonic() - self._start:9.3f}  {text}\n")
            self._file.flush()
        if self.echo:
            print(f"    | {text}", file=sys.stderr)


@dataclass
class Reply:
    code: int
    params: list
    data: bytes

    @property
    def ok(self):
        return self.code == OK


def _send(sock, ptype, payload=b""):
    sock.sendall(struct.pack("<II", 8 + len(payload), ptype) + payload)


def _recv_exact(sock, count):
    buf = bytearray()
    while len(buf) < count:
        chunk = sock.recv(min(count - len(buf), 1 << 20))
        if not chunk:
            raise LinkError("the camera closed the connection")
        buf += chunk
    return bytes(buf)


def _recv(sock):
    length, ptype = struct.unpack("<II", _recv_exact(sock, 8))
    if not 8 <= length <= MAX_PACKET:
        raise LinkError(f"bad packet length {length}")
    return ptype, _recv_exact(sock, length - 8)


def _explain(err, host):
    if isinstance(err, socket.timeout):
        return f"no answer from {host} in time"
    if getattr(err, "errno", None) in (errno.EHOSTUNREACH, errno.ENETUNREACH):
        return (f"cannot reach {host} ({err}). Check that this computer and the camera are on the same network; on "
                "macOS also allow Local Network access for the app running this command (System Settings > Privacy & "
                "Security > Local Network)")
    return f"connection to {host} failed: {err}"


class Link:
    def __init__(self, host, guid, name, trace, port=PORT, reply_timeout=30.0):
        self.host, self.port, self.guid, self.name, self.trace = host, port, guid, name, trace
        self.reply_timeout = reply_timeout
        self.events = queue.Queue()
        self.camera_name = ""
        self._cmd = self._evt = None
        self._tid = 0
        self._lock = threading.Lock()

    def connect(self, pairing_timeout=90.0):
        """Open both channels. The camera may hold the first answer until pairing is confirmed on its screen."""
        try:
            self._cmd = socket.create_connection((self.host, self.port), timeout=8)
            self._cmd.setsockopt(socket.IPPROTO_TCP, socket.TCP_NODELAY, 1)
            _send(self._cmd, INIT_CMD_REQ,
                  self.guid + (self.name + "\0").encode("utf-16-le") + struct.pack("<I", 0x00010000))
            self._cmd.settimeout(pairing_timeout)
            ptype, body = _recv(self._cmd)
            if ptype == INIT_FAIL:
                reason = struct.unpack_from("<I", body)[0] if len(body) >= 4 else None
                raise LinkError(f"the camera refused the connection (reason {reason}). If it is in PC Remote mode, "
                                "choose Network > PC Remote Function > Pairing on the camera and run this again")
            if ptype != INIT_CMD_ACK or len(body) < 20:
                raise LinkError(f"unexpected answer to the connection request (packet type {ptype})")
            connection = struct.unpack_from("<I", body)[0]
            self.camera_name = body[20:-4].decode("utf-16-le", "replace").split("\0")[0]
            self.trace(f"connected to '{self.camera_name}' at {self.host}:{self.port}, connection {connection}")
            self._evt = socket.create_connection((self.host, self.port), timeout=8)
            _send(self._evt, INIT_EVT_REQ, struct.pack("<I", connection))
            ptype, _ = _recv(self._evt)
            if ptype != INIT_EVT_ACK:
                raise LinkError(f"event channel refused (packet type {ptype})")
            self._evt.settimeout(None)
        except OSError as err:
            self.close()
            raise LinkError(_explain(err, self.host)) from err
        except LinkError:
            self.close()
            raise
        self._tid = 0
        threading.Thread(target=self._read_events, args=(self._evt,), daemon=True).start()

    def _read_events(self, sock):
        try:
            while True:
                ptype, body = _recv(sock)
                if ptype == PING:
                    _send(sock, PONG)
                elif ptype == EVENT and len(body) >= 6:
                    code = struct.unpack_from("<H", body)[0]
                    params = list(struct.unpack_from(f"<{(len(body) - 6) // 4}I", body, 6))
                    self.trace(f"** event {event_name(code)} {params}")
                    self.events.put((code, params))
        except (OSError, LinkError):
            pass

    def transact(self, op, params=(), data_out=None, tid=None, timeout=None):
        """Run one operation. `tid` overrides the transaction ID and restarts the counter after it."""
        if self._cmd is None:
            raise LinkError("not connected")
        with self._lock:
            if tid is None:
                tid = self._tid
            self._tid = tid + 1
            sent = f" + {len(data_out)} bytes {data_out[:16].hex()}" if data_out is not None else ""
            self.trace(f"-> {op_name(op)} {list(params)} tid={tid}{sent}")
            try:
                self._cmd.settimeout(timeout or self.reply_timeout)
                _send(self._cmd, CMD_REQUEST, struct.pack("<IHI", 2 if data_out is not None else 1, op, tid)
                      + b"".join(struct.pack("<I", p & 0xFFFFFFFF) for p in params))
                if data_out is not None:
                    _send(self._cmd, START_DATA, struct.pack("<IQ", tid, len(data_out)))
                    _send(self._cmd, DATA, struct.pack("<I", tid) + data_out)
                    _send(self._cmd, END_DATA, struct.pack("<I", tid))
                data = bytearray()
                while True:
                    ptype, body = _recv(self._cmd)
                    if ptype in (DATA, END_DATA):
                        data += body[4:]
                    elif ptype == CMD_RESPONSE:
                        code = struct.unpack_from("<H", body)[0]
                        rparams = list(struct.unpack_from(f"<{(len(body) - 6) // 4}I", body, 6))
                        break
                    elif ptype == PING:
                        _send(self._cmd, PONG)
                    elif ptype != START_DATA:
                        self.trace(f"   (ignored packet type {ptype}, {len(body)} bytes)")
            except OSError as err:
                self.trace(f"<- LINK FAILURE {err!r}")
                raise LinkError(_explain(err, self.host)) from err
            got = f" data={len(data)} bytes {bytes(data[:24]).hex()}" if data else ""
            self.trace(f"<- {rc_name(code)} {rparams}{got}")
            return Reply(code, rparams, bytes(data))

    def close(self):
        for sock in (self._evt, self._cmd):
            if sock is not None:
                try:
                    sock.close()
                except OSError:
                    pass
        self._cmd = self._evt = None
