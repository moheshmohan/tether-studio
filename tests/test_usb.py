"""Framing tests for the USB link, with fake endpoints in place of a camera.

Run from the project folder:  python -m unittest -v tests.test_usb
"""
import struct
import unittest

import usb.core

from zve10 import codes as c
from zve10.ptpip import LinkError, Trace
from zve10.ptpusb import COMMAND, DATA, HEADER, RESPONSE, UsbLink


def container(ctype, code, tid, payload=b""):
    return HEADER.pack(HEADER.size + len(payload), ctype, code, tid) + payload


class FakeOut:
    wMaxPacketSize = 512

    def __init__(self):
        self.writes = []

    def write(self, data, timeout):
        self.writes.append(bytes(data))


class FakeIn:
    def __init__(self, reads):
        self.reads = list(reads)

    def read(self, size, timeout):
        if not self.reads:
            raise usb.core.USBError("Operation timed out", errno=60)
        return self.reads.pop(0)


def link_with(reads):
    link = UsbLink(Trace())
    link._dev, link._out, link._in = object(), FakeOut(), FakeIn(reads)
    return link


class UsbLinkTests(unittest.TestCase):
    def test_command_without_data(self):
        link = link_with([container(RESPONSE, c.OK, 0, struct.pack("<II", 7, 9))])
        reply = link.transact(c.OPEN_SESSION, (1,))
        self.assertTrue(reply.ok)
        self.assertEqual(reply.params, [7, 9])
        self.assertEqual(link._out.writes, [container(COMMAND, c.OPEN_SESSION, 0, struct.pack("<I", 1))])

    def test_data_in_split_across_reads_with_empty_packets(self):
        payload = bytes(range(256)) * 9                                  # 2304 bytes; the container spans reads
        whole = container(DATA, c.GET_OBJECT, 0, payload)
        reads = [whole[:5], whole[5:1024], whole[1024:], b"", container(RESPONSE, c.OK, 0)]
        reply = link_with(reads).transact(c.GET_OBJECT, (0x1234,))
        self.assertTrue(reply.ok)
        self.assertEqual(reply.data, payload)

    def test_data_and_response_arriving_in_one_read(self):
        payload = b"\x05" * 500                                          # 512-byte container, no empty packet after
        reads = [container(DATA, c.GET_STORAGE_IDS, 0, payload) + container(RESPONSE, c.STORE_NOT_AVAILABLE, 0)]
        reply = link_with(reads).transact(c.GET_STORAGE_IDS)
        self.assertEqual(reply.code, c.STORE_NOT_AVAILABLE)
        self.assertEqual(reply.data, payload)

    def test_data_out_is_sent_as_its_own_container(self):
        link = link_with([container(RESPONSE, c.OK, 0)])
        link.transact(c.SDIO_CONTROL_DEVICE, (c.CONTROL_MOVIE_REC,), data_out=b"\x02\x00")
        self.assertEqual(link._out.writes, [
            container(COMMAND, c.SDIO_CONTROL_DEVICE, 0, struct.pack("<I", c.CONTROL_MOVIE_REC)),
            container(DATA, c.SDIO_CONTROL_DEVICE, 0, b"\x02\x00")])

    def test_exact_multiple_of_the_packet_size_gets_an_empty_packet(self):
        link = link_with([container(RESPONSE, c.OK, 0)])
        link.transact(c.SDIO_CONTROL_DEVICE, (1,), data_out=b"\x00" * 500)   # 512-byte data container
        self.assertEqual([len(w) for w in link._out.writes], [16, 512, 0])

    def test_transaction_ids_count_up_and_restart_after_an_override(self):
        link = link_with([container(RESPONSE, c.OK, n) for n in (0, 1, 0, 1)])
        for tid in (None, None, 0, None):
            link.transact(c.GET_DEVICE_INFO, tid=tid)
        sent = [HEADER.unpack_from(w)[3] for w in link._out.writes]
        self.assertEqual(sent, [0, 1, 0, 1])

    def test_silence_from_the_camera_is_a_link_error(self):
        with self.assertRaises(LinkError):
            link_with([]).transact(c.GET_DEVICE_INFO)


if __name__ == "__main__":
    unittest.main()
