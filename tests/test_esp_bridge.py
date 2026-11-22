"""The ESP32 bridge relay, tested against a stand-in for the board on a pseudo-terminal and the mock camera.

Run from the project folder:  python -m unittest -v tests.test_esp_bridge
"""
import importlib.util
import os
import pty
import select
import socket
import struct
import tempfile
import threading
import time
import unittest

import zve10.camera as cam
from zve10.ptpip import Trace
from tests.mock_camera import MockZVE10

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
spec = importlib.util.spec_from_file_location("esp_relay", os.path.join(ROOT, "esp32_bridge", "relay.py"))
relay = importlib.util.module_from_spec(spec)
spec.loader.exec_module(relay)


class FakeBoard:
    """Speaks the board's side of the USB protocol; every connection goes to 127.0.0.1 whatever address is asked."""

    def __init__(self):
        self.master, slave = pty.openpty()
        self.path = os.ttyname(slave)
        self.slave = slave
        self.parser = relay.Parser()
        self.socks = {}
        self.joined = None
        self.boot_id = 0x1234
        self.wlock = threading.Lock()
        self.running = True
        threading.Thread(target=self._loop, daemon=True).start()

    def send(self, ftype, channel=0, payload=b""):
        with self.wlock:
            os.write(self.master, relay.frame(ftype, channel, payload))

    def noise(self, data):
        with self.wlock:
            os.write(self.master, data)

    def _wifi(self):
        state = relay.WIFI_JOINED if self.joined else relay.WIFI_IDLE
        self.send(relay.R_WIFI, 0, bytes((state, 0)) + socket.inet_aton("192.168.122.50")
                  + socket.inet_aton("192.168.122.1") + struct.pack("<b", -40))

    def _pump(self, channel, sock):
        try:
            while True:
                data = sock.recv(relay.MAX_PAYLOAD)
                if not data:
                    break
                self.send(relay.R_DATA, channel, data)
        except OSError:
            pass
        if self.socks.get(channel) is sock:
            del self.socks[channel]
            sock.close()
            self.send(relay.R_CLOSED, channel)

    def _loop(self):
        while self.running:
            try:
                ready, _, _ = select.select([self.master], [], [], 0.2)
                if not ready:
                    continue
                data = os.read(self.master, 65536)
            except (OSError, ValueError):       # the test closed the pseudo-terminal
                break
            for ftype, channel, payload in self.parser.feed(data):
                if ftype == relay.T_STATUS:
                    self.send(relay.R_HELLO, 0, bytes((1,)) + struct.pack("<I", self.boot_id))
                    self._wifi()
                elif ftype == relay.T_WIFI:
                    self.joined = payload.split(b"\0")
                    self._wifi()
                elif ftype == relay.T_ECHO:
                    self.send(relay.R_ECHO, channel, payload)
                elif ftype == relay.T_SCAN:
                    nets = [(b"HomeRouter", -70, 6, 3), (b"DIRECT-abCD:ZV-E10", -35, 1, 3), (b"", -80, 11, 0)]
                    self.send(relay.R_SCAN, 0, bytes((len(nets),)) + b"".join(
                        struct.pack("<bBBB", sig, chan, sec, len(name)) + name for name, sig, chan, sec in nets))
                elif ftype == relay.T_OPEN:
                    port = struct.unpack_from("<H", payload, 4)[0]
                    try:
                        sock = socket.create_connection(("127.0.0.1", port), timeout=3)
                        sock.settimeout(None)
                        self.socks[channel] = sock
                        self.send(relay.R_OPENED, channel, b"\x01")
                        threading.Thread(target=self._pump, args=(channel, sock), daemon=True).start()
                    except OSError:
                        self.send(relay.R_OPENED, channel, b"\x00")
                elif ftype == relay.T_DATA and channel in self.socks:
                    self.socks[channel].sendall(payload)
                elif ftype == relay.T_CLOSE:
                    sock = self.socks.pop(channel, None)
                    if sock:
                        sock.close()
                    self.send(relay.R_CLOSED, channel)

    def close(self):
        self.running = False
        os.close(self.master)
        os.close(self.slave)


def free_port():
    with socket.socket() as probe:
        probe.bind(("127.0.0.1", 0))
        return probe.getsockname()[1]


