"""End-to-end tests of the Wi-Fi client against the mock camera.

Run from the project folder:  python -m unittest -v tests.test_wifi
"""
import contextlib
import io
import os
import tempfile
import unittest

import zve10.__main__ as cli
import zve10.camera as cam
from zve10 import codes as c
from zve10.ptpip import Trace
from tests.mock_camera import MockZVE10, clip_bytes


class WifiClientTests(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.cwd = os.getcwd()
        os.chdir(self.tmp.name)
        self.saved = (cam.VERIFY_WAIT, cam.SETTLE, cam.RECONNECT_PAUSE, cam.CARD_WAIT_PC_REMOTE, cli.SETTLE)
        cam.VERIFY_WAIT, cam.SETTLE, cam.RECONNECT_PAUSE, cam.CARD_WAIT_PC_REMOTE, cli.SETTLE = 0.8, 0.05, 0.05, 1.0, 0.05
        self.mocks = []

    def tearDown(self):
        cam.VERIFY_WAIT, cam.SETTLE, cam.RECONNECT_PAUSE, cam.CARD_WAIT_PC_REMOTE, cli.SETTLE = self.saved
        for mock in self.mocks:
            mock.close()
        os.chdir(self.cwd)
        self.tmp.cleanup()

    def mock(self, **kwargs):
        self.mocks.append(MockZVE10(**kwargs))
        return self.mocks[-1]

    def run_cli(self, mock, *args, service="auto"):
        out, err = io.StringIO(), io.StringIO()
        with contextlib.redirect_stdout(out), contextlib.redirect_stderr(err):
            code = cli.main(["--host", "127.0.0.1", "--port", str(mock.port), "--service", service, *args])
        return code, out.getvalue(), err.getvalue()

    def test_take_records_then_downloads_the_new_clip(self):
        mock = self.mock()
        code, out, err = self.run_cli(mock, "take", "--seconds", "0.3")
        self.assertEqual(code, 0, err)
        name, content = mock.newest_clip()
        self.assertEqual(name, "C0179.MP4")
        with open(os.path.join("downloads", name), "rb") as fh:
            self.assertEqual(fh.read(), content)
        self.assertFalse(mock.recording)
        sessions = [params for op, params in mock.requests if op == c.SDIO_OPEN_SESSION]
        self.assertEqual(sessions, [[1, cam.REMOTE], [1, cam.TRANSFER]])
        modes = [params for op, params in mock.requests if op == c.SDIO_SET_CONTENTS_TRANSFER_MODE]
        self.assertEqual(modes, [[2, 1, 0], [2, 0, 0]])

    def test_record_waits_for_a_camera_that_is_slow_to_follow_the_button(self):
        mock = self.mock()
        mock.button_delay = 1.2
        cam.VERIFY_WAIT = 4.0
        code, _, err = self.run_cli(mock, "record", "--seconds", "0.3")
        self.assertEqual(code, 0, err)
        self.assertFalse(mock.recording)
        self.assertEqual(mock.presses, [2, 1])                           # one start, one stop, nothing else
        self.assertEqual(mock.newest_clip()[0], "C0179.MP4")             # exactly one new clip

    def test_record_that_never_starts_is_reported_and_released(self):
        mock = self.mock()
        mock.refuse_record = True
        code, _, err = self.run_cli(mock, "record", "--seconds", "0.3")
        self.assertEqual(code, 1)
        self.assertIn("did not start recording", err)
        self.assertEqual(mock.presses, [2, 1])

    def test_pc_remote_records_with_a_plain_session(self):
        mock = self.mock(service="pcremote")
        code, _, err = self.run_cli(mock, "record", "--seconds", "0.3", service="pcremote")
        self.assertEqual(code, 0, err)
        self.assertEqual(mock.newest_clip()[0], "C0179.MP4")
        self.assertNotIn(c.SDIO_OPEN_SESSION, [op for op, _ in mock.requests])

    def test_pc_remote_transfer_is_reported_not_hung(self):
        mock = self.mock(service="pcremote")
        code, _, err = self.run_cli(mock, "pull", service="pcremote")
        self.assertEqual(code, 3)
        self.assertIn("never exposed the memory card", err)
        self.assertIn("Smartphone Connect", err)
        modes = [params for op, params in mock.requests if op == c.SDIO_SET_CONTENTS_TRANSFER_MODE]
        self.assertEqual(modes, [[2, 1, 0], [2, 0, 0]])                  # the request is withdrawn afterwards

    def test_download_resumes_a_partial_file(self):
        mock = self.mock()
        content = clip_bytes("C0178.MP4", mock.clip_size)
        os.makedirs("downloads")
        with open(os.path.join("downloads", "C0178.MP4.part"), "wb") as fh:
            fh.write(content[:1_000_000])
        code, _, err = self.run_cli(mock, "pull", "C0178.MP4")
        self.assertEqual(code, 0, err)
        with open(os.path.join("downloads", "C0178.MP4"), "rb") as fh:
            self.assertEqual(fh.read(), content)
        first = next(params for op, params in mock.requests if op == c.SDIO_GET_PARTIAL_LARGE_OBJECT_OLD)
        self.assertEqual(first[1], 1_000_000)

    def test_list_shows_folder_paths_with_either_listing_style(self):
        for flat in (True, False):
            with self.subTest(flat_listing=flat):
                mock = self.mock()
                mock.flat_listing = flat
                code, out, err = self.run_cli(mock, "list")
                self.assertEqual(code, 0, err)
                self.assertIn("PRIVATE/M4ROOT/CLIP/C0178.MP4", out)

    def test_unadvertised_operations_are_never_sent(self):
        mock = self.mock()
        camera = cam.Camera("127.0.0.1", Trace(), bytes(16), port=mock.port)
        camera.open(cam.REMOTE)
        try:
            with self.assertRaises(cam.CameraError):
                camera._op(0x9213)                                       # SDIO_GetDeviceLog
            self.assertNotIn(0x9213, [op for op, _ in mock.requests])
            self.assertFalse(camera.recording())                         # the session still works
        finally:
            camera.close()


if __name__ == "__main__":
    unittest.main()
