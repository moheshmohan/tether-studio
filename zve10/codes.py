"""PTP and Sony vendor codes, with names for the protocol log."""

OK = 0x2001
STORE_NOT_AVAILABLE = 0x2013
DEVICE_BUSY = 0x2019
SESSION_ALREADY_OPEN = 0x201E

GET_DEVICE_INFO = 0x1001
OPEN_SESSION = 0x1002
CLOSE_SESSION = 0x1003
GET_STORAGE_IDS = 0x1004
GET_OBJECT_HANDLES = 0x1007
GET_OBJECT_INFO = 0x1008
GET_OBJECT = 0x1009
GET_PARTIAL_OBJECT = 0x101B
SDIO_CONNECT = 0x9201
SDIO_GET_EXT_DEVICE_INFO = 0x9202
SDIO_CONTROL_DEVICE = 0x9207
SDIO_GET_ALL_PROPS = 0x9209
SDIO_OPEN_SESSION = 0x9210
SDIO_GET_PARTIAL_LARGE_OBJECT_OLD = 0x9211
SDIO_SET_CONTENTS_TRANSFER_MODE = 0x9212
SDIO_GET_PARTIAL_LARGE_OBJECT = 0x9219

CONTROL_MOVIE_REC = 0xD2C8      # data: uint16, 2 = start recording, 1 = stop (seen on a ZV-E10, firmware 2.03)
PROP_RECORDING_STATE = 0xD21D   # 0 = not recording, 1 = recording, 2 = recording failed

STORAGE_CARD = 0x00010001       # the memory card
STORAGE_VIRTUAL = 0x00F10001    # images selected on the camera for sending

OPS = {
    0x1001: "GetDeviceInfo", 0x1002: "OpenSession", 0x1003: "CloseSession", 0x1004: "GetStorageIDs",
    0x1005: "GetStorageInfo", 0x1007: "GetObjectHandles", 0x1008: "GetObjectInfo", 0x1009: "GetObject",
    0x100A: "GetThumb", 0x101B: "GetPartialObject", 0x9201: "SDIO_Connect", 0x9202: "SDIO_GetExtDeviceInfo",
    0x9205: "SDIO_SetExtDevicePropValue", 0x9207: "SDIO_ControlDevice", 0x9209: "SDIO_GetAllExtDevicePropInfo",
    0x9210: "SDIO_OpenSession", 0x9211: "SDIO_GetPartialLargeObject(old)", 0x9212: "SDIO_SetContentsTransferMode",
    0x9213: "SDIO_GetDeviceLog", 0x9219: "SDIO_GetPartialLargeObject", 0x9805: "GetObjectPropList",
}
RCS = {
    0x2001: "OK", 0x2002: "GeneralError", 0x2003: "SessionNotOpen", 0x2004: "InvalidTransactionID",
    0x2005: "OperationNotSupported", 0x2006: "ParameterNotSupported", 0x2008: "InvalidStorageID",
    0x2009: "InvalidObjectHandle", 0x200F: "AccessDenied", 0x2013: "StoreNotAvailable", 0x2019: "DeviceBusy",
    0x201A: "InvalidParentObject", 0x201D: "InvalidParameter", 0x201E: "SessionAlreadyOpen",
    0xA101: "Sony_AuthenticationFailed", 0xA105: "Sony_TemporaryStorageFull", 0xA106: "Sony_CameraStatusError",
}
EVENTS = {
    0x4002: "ObjectAdded", 0x4004: "StoreAdded", 0x4005: "StoreRemoved", 0x4006: "DevicePropChanged",
    0xC201: "Sony_ObjectAdded", 0xC202: "Sony_ObjectRemoved", 0xC203: "Sony_DevicePropChanged",
    0xC206: "Sony_Captured", 0xC20D: "Sony_ContentsTransfer", 0xC222: "Sony_OperationResult",
    0xC224: "Sony_MovieRecOperationsResult",
}


def op_name(code):
    return f"{OPS.get(code, 'Op')} (0x{code:04X})"


def rc_name(code):
    return f"{RCS.get(code, 'Response')} (0x{code:04X})"


def event_name(code):
    return f"{EVENTS.get(code, 'Event')} (0x{code:04X})"
