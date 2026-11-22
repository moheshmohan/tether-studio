"""Parsers (and the matching packers, used by the mock camera) for PTP datasets."""
import struct
from dataclasses import dataclass, field

_INT = {1: "b", 2: "B", 3: "h", 4: "H", 5: "i", 6: "I", 7: "q", 8: "Q"}
PARSE_ERRORS = (struct.error, ValueError, IndexError)


class Reader:
    def __init__(self, data, offset=0):
        self.data, self.offset = data, offset

    def remaining(self):
        return len(self.data) - self.offset

    def _take(self, fmt):
        (value,) = struct.unpack_from("<" + fmt, self.data, self.offset)
        self.offset += struct.calcsize("<" + fmt)
        return value

    def u8(self):
        return self._take("B")

    def u16(self):
        return self._take("H")

    def u32(self):
        return self._take("I")

    def peek_u16(self):
        return struct.unpack_from("<H", self.data, self.offset)[0]

    def string(self):
        chars = self.u8()
        raw = self.data[self.offset:self.offset + 2 * chars]
        if len(raw) < 2 * chars:
            raise ValueError("truncated string")
        self.offset += 2 * chars
        return raw.decode("utf-16-le", "replace").split("\0")[0]

    def array(self, fmt):
        return [self._take(fmt) for _ in range(self.u32())]

    def value(self, dtype):
        if dtype in _INT:
            return self._take(_INT[dtype])
        if dtype in (9, 10):
            raw = self.data[self.offset:self.offset + 16]
            if len(raw) < 16:
                raise ValueError("truncated int128")
            self.offset += 16
            return int.from_bytes(raw, "little", signed=dtype == 9)
        if dtype == 0xFFFF:
            return self.string()
        if dtype & 0x4000 and (dtype & 0xBFFF) in _INT:
            return [self.value(dtype & 0xBFFF) for _ in range(self.u32())]
        raise ValueError(f"unknown datatype 0x{dtype:04X}")


def pack_string(text):
    if not text:
        return b"\0"
    raw = (text + "\0").encode("utf-16-le")
    return bytes([len(raw) // 2]) + raw


def pack_array(fmt, values):
    return struct.pack("<I", len(values)) + b"".join(struct.pack("<" + fmt, v) for v in values)


def u32_array(data):
    return Reader(data).array("I") if len(data) >= 4 else []


@dataclass
class DeviceInfo:
    vendor_desc: str = ""
    ops: list = field(default_factory=list)
    events: list = field(default_factory=list)
    manufacturer: str = ""
    model: str = ""
    version: str = ""
    serial: str = ""


def parse_device_info(data):
    r = Reader(data, 8)                 # StandardVersion, VendorExtensionID, VendorExtensionVersion
    info = DeviceInfo(vendor_desc=r.string())
    r.u16()                             # FunctionalMode
    info.ops, info.events = r.array("H"), r.array("H")
    r.array("H"), r.array("H"), r.array("H")   # device props, capture formats, image formats
    info.manufacturer, info.model, info.version, info.serial = r.string(), r.string(), r.string(), r.string()
    return info


def pack_device_info(info):
    return (struct.pack("<HIH", 100, 0x11, 300) + pack_string(info.vendor_desc) + struct.pack("<H", 0)
            + pack_array("H", info.ops) + pack_array("H", info.events) + pack_array("H", []) + pack_array("H", [])
            + pack_array("H", []) + pack_string(info.manufacturer) + pack_string(info.model)
            + pack_string(info.version) + pack_string(info.serial))


def parse_ext_device_info(data):
    """SDIO_GetExtDeviceInfo: protocol version, property codes, control codes."""
    r = Reader(data)
    version = r.u16()
    props = r.array("H")
    controls = r.array("H") if r.remaining() >= 4 else []
    return version, props, controls


@dataclass
class Prop:
    code: int
    dtype: int
    enabled: int
    value: object


def parse_all_props(data):
    """SDIO_GetAllExtDevicePropInfo -> {code: Prop}. Stops quietly at the first entry it cannot decode."""
    props = {}
    r = Reader(data, 8)                 # 64-bit property count
    try:
        while r.remaining() >= 6:
            code, dtype = r.u16(), r.u16()
            if code >> 12 not in (0x5, 0xD):
                break                   # not a property code: the layout differs from what we expect
            r.u8()                      # get/set
            enabled = r.u8()
            r.value(dtype)              # factory default
            current = r.value(dtype)
            form = r.u8() if r.remaining() else 0
            if form == 1:
                r.value(dtype), r.value(dtype), r.value(dtype)
            elif form == 2:
                for _ in range(r.u16()):
                    r.value(dtype)
                # Newer firmware appends a second list (currently selectable values). A count is always small,
                # whereas the next property code is 0x5xxx or 0xDxxx.
                if r.remaining() >= 2 and r.peek_u16() < 0x200:
                    for _ in range(r.u16()):
                        r.value(dtype)
            props[code] = Prop(code, dtype, enabled, current)
    except PARSE_ERRORS:
        pass
    return props


def pack_prop(code, dtype, value, enum=None, second_list=None, value_range=None):
    fmt = "<" + _INT[dtype]
    out = struct.pack("<HHBB", code, dtype, 1, 1) + struct.pack(fmt, value) * 2
    if value_range:
        return out + b"\x01" + b"".join(struct.pack(fmt, v) for v in value_range)
    if enum is None:
        return out + b"\x00"
    out += b"\x02" + struct.pack("<H", len(enum)) + b"".join(struct.pack(fmt, v) for v in enum)
    if second_list is not None:
        out += struct.pack("<H", len(second_list)) + b"".join(struct.pack(fmt, v) for v in second_list)
    return out


@dataclass
class ObjectInfo:
    storage: int
    fmt: int
    size: int
    parent: int
    name: str
    date: str


FORMAT_FOLDER = 0x3001


def parse_object_info(data):
    r = Reader(data)
    storage, fmt = r.u32(), r.u16()
    r.u16()                             # protection
    size = r.u32()
    r.offset += 26                      # thumb format/size/dimensions, image dimensions, bit depth
    parent = r.u32()
    r.offset += 10                      # association type, association desc, sequence number
    name = r.string()
    date = r.string() if r.remaining() else ""
    return ObjectInfo(storage, fmt, size, parent, name, date)


def pack_object_info(info):
    return (struct.pack("<IHHI", info.storage, info.fmt, 0, min(info.size, 0xFFFFFFFF)) + bytes(26)
            + struct.pack("<I", info.parent) + bytes(10) + pack_string(info.name) + pack_string(info.date)
            + pack_string(info.date) + pack_string(""))