class ParserTests(unittest.TestCase):
    def test_frames_survive_noise_and_arbitrary_splits(self):
        frames = [(relay.R_DATA, 2, bytes(range(256)) * 3), (relay.R_CLOSED, 2, b""), (relay.R_ECHO, 0, b"\xA5\x5A\xA5")]
        stream = b"ESP-ROM:esp32c3\r\n\xA5boot\xA5\x5A\x01" + b"".join(relay.frame(*f) for f in frames) + b"tail"
        for step in (1, 3, 7, 4096):
            parser, got = relay.Parser(), []
            for i in range(0, len(stream), step):
                got += parser.feed(stream[i:i + step])
            self.assertEqual(got, frames, f"split every {step} bytes")

    def test_oversized_payload_is_refused(self):
        with self.assertRaises(ValueError):
            relay.frame(relay.T_DATA, 0, b"x" * (relay.MAX_PAYLOAD + 1))


class RelayTests(unittest.TestCase):
    def setUp(self):
        self.saved = (cam.VERIFY_WAIT, cam.SETTLE, cam.RECONNECT_PAUSE)
        cam.VERIFY_WAIT, cam.SETTLE, cam.RECONNECT_PAUSE = 0.8, 0.05, 0.05
        self.board = FakeBoard()
        self.bridge = relay.Bridge(relay.open_serial(self.board.path), log=lambda text: None)
        self.tmp = tempfile.TemporaryDirectory()

    def tearDown(self):
        cam.VERIFY_WAIT, cam.SETTLE, cam.RECONNECT_PAUSE = self.saved
        self.bridge.close()
        self.board.close()
        self.tmp.cleanup()

    def test_handshake_join_and_echo(self):
        self.board.noise(b"ESP-ROM:esp32c3-api1-20210207\r\nrst:0x15 (USB_UART_CHIP_RESET)\r\n")
        self.assertTrue(self.bridge.wait_for_board(timeout=3))
        state = self.bridge.join("DIRECT-abCD:ZV-E10", "secret pass", timeout=3)
        self.assertEqual(state[0], relay.WIFI_JOINED)
        self.assertEqual(state[3], "192.168.122.1")
        self.assertEqual(self.board.joined, [b"DIRECT-abCD:ZV-E10", b"secret pass"])
        correct, _, _ = self.bridge.echo_test(count=20)
        self.assertEqual(correct, 20)

    def test_scan_lists_networks_strongest_first(self):
        self.assertTrue(self.bridge.wait_for_board(timeout=3))
        self.assertEqual(self.bridge.scan(timeout=3), [("DIRECT-abCD:ZV-E10", -35, 1, 3), ("HomeRouter", -70, 6, 3),
                                                       ("", -80, 11, 0)])

    def test_record_and_download_through_the_bridge(self):
        mock = MockZVE10(clip_size=3_000_000)
        local = free_port()
        self.assertTrue(self.bridge.wait_for_board(timeout=3))
        self.bridge.listen(local, lambda: "192.168.122.1", mock.port)
        camera = cam.Camera("127.0.0.1", Trace(), os.urandom(16), service="smartphone", port=local)
        try:
            camera.open(cam.REMOTE)
            self.assertTrue(camera.start_recording())
            camera.stop_recording()
            camera.switch(cam.TRANSFER)
            camera.expose_card()
            newest = cam.newest_video(camera.list_files())
            dest = camera.download(newest, self.tmp.name)
            name, content = mock.newest_clip()
            self.assertEqual(newest.name, name)
            with open(dest, "rb") as fh:
                self.assertEqual(fh.read(), content)
            camera.switch(cam.REMOTE)
            self.assertFalse(camera.recording())
        finally:
            camera.close()
            mock.close()
        deadline = time.monotonic() + 3
        while time.monotonic() < deadline and any(self.bridge.owner):
            time.sleep(0.05)
        self.assertEqual(self.bridge.owner, [None] * relay.CHANNELS, "every channel is released after use")

    def test_connection_to_a_closed_port_is_closed_not_hung(self):
        self.assertTrue(self.bridge.wait_for_board(timeout=3))
        local = free_port()
        self.bridge.listen(local, lambda: "192.168.122.1", free_port())
        conn = socket.create_connection(("127.0.0.1", local), timeout=5)
        self.assertEqual(conn.recv(10), b"")
        conn.close()


if __name__ == "__main__":
    unittest.main()
