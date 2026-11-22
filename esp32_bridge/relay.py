"""Computer side of the ESP32 Wi-Fi bridge (the board runs esp32_bridge.ino).

The board joins the camera's own DIRECT-... network; this program makes the camera reachable on this computer at
127.0.0.1, on the camera's usual ports, while the computer's own Wi-Fi stays on the router:

    .venv/bin/python esp32_bridge/relay.py                 # leave it running
    .venv/bin/python probe/smartphone_connect_test.py --host 127.0.0.1 --port 15740

The camera's network name and password are read from esp32_bridge/camera_wifi.txt: the name on the first line,
the password on the second. They are sent to the board over USB and never printed.

    .venv/bin/python esp32_bridge/relay.py --selftest      # USB link check and speed, no Wi-Fi needed
    .venv/bin/python esp32_bridge/relay.py --scan          # Wi-Fi networks the board can hear

Python standard library only.
"""
import argparse
import glob
import os
import select
import socket
import struct
import sys
import termios
import threading
import time

MAGIC = b"\xA5\x5A"
T_WIFI, T_OPEN, T_DATA, T_CLOSE, T_STATUS, T_ECHO, T_SCAN, T_FLOOD, T_DRAIN = 1, 2, 3, 4, 5, 6, 7, 8, 9
R_WIFI, R_OPENED, R_DATA, R_CLOSED, R_ECHO, R_SCAN, R_HELLO, R_FLOOD, R_DRAIN = 0x81, 0x82, 0x83, 0x84, 0x86, 0x87, 0x88, 0x89, 0x8A
WIFI_IDLE, WIFI_JOINING, WIFI_JOINED = 0, 1, 2
CHANNELS = 6
MAX_PAYLOAD = 4096
DEFAULT_PORTS = "15740:15740,64321:64321"       # PTP/IP (control and files), description documents
HERE = os.path.dirname(os.path.abspath(__file__))
# Espressif's wifi_err_reason_t values worth explaining
REASONS = {2: "authentication expired", 15: "wrong password (handshake timed out)", 201: "network not found",
           202: "wrong password", 203: "the camera refused the association", 204: "wrong password (handshake)",
           205: "connection failed", 8: "this board left the network", 200: "signal lost"}


def frame(ftype, channel=0, payload=b""):
    if len(payload) > MAX_PAYLOAD:
        raise ValueError("payload too large for one frame")
    head = bytes((ftype, channel, len(payload) & 0xFF, len(payload) >> 8))
    return MAGIC + head + bytes((head[0] ^ head[1] ^ head[2] ^ head[3] ^ 0xFF,)) + payload


class Parser:
    """Frames out of the byte stream from the board; anything else on the line (boot messages) is skipped."""

    def __init__(self):
        self.buf = bytearray()

    def feed(self, data):
        self.buf += data
        frames = []
        while True:
            start = self.buf.find(MAGIC)
            if start < 0:
                del self.buf[:max(0, len(self.buf) - 1)]        # keep a possible first magic byte
                break
            if start:
                del self.buf[:start]
            if len(self.buf) < 7:
                break
            ftype, channel, low, high, check = self.buf[2:7]
            length = low | high << 8
            if check != ftype ^ channel ^ low ^ high ^ 0xFF or length > MAX_PAYLOAD:
                del self.buf[:1]                                # not a frame: look for the next magic
                continue
            if len(self.buf) < 7 + length:
                break
            frames.append((ftype, channel, bytes(self.buf[7:7 + length])))
            del self.buf[:7 + length]
        return frames


def open_serial(path):
    fd = os.open(path, os.O_RDWR | os.O_NOCTTY | os.O_NONBLOCK)
    attrs = termios.tcgetattr(fd)
    attrs[0] = attrs[1] = attrs[3] = 0                                  # raw: no input, output or line processing
    attrs[2] = (attrs[2] | termios.CLOCAL | termios.CREAD | termios.CS8) & ~(termios.PARENB | termios.HUPCL)
    attrs[6][termios.VMIN] = attrs[6][termios.VTIME] = 0
    termios.tcsetattr(fd, termios.TCSANOW, attrs)
    return fd


def find_port():
    ports = sorted(glob.glob("/dev/cu.usbmodem*") + glob.glob("/dev/ttyACM*"))
    return ports[0] if ports else None


