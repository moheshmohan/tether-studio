"""Copy clips from the camera's memory card when it is mounted over USB (Mass Storage mode, macOS).

A connected USB data cable puts the ZV-E10 into USB mode: the card mounts here and the camera leaves Wi-Fi and
cannot record. Ejecting does not release it; the cable (or a switchable hub port) has to be disconnected.
"""
import glob
import os
import re
import shutil
import subprocess
import time

VOLUMES = "/Volumes"
CLIP_DIR = os.path.join("PRIVATE", "M4ROOT", "CLIP")
EXTRA_VOLUMES = ("PMHOME",)     # the camera's second, read-only disk


def card_volumes():
    return [v for v in sorted(glob.glob(os.path.join(VOLUMES, "*"))) if os.path.isdir(os.path.join(v, CLIP_DIR))]


def wait_for_card(timeout):
    """The mounted card's path, or None if it does not appear in time."""
    deadline = time.monotonic() + timeout
    while time.monotonic() < deadline:
        volumes = card_volumes()
        if volumes:
            return volumes[0]
        time.sleep(0.5)
    return None


def clip_number(name):
    digits = re.sub(r"\D", "", os.path.splitext(name)[0])
    return int(digits) if digits else -1


def newest_clip(volume):
    """Path of the highest-numbered clip on the card, or None."""
    clips = [f for f in os.listdir(os.path.join(volume, CLIP_DIR))
             if f.upper().endswith(".MP4") and not f.startswith(".")]
    return os.path.join(volume, CLIP_DIR, max(clips, key=clip_number)) if clips else None


def copy(source, out_dir, progress=None):
    os.makedirs(out_dir, exist_ok=True)
    dest = os.path.join(out_dir, os.path.basename(source))
    total = os.path.getsize(source)
    done = 0
    with open(source, "rb") as src, open(dest + ".part", "wb") as out:
        while True:
            block = src.read(8 * 1024 * 1024)
            if not block:
                break
            out.write(block)
            done += len(block)
            if progress:
                progress(done, total)
    if done != total:
        raise OSError(f"{os.path.basename(source)}: copied {done} of {total} bytes")
    shutil.copystat(source, dest + ".part")
    os.replace(dest + ".part", dest)
    return dest


def eject(volume):
    """Unmount the card (and the camera's helper disk) so the cable can be disconnected safely."""
    targets = [volume] + [os.path.join(VOLUMES, name) for name in EXTRA_VOLUMES]
    for target in targets:
        if VOLUMES == "/Volumes" and os.path.isdir(target):
            subprocess.run(["diskutil", "eject", target], capture_output=True, timeout=60)
