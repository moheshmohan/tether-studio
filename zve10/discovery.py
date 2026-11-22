"""Find the camera on whatever network this computer is on, and tell which of its Wi-Fi services is running."""
import re
import select
import socket
import subprocess
import time
import urllib.request
from dataclasses import dataclass
from urllib.parse import urljoin, urlparse

from .ptpip import PORT

SEARCH_TARGET = "urn:schemas-sony-com:service:DigitalImaging:1"
DIRECT_HOST = "192.168.122.1"      # the camera's address on its own Wi-Fi Direct network
DESCRIPTION_PORT = 64321


@dataclass
class Found:
    host: str
    model: str = ""
    service: str = None     # "smartphone" (transfer possible), "pcremote" (remote control only) or None
    description: str = ""   # the capability XML, kept for the log


def _local_ipv4():
    try:
        out = subprocess.run(["ifconfig"], capture_output=True, text=True, timeout=3).stdout
    except (OSError, subprocess.SubprocessError):
        return []
    return [ip for ip in dict.fromkeys(re.findall(r"\binet (\d+\.\d+\.\d+\.\d+)", out)) if not ip.startswith("127.")]


def _fetch(url, timeout=3.0):
    try:
        with urllib.request.urlopen(url, timeout=timeout) as response:
            return response.read(200_000).decode("utf-8", "replace")
    except (OSError, ValueError):
        return None


def _flag(xml, key):
    """Value of the first element or attribute whose name contains `key`, e.g. MediaServer -> ENABLE."""
    match = (re.search(rf"<[^<>/]*{key}[^<>]*>\s*([\w.]+)\s*<", xml, re.I)
             or re.search(rf"{key}\w*\s*=\s*\"([^\"]+)\"", xml, re.I))
    return match.group(1) if match else None


def describe(location):
    """Read the camera's description and capability documents from its dd.xml URL."""
    dd = _fetch(location)
    if dd is None:
        return None
    found = Found(host=urlparse(location).hostname)
    name = re.search(r"<friendlyName>([^<]*)</friendlyName>", dd)
    found.model = name.group(1) if name else ""
    scpd = re.search(r"<SCPDURL>([^<]+)</SCPDURL>", dd)
    did = _fetch(urljoin(location, scpd.group(1))) if scpd else None
    found.description = f"{dd}\n{did or ''}"
    media = _flag(found.description, "MediaServer")
    if media is not None:
        found.service = "smartphone" if media.upper() in ("ENABLE", "ENABLED", "TRUE", "1", "ON") else "pcremote"
    return found


def describe_host(host):
    return describe(f"http://{host}:{DESCRIPTION_PORT}/dd.xml")


def ssdp_search(wait=3.0):
    """Ask every local network for Sony cameras. Returns (dd.xml URLs, error text or None)."""
    message = (f"M-SEARCH * HTTP/1.1\r\nHOST: 239.255.255.250:1900\r\nMAN: \"ssdp:discover\"\r\nMX: 2\r\n"
               f"ST: {SEARCH_TARGET}\r\n\r\n").encode()
    socks, error = [], None
    for ip in _local_ipv4() or [""]:
        sock = socket.socket(socket.AF_INET, socket.SOCK_DGRAM, socket.IPPROTO_UDP)
        try:
            sock.bind((ip, 0))
            if ip:
                sock.setsockopt(socket.IPPROTO_IP, socket.IP_MULTICAST_IF, socket.inet_aton(ip))
            sock.setsockopt(socket.IPPROTO_IP, socket.IP_MULTICAST_TTL, 2)
            sock.sendto(message, ("239.255.255.250", 1900))
            socks.append(sock)
        except OSError as err:
            error = f"could not search from {ip or 'default interface'}: {err}"
            sock.close()
    locations = []
    deadline = time.monotonic() + wait
    resend = time.monotonic() + 1.0
    while socks and time.monotonic() < deadline:
        ready, _, _ = select.select(socks, [], [], 0.25)
        for sock in ready:
            try:
                text = sock.recv(4096).decode("utf-8", "replace")
            except OSError:
                continue
            match = re.search(r"^LOCATION:\s*(\S+)", text, re.I | re.M)
            if match and match.group(1) not in locations:
                locations.append(match.group(1))
        if time.monotonic() >= resend:
            resend = deadline + 1
            for sock in socks:
                try:
                    sock.sendto(message, ("239.255.255.250", 1900))
                except OSError:
                    pass
    for sock in socks:
        sock.close()
    return locations, error


def _port_open(host, port=PORT, timeout=0.7):
    try:
        socket.create_connection((host, port), timeout=timeout).close()
        return True
    except OSError:
        return False


def find_cameras(wait=3.0, trace=None):
    """Cameras reachable right now: by SSDP on the current networks, else at the Wi-Fi Direct address."""
    locations, error = ssdp_search(wait)
    if trace:
        trace(f"SSDP: {len(locations)} answer(s) {locations}" + (f"; {error}" if error else ""))
    found = [f for f in (describe(location) for location in locations) if f]
    if not found and _port_open(DIRECT_HOST):
        found.append(describe_host(DIRECT_HOST) or Found(host=DIRECT_HOST))
    if trace:
        for camera in found:
            trace(f"camera {camera.model or '?'} at {camera.host}, service {camera.service}\n{camera.description}")
    return found, error