class Bridge:
    def __init__(self, fd, log=print):
        self.fd, self.log = fd, log
        self.parser = Parser()
        self.wlock = threading.Lock()
        self.lock = threading.Lock()
        self.owner = [None] * CHANNELS          # the local socket using each channel, or "closing"
        self.opened = [threading.Event() for _ in range(CHANNELS)]
        self.open_ok = [False] * CHANNELS
        self.hello = threading.Event()
        self.boot_id = None
        self.version = None
        self.wifi = None                        # (state, reason, ip, gateway, signal)
        self.wifi_changed = threading.Condition()
        self.echoes = []
        self.scan_done, self.scan_result = False, None
        self.flood_bytes, self.flood_last = 0, 0.0
        self.drained = None                     # (bytes, seconds) of the last T_DRAIN measurement
        self.echo_cond = threading.Condition()
        self.last_frame = time.monotonic()
        self.closed = False
        self.on_reboot = None
        threading.Thread(target=self._read_loop, daemon=True).start()

    # ---- USB side ---------------------------------------------------------------------------------------------

    def send(self, ftype, channel=0, payload=b""):
        data = frame(ftype, channel, payload)
        with self.wlock:
            view = memoryview(data)
            deadline = time.monotonic() + 10
            while view:
                try:
                    view = view[os.write(self.fd, view):]
                except BlockingIOError:
                    if time.monotonic() > deadline:
                        raise OSError("the board is not taking data on USB")
                    select.select([], [self.fd], [], 0.5)

    def _read_loop(self):
        while not self.closed:
            try:
                ready, _, _ = select.select([self.fd], [], [], 0.5)
                if not ready:
                    continue
                data = os.read(self.fd, 65536)
            except (OSError, ValueError):
                break
            if not data:
                time.sleep(0.05)
                continue
            for ftype, channel, payload in self.parser.feed(data):
                self.last_frame = time.monotonic()
                try:
                    self._dispatch(ftype, channel, payload)
                except OSError:
                    pass
        self.closed = True
        self._drop_all()

    def _dispatch(self, ftype, channel, payload):
        if ftype == R_DATA and channel < CHANNELS:
            sock = self.owner[channel]
            if isinstance(sock, socket.socket):
                sock.sendall(payload)
        elif ftype == R_OPENED and channel < CHANNELS:
            self.open_ok[channel] = bool(payload and payload[0])
            self.opened[channel].set()
        elif ftype == R_CLOSED and channel < CHANNELS:
            with self.lock:
                sock, self.owner[channel] = self.owner[channel], None
            if isinstance(sock, socket.socket):
                self._shutdown(sock)
        elif ftype == R_HELLO and len(payload) >= 5:
            boot_id = struct.unpack_from("<I", payload, 1)[0]
            rebooted = self.boot_id is not None and boot_id != self.boot_id
            self.version, self.boot_id = payload[0], boot_id
            self.hello.set()
            if rebooted:
                self.log("the board restarted; reconnecting")
                self._drop_all()
                if self.on_reboot:
                    threading.Thread(target=self.on_reboot, daemon=True).start()
        elif ftype == R_WIFI and len(payload) >= 11:
            state = (payload[0], payload[1], socket.inet_ntoa(payload[2:6]), socket.inet_ntoa(payload[6:10]),
                     struct.unpack_from("<b", payload, 10)[0])
            with self.wifi_changed:
                self.wifi = state
                self.wifi_changed.notify_all()
        elif ftype == R_ECHO:
            with self.echo_cond:
                self.echoes.append(payload)
                self.echo_cond.notify_all()
        elif ftype == R_DRAIN and len(payload) >= 8:
            count, micros = struct.unpack_from("<II", payload)
            with self.echo_cond:
                self.drained = (count, micros / 1e6)
                self.echo_cond.notify_all()
        elif ftype == R_FLOOD:
            with self.echo_cond:
                self.flood_bytes += len(payload)
                self.flood_last = time.monotonic()
                self.echo_cond.notify_all()
        elif ftype == R_SCAN and payload:
            found, at = [], 1
            for _ in range(0 if payload[0] == 0xFF else payload[0]):
                if at + 4 > len(payload):
                    break
                signal, channel_no, security, length = struct.unpack_from("<bBBB", payload, at)
                found.append((payload[at + 4:at + 4 + length].decode("utf-8", "replace"), signal, channel_no, security))
                at += 4 + length
            with self.echo_cond:
                self.scan_result = None if payload[0] == 0xFF else found
                self.scan_done = True
                self.echo_cond.notify_all()

    @staticmethod
    def _shutdown(sock):
        try:
            sock.shutdown(socket.SHUT_RDWR)
        except OSError:
            pass

    def _drop_all(self):
        with self.lock:
            socks, self.owner = self.owner, [None] * CHANNELS
        for sock in socks:
            if isinstance(sock, socket.socket):
                self._shutdown(sock)

    def close(self):
        self.closed = True
        self._drop_all()
        try:
            os.close(self.fd)
        except OSError:
            pass

    # ---- handshake and Wi-Fi ----------------------------------------------------------------------------------

    def wait_for_board(self, timeout=12.0):
        deadline = time.monotonic() + timeout
        while time.monotonic() < deadline:
            self.send(T_STATUS)
            if self.hello.wait(0.5):
                return True
        return False

    def flood_test(self, frames=500):
        """The board sends `frames` full frames as fast as it can. Returns (bytes received, seconds)."""
        wanted = frames * MAX_PAYLOAD
        with self.echo_cond:
            self.flood_bytes = 0
        started = time.monotonic()
        self.send(T_FLOOD, 0, struct.pack("<H", frames))
        with self.echo_cond:
            self.echo_cond.wait_for(lambda: self.flood_bytes >= wanted, timeout=60)
            return self.flood_bytes, max(self.flood_last - started, 1e-6)

    def drain(self, request, timeout=120.0):
        """Wi-Fi side alone: the board counts and throws away what the camera sends after `request()` has run,
        until the camera has been silent for a second. Returns (bytes, seconds from first to last byte) or None."""
        with self.echo_cond:
            self.drained = None
        self.send(T_DRAIN)
        time.sleep(0.05)
        request()
        with self.echo_cond:
            self.echo_cond.wait_for(lambda: self.drained is not None, timeout=timeout)
            return self.drained

    def scan(self, timeout=20.0):
        """Networks the board can hear, as (name, signal dBm, channel, security), strongest first; None if it failed."""
        with self.echo_cond:
            self.scan_done, self.scan_result = False, None
        self.send(T_SCAN)
        with self.echo_cond:
            if not self.echo_cond.wait_for(lambda: self.scan_done, timeout=timeout):
                return None
            return sorted(self.scan_result, key=lambda net: -net[1]) if self.scan_result is not None else None

    def join(self, name, password, timeout=40.0):
        """Ask the board to join the camera's network. Returns the final (state, reason, ip, gateway, signal)."""
        self.send(T_WIFI, 0, name.encode() + b"\0" + password.encode())
        deadline = time.monotonic() + timeout
        with self.wifi_changed:
            self.wifi = None
        while time.monotonic() < deadline:
            with self.wifi_changed:
                self.wifi_changed.wait(1.0)
                state = self.wifi
            if state and state[0] == WIFI_JOINED and state[2] != "0.0.0.0":
                return state
            self.send(T_STATUS)
        return self.wifi

    # ---- TCP side ---------------------------------------------------------------------------------------------

    def serve(self, conn, target_ip, target_port):
        """Carry one local connection to target_ip:target_port on the board's network."""
        with self.lock:
            channel = next((i for i, owner in enumerate(self.owner) if owner is None), None)
            if channel is not None:
                self.owner[channel] = conn
                self.opened[channel].clear()
        if channel is None:
            self.log("no free channel on the board; connection refused")
            conn.close()
            return
        try:
            self.send(T_OPEN, channel, socket.inet_aton(target_ip) + struct.pack("<H", target_port))
            if self.opened[channel].wait(9.0) and self.open_ok[channel]:
                while True:
                    data = conn.recv(MAX_PAYLOAD)
                    if not data:
                        break
                    self.send(T_DATA, channel, data)
        except OSError:
            pass
        finally:
            with self.lock:
                mine = self.owner[channel] is conn
                if mine:
                    self.owner[channel] = "closing"     # freed when the board confirms
            if mine and not self.closed:
                try:
                    self.send(T_CLOSE, channel)
                except OSError:
                    pass
            conn.close()

    def listen(self, local_port, target_ip, target_port, host="127.0.0.1"):
        server = socket.socket()
        server.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
        server.bind((host, local_port))
        server.listen(8)

        def accept():
            while not self.closed:
                try:
                    conn, _ = server.accept()
                except OSError:
                    break
                conn.setsockopt(socket.IPPROTO_TCP, socket.TCP_NODELAY, 1)
                threading.Thread(target=self.serve, args=(conn, target_ip(), target_port), daemon=True).start()
        threading.Thread(target=accept, daemon=True).start()
        return server

    # ---- self test --------------------------------------------------------------------------------------------

    def echo_test(self, count=200, size=MAX_PAYLOAD):
        """Send frames that the board returns unchanged. Returns (frames correct, seconds, bytes each way)."""
        payloads = [bytes((i * 7 + j) & 0xFF for j in range(size)) for i in range(8)]
        with self.echo_cond:
            self.echoes.clear()
        started = time.monotonic()
        correct = 0
        for i in range(count):
            self.send(T_ECHO, 0, payloads[i % 8])
            with self.echo_cond:
                if not self.echo_cond.wait_for(lambda: self.echoes, timeout=5):
                    break
                correct += self.echoes.pop(0) == payloads[i % 8]
        return correct, time.monotonic() - started, count * size


