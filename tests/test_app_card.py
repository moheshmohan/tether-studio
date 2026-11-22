"""The Mac app's card reader (TetherStudio --card-check) against the mock camera.

Skipped when the app has not been built (cd TetherStudio && swift build).
Run from the project folder:  python -m unittest -v tests.test_app_card
"""
import os
import subprocess
import tempfile
import unittest

from tests.mock_camera import MockZVE10

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
APP = os.path.join(ROOT, "TetherStudio", ".build", "debug", "TetherStudio")
FOLDER = "CLIP"         # the app files a clip under the last folder the camera lists it in


@unittest.skipUnless(os.path.exists(APP), "the app is not built")
class AppCardTests(unittest.TestCase):
    def check(self, mock, out, *more):
        return subprocess.run([APP, "--card-check", f"127.0.0.1:{mock.port}", "--download", out, *more],
                              capture_output=True, text=True, timeout=120)

    def tree(self, top):
        return sorted(os.path.relpath(os.path.join(d, f), top) for d, _, files in os.walk(top) for f in files)

    def test_lists_downloads_and_resumes(self):
        mock = MockZVE10(service="smartphone", clip_size=7_500_000)
        self.addCleanup(mock.close)
        name, content = mock.newest_clip()
        with tempfile.TemporaryDirectory() as out:
            run = self.check(mock, out)
            self.assertEqual(run.returncode, 0, run.stdout + run.stderr)
            self.assertIn(name, run.stdout)
            path = os.path.join(out, FOLDER, name)
            with open(path, "rb") as fh:
                self.assertEqual(fh.read(), content)

            part = os.path.join(out, FOLDER, "." + name + ".part")  # an interrupted copy is continued, not restarted
            os.rename(path, part)
            with open(part, "r+b") as fh:
                fh.truncate(2_000_000)
            self.assertEqual(self.check(mock, out).returncode, 0)
            with open(path, "rb") as fh:
                self.assertEqual(fh.read(), content)
            self.assertEqual(self.tree(out), [os.path.join(FOLDER, name)])

    def test_nothing_already_there_is_deleted_or_replaced(self):
        """The copy runs in a session of its own, as the app's download buttons do. On 18 Nov 2026 that
        path met the camera's empty file description and removed the download folder."""
        mock = MockZVE10(service="smartphone", clip_size=300_000)
        self.addCleanup(mock.close)
        name, content = mock.newest_clip()
        with tempfile.TemporaryDirectory() as out:
            os.makedirs(os.path.join(out, FOLDER))
            for keep, data in (("C0001.MP4", b"an older clip"), (name, b"another file that has this clip's name")):
                with open(os.path.join(out, FOLDER, keep), "wb") as fh:
                    fh.write(data)
            run = self.check(mock, out)
            self.assertEqual(run.returncode, 0, run.stdout + run.stderr)
            base, ext = os.path.splitext(name)
            self.assertEqual(self.tree(out), sorted(os.path.join(FOLDER, f) for f in ("C0001.MP4", name, f"{base} (2){ext}")))
            with open(os.path.join(out, FOLDER, name), "rb") as fh:
                self.assertEqual(fh.read(), b"another file that has this clip's name")
            with open(os.path.join(out, FOLDER, f"{base} (2){ext}"), "rb") as fh:
                self.assertEqual(fh.read(), content)

    def test_a_file_described_before_the_list_is_refused(self):
        mock = MockZVE10(service="smartphone", clip_size=100_000)
        self.addCleanup(mock.close)
        handle = max(h for h, (_, _, data) in mock.objects.items() if data is not None)
        with tempfile.TemporaryDirectory() as out:
            run = self.check(mock, out, "--probe-info", f"0x{handle:08X}")
            self.assertIn("before listing: The camera gave no usable description", run.stdout)
            self.assertEqual(run.returncode, 0, run.stdout + run.stderr)     # and the copy after the list still works

    def test_reads_are_spaced_so_the_camera_serves_the_right_piece(self):
        """The mock, like the camera, serves a read of the same file from the previous read's position
        when it follows too soon. With the app's spacing that never happens."""
        mock = MockZVE10(service="smartphone", clip_size=3 * 3_145_728 + 100)       # three full pieces and a tiny last one
        self.addCleanup(mock.close)
        name, content = mock.newest_clip()
        with tempfile.TemporaryDirectory() as out:
            run = self.check(mock, out)
            self.assertEqual(run.returncode, 0, run.stdout + run.stderr)
            with open(os.path.join(out, FOLDER, name), "rb") as fh:
                self.assertEqual(fh.read(), content)
        self.assertEqual(mock.stale_served, 0)

    def test_a_piece_served_from_the_wrong_place_is_noticed_and_read_again(self):
        """Second line of defence: with the spacing switched off the mock does serve wrong pieces;
        the app notices a piece that begins like the one before it and reads it again."""
        mock = MockZVE10(service="smartphone", clip_size=3 * 3_145_728 + 100)
        self.addCleanup(mock.close)
        name, content = mock.newest_clip()
        with tempfile.TemporaryDirectory() as out:
            run = self.check(mock, out, "--no-read-spacing")
            self.assertEqual(run.returncode, 0, run.stdout + run.stderr)
            with open(os.path.join(out, FOLDER, name), "rb") as fh:
                self.assertEqual(fh.read(), content)
        self.assertGreater(mock.stale_served, 0, "the mock did serve wrong pieces, so the check was exercised")

    def test_pc_remote_is_reported_not_hung(self):
        mock = MockZVE10(service="pcremote", clip_size=100_000)
        self.addCleanup(mock.close)
        with tempfile.TemporaryDirectory() as out:
            run = self.check(mock, out)
        self.assertEqual(run.returncode, 1)
        self.assertIn("did not show its card", run.stdout)


if __name__ == "__main__":
    unittest.main()