def read_wifi_file(path):
    with open(path, encoding="utf-8") as fh:
        lines = [line.rstrip("\r\n") for line in fh if line.strip() and not line.lstrip().startswith("#")]
    if len(lines) < 2:
        raise ValueError("need the network name on the first line and the password on the second")
    return lines[0].strip(), lines[1].strip()


def describe_wifi(state):
    if state is None:
        return "no answer from the board"
    code, reason, ip, gateway, signal = state
    if code == WIFI_JOINED:
        return f"joined, board address {ip}, camera at {gateway}, signal {signal} dBm"
    why = f" (last problem: {REASONS.get(reason, f'reason {reason}')})" if reason else ""
    return ("not started" if code == WIFI_IDLE else "still trying to join") + why


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--serial", help="the board's USB port (default: the first /dev/cu.usbmodem*)")
    parser.add_argument("--wifi-file", default=os.path.join(HERE, "camera_wifi.txt"))
    parser.add_argument("--ports", default=DEFAULT_PORTS, help=f"local:camera port pairs (default {DEFAULT_PORTS})")
    parser.add_argument("--camera-ip", help="camera address on its own network (default: the network's gateway)")
    parser.add_argument("--selftest", action="store_true", help="check the USB link and its speed, then stop")
    parser.add_argument("--scan", action="store_true", help="list the Wi-Fi networks the board can hear, then stop")
    args = parser.parse_args(argv)

    path = args.serial or find_port()
    if not path:
        print("No ESP32 board found on USB (no /dev/cu.usbmodem* port).", file=sys.stderr)
        return 2
    bridge = Bridge(open_serial(path))
    try:
        if not bridge.wait_for_board():
            print(f"The board on {path} does not answer. Is the bridge program flashed on it?", file=sys.stderr)
            return 2
        print(f"Board on {path}: bridge version {bridge.version}", flush=True)
        if args.selftest:
            correct, seconds, size = bridge.echo_test()
            print(f"USB link: {correct}/200 frames returned intact, {size / 1024 / seconds:.0f} KB/s each way "
                  f"at the same time", flush=True)
            if bridge.version >= 3:
                got, took = bridge.flood_test()
                print(f"USB link, board to computer only: {got / 1e6:.1f} MB in {took:.1f} s = {got / 1e6 / took:.2f} MB/s",
                      flush=True)
            return 0 if correct == 200 else 1
        if args.scan:
            found = bridge.scan()
            if found is None:
                print("The board could not scan (older bridge program, or the radio is busy).", file=sys.stderr)
                return 1
            print(f"The board hears {len(found)} networks:", flush=True)
            for name, signal, channel_no, security in found:
                print(f"  {signal:4d} dBm  channel {channel_no:2d}  {'open' if security == 0 else 'secured'}  {name!r}")
            return 0
        try:
            name, password = read_wifi_file(args.wifi_file)
        except (OSError, ValueError) as err:
            print(f"Cannot read the camera's Wi-Fi details from {args.wifi_file}: {err}\n"
                  "Put the DIRECT-... network name on the first line and its password on the second.", file=sys.stderr)
            return 2

        def join():
            state = bridge.join(name, password)
            print(f"Camera network '{name}': {describe_wifi(state)}", flush=True)
            return state
        bridge.on_reboot = join
        state = join()
        if not state or state[0] != WIFI_JOINED:
            print("The board keeps trying; leave the camera on its Connection screen.", flush=True)

        def camera_ip():
            return args.camera_ip or (bridge.wifi[3] if bridge.wifi and bridge.wifi[0] == WIFI_JOINED else "192.168.122.1")
        for pair in args.ports.split(","):
            local, _, remote = pair.partition(":")
            bridge.listen(int(local), camera_ip, int(remote or local))
        print(f"READY: camera reachable at 127.0.0.1, ports {args.ports}", flush=True)
        shown = state
        while not bridge.closed:
            time.sleep(2.0)
            bridge.send(T_STATUS)
            current = bridge.wifi
            if current and shown and current[0] != shown[0]:
                print(f"Camera network: {describe_wifi(current)}", flush=True)
            shown = current or shown
            if time.monotonic() - bridge.last_frame > 8:
                print("The board has stopped answering on USB.", file=sys.stderr, flush=True)
                return 1
        return 1
    except KeyboardInterrupt:
        return 130
    except OSError as err:
        print(f"USB link failed: {err}", file=sys.stderr)
        return 1
    finally:
        bridge.close()


if __name__ == "__main__":
    sys.exit(main())
