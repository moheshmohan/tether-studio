# ZV-E10 remote-control protocol notes

This is a protocol reference for controlling a Sony ZV-E10 from a computer over its
**Ctrl w/ Smartphone** Wi-Fi service (PTP/IP), over **PC Remote** (Wi-Fi or USB), and for reading its memory card
over the phone service. It is written for the Tether Studio project (a macOS app, MIT licence) and records what
was seen on the camera and on the wire while building it.

> **Disclaimer.** Tether Studio is an independent project. It is not affiliated with, endorsed by or supported
> by Sony. "Sony", "ZV-E10" and the menu names quoted below are used only to identify the camera and its
> settings. Everything here was observed on **one ZV-E10 with firmware 2.03** (a 50 Hz/PAL unit) in November 2026.
> Other firmware versions and other models may behave differently. Sending vendor commands to a camera is at
> your own risk.

Contents:

1. [Camera modes and what each allows](#1-camera-modes-and-what-each-allows)
2. [Discovery and ports](#2-discovery-and-ports)
3. [PTP/IP connection and sessions](#3-ptpip-connection-and-sessions)
4. [Operations the camera lists](#4-operations-the-camera-lists)
5. [Controls (button-style commands)](#5-controls-button-style-commands)
6. [Properties](#6-properties)
7. [Live view](#7-live-view)
8. [Photos](#8-photos)
9. [Reading the card over phone control](#9-reading-the-card-over-phone-control)
10. [Timing quirks](#10-timing-quirks)
11. [libgphoto2 notes](#11-libgphoto2-notes)
12. [The ESP32-C3 bridge and its USB framing](#12-the-esp32-c3-bridge-and-its-usb-framing)
13. [Measured speeds](#13-measured-speeds)
14. [What this project deliberately does not do](#14-what-this-project-deliberately-does-not-do)

All multi-byte numbers on the wire are little-endian unless stated otherwise. "OK" is PTP response 0x2001.

---

## 1. Camera modes and what each allows

| Camera setting | Link | Remote control | Live view | Memory card | Notes |
|---|---|---|---|---|---|
| PC Remote **On**, Cnct Method **USB** | USB cable, PTP (USB id 054c:0d97) | Yes | Yes, fast | **No**: every storage request answers StoreNotAvailable (0x2013) | Camera leaves Wi-Fi while in this mode |
| PC Remote **On**, Cnct Method **Wi-Fi Access Point** | Camera joins your router | Yes, after pairing once | Yes | **No**, same refusal as USB | The camera's description says media server disabled |
| PC Remote **Off**, Ctrl w/ Smartphone **On** | Camera's own network only (`DIRECT-xxxx:ZV-E10`) | Yes | Yes | **Yes**, by switching session type (section 9) | No pairing step. Read-only: no delete or format operation is offered |
| USB cable in Mass Storage / MTP | USB | No | No | Yes, as a disk or MTP device | The camera leaves Wi-Fi and does not rejoin until it is switched off and on |
| Wi-Fi on, both remote functions off | Router | No | No | No | No TCP port open at all (full port scan); the camera answers ping only |

So **only Ctrl w/ Smartphone gives recording and the card on one link**, and only on the camera's own network.
With PC Remote off and Ctrl w/ Smartphone on, the camera does not join the router at all (checked repeatedly,
before and after a power cycle).

Camera-side setup for phone control: PC Remote **Off**; Ctrl w/ Smartphone **On**; then open Ctrl w/ Smartphone
→ **Connection**, which shows the network name and password (the Delete button switches from the QR code to the
text). With **Always Connected Off**, the camera's network stays down after each power-on until Connection is
opened again (watched for 100 s). With **Always Connected On**, the network comes back by itself after a power
cycle with the same name and password, and a client reconnected about 20 s after power-off.

Phone-control network facts seen: 2.4 GHz, channel 1, WPA password shown on the camera, camera at
**192.168.122.1**, which is also the gateway the camera's DHCP server hands out.

## 2. Discovery and ports

| Port | Protocol | Use |
|---|---|---|
| UDP 1900 (multicast 239.255.255.250) | SSDP | Search target `urn:schemas-sony-com:service:DigitalImaging:1`; the answer's `LOCATION` points at the description |
| TCP 64321 | HTTP | `/dd.xml` (UPnP device description) and `/DigitalImagingDesc.xml` (capabilities) |
| TCP 15740 | PTP/IP | Both the command and the event connection |
| TCP 60152 | HTTP | Advertised live-view stream (property 0xD278, see section 7); **not tried** |

On the router (PC Remote over Wi-Fi) the camera answers SSDP. Tether Studio also falls back to trying port
15740 on every address of the Mac's own /24, because a freshly built macOS app may not receive the multicast
answers until the firewall allows it. On the camera's own network the camera is simply the gateway.

The capability document tells the two Wi-Fi services apart:

| Element | PC Remote (Wi-Fi) | Ctrl w/ Smartphone |
|---|---|---|
| `X_ServerType` | (not recorded) | `Control with Smartphone` |
| `X_PTP_PairingNecessity` | `Necessary` | `Unnecessary` |
| `X_PTP_MediaServerSupport` | `Disable` | `Enable` |
| `X_PTP_RemoteControlSupport` | `Enable` | `Enable` |

`X_PTP_MediaServerSupport` matches what the camera then does: card access is refused where it says `Disable`.

## 3. PTP/IP connection and sessions

### 3.1 Packets

Every PTP/IP packet is `length (4) | type (4) | payload`, where `length` includes the 8-byte header.

| Type | Name | Payload (as used here) |
|---|---|---|
| 1 | Init Command Request | client GUID (16), client name (UTF-16LE, zero-terminated), protocol version 0x00010000 |
| 2 | Init Command Ack | connection number (4), camera GUID (16), camera name (UTF-16LE), version |
| 3 | Init Event Request | connection number from the ack (4) |
| 4 | Init Event Ack | — |
| 5 | Init Fail | reason |
| 6 | Operation Request | data-phase flag (4: 1 = none or camera-to-host, 2 = host-to-camera), opcode (2), transaction id (4), up to 5 parameters (4 each) |
| 7 | Operation Response | response code (2), transaction id (4), parameters |
| 8 | Event | event code, transaction id, parameters |
| 9 | Start Data | transaction id (4), total length (8) |
| 10 | Data | transaction id (4), bytes |
| 12 | End Data | transaction id (4), last bytes |
| 13 / 14 | Ping / Pong | — |

Connection order: open TCP to 15740, send Init Command Request, wait for the ack; open a second TCP connection
to 15740 and send Init Event Request with the connection number; wait for the event ack. Keep reading the event
connection so the camera never blocks on it, and answer any Ping with Pong.

A host-to-camera data phase, here a control value of `n` bytes, is three packets back to back:

```
Operation Request  len=22  type=6  flag=2  op=0x9207  tid  param1=<control code>
Start Data         len=20  type=9  tid  total=n (8 bytes)
End Data           len=12+n type=12 tid  <n value bytes>
```

### 3.2 Identity and pairing (PC Remote over Wi-Fi only)

The client's 16-byte GUID is its identity. In PC Remote mode the camera remembers paired GUIDs. An unknown
GUID is refused with Init Fail unless the camera is on its Pairing screen
(Network → PC Remote Function → Pairing). In that case **the camera holds the Init Command Ack back** while it
asks the user to confirm, showing the client name sent in the request. Once confirmed, the same GUID connects
without asking again. Allow at least 60 s for that first answer.

The phone service has **no pairing**: any GUID is accepted at once. Do not run the pairing flow against it. A
pairing-style request sent there got no answer for 57 s.

### 3.3 Sessions

Remote-control session (PC Remote on USB or Wi-Fi, and phone control):

1. `OpenSession` 0x1002 (plain PTP). The phone service also accepts `SDIO_OpenSession` 0x9210 with
   parameters (1, 0). A plain OpenSession is all libgphoto2 sends, and it works on both services.
2. Sony's connect sequence: `SDIO_Connect` 0x9201 (1, 0, 0), then (2, 0, 0), then `SDIO_GetExtDeviceInfo`
   0x9202 (300) (200 is the fallback if 300 is refused), then `SDIO_Connect` (3, 0, 0).
3. `GetDeviceInfo` 0x1001 again. The camera expects to be asked once the session is up.

Card (contents-transfer) session, phone control only: see section 9.

Session parameters seen:

| Request | PC Remote | Ctrl w/ Smartphone |
|---|---|---|
| `SDIO_OpenSession (1, 0)` remote control | OK | OK (opened in 1.7 s) |
| `SDIO_OpenSession (1, 1)` contents transfer | OK, but storage then refused | OK, card appears |
| `SDIO_OpenSession (1, 2)` | InvalidParameter (0x201D) | not needed |
| `SetContentsTransferMode 0x9212 (2, 1, 0)` | OK, but storage still refused (polled 8 s) | OK, card appears about 1 s later |

Response codes met in practice: 0x2001 OK, 0x2013 StoreNotAvailable, 0x2019 DeviceBusy, 0x201D
InvalidParameter, 0x201E SessionAlreadyOpen.

On macOS over USB, the system's PTP daemon opens a session as soon as the camera is plugged in, and that session
outlives the daemon: the next OpenSession answers 0x201E. Send `CloseSession` 0x1003 first.

## 4. Operations the camera lists

From `GetDeviceInfo`, identical in PC Remote (USB and Wi-Fi), the phone service's remote session and its card
session:

```
0x1001–0x100A  0x100D  0x101B
0x9201 0x9202 0x9205 0x9207 0x9209 0x920A–0x920F 0x9210 0x9211 0x9212 0x9214
0x9801 0x9802 0x9803 0x9805
```

**Not listed:** `DeleteObject` 0x100B and `FormatStore` 0x100F. There is therefore **no way to delete files over
Wi-Fi**. Files can be deleted only with the card mounted as a disk (or with the camera's own menu).

Operations this project uses:

| Op | Name (descriptive) | Parameters | Used for |
|---|---|---|---|
| 0x1001 | GetDeviceInfo | — | operation list |
| 0x1002 / 0x1003 | OpenSession / CloseSession | session id / — | sessions |
| 0x1004 | GetStorageIDs | — | is the card shown |
| 0x1007 | GetObjectHandles | storage, 0, parent (0 = all) | card listing |
| 0x1008 | GetObjectInfo | handle | name, size, date, parent |
| 0x1009 | GetObject | handle | live view and captured-photo pseudo-objects |
| 0x9201 | Sony connect step | phase (1, 2, 3), 0, 0 | session setup |
| 0x9202 | Sony extended device info | version (300 or 200) | lists properties and controls |
| 0x9205 | Sony set property | property code; data = value | settings |
| 0x9207 | Sony control | control code; data = value | buttons, zoom, touch (section 5) |
| 0x9209 | Sony read all properties | — | settings poll (used by libgphoto2) |
| 0x9210 | Sony open session | (1, 0) remote, (1, 1) contents transfer | sessions |
| 0x9211 | Sony read part of a large object | handle, offset low 32, offset high 32, length | file download |
| 0x9212 | Sony contents-transfer mode | (2, 1, 0) show the card, (2, 0, 0) give it back | card session |
| 0x9803 | GetObjectPropValue | handle, 0xDC04 | 64-bit size of files of 4 GB or more |

## 5. Controls (button-style commands)

Controls are sent with `0x9207`, parameter 1 = control code, and a host-to-camera data phase carrying the value.
For buttons, **2 = press (down)** and **1 = release (up)**. **The width of the value matters**: zoom sent as one
byte is answered OK and ignored, while the same value as 16 bits works. Use 16 bits unless stated otherwise.

Controls the camera lists in `SDIO_GetExtDeviceInfo (300)`:

```
D2C1 D2C2 D2C3 D2C7 D2C8 D2C9 D2CA D2CD D2CE D2CF D2D0 D2D1 D2D2 D2D5 D2D6
D2D7 D2D8 D2D9 D2DA D2DB D2DC D2DD D2DF D2E0 D2E1 D2E4 D2E5 D2E6 D2E8
```

| Code | Function (as observed) | Value | Status |
|---|---|---|---|
| 0xD2C1 | Shutter half press (focus) | 2 down, 1 up | Works (through libgphoto2's capture and autofocus actions) |
| 0xD2C2 | Shutter full press | 2 down, 1 up | Works (libgphoto2 capture: half, full, release both) |
| 0xD2C8 | Movie record | 2 = start, 1 = stop | Works. Confirm with 0xD21D (section 10) |
| 0xD2D1 | Manual-focus step | signed int16, ±1 (small) … ±7 (large), negative = nearer | Works in manual focus only (as libgphoto2's manual-focus action sends it) |
| 0xD2DD | **Zoom** | int16: +1 tele, −1 wide, **0 stop** | Works on Wi-Fi and USB. The lens keeps moving until 0 is sent |
| 0xD2E4 | **Touch point** (focus or track) | uint32 `x << 16 \| y`, x 0–639, y 0–479 over the whole picture | Works when 0xD284 = 1 |
| 0xD2E5 | End touch focus / tracking | 2 then 1 | Works. DeviceBusy if sent within about 1 s of the touch |
| 0xD2C3 | (exposure-lock style button) | 2 / 1 | Answered OK, no visible effect in Movie (Scene). Not used |
| 0xD2CA | Thought to start a card format (never tried) | — | **Never sent by this project** (section 14) |
| others | — | — | Listed by the camera, not tested here |

Notes:

- Zoom runs through the lens's optical range, then Clear Image Zoom up to 2.0× (depending on 0xD25F). Its
  position is in 0xD25D/0xD25C (section 6).
- What a touch does depends on 0xD283: 3 = touch focus, 4 = touch tracking. While a touch focus or tracking is
  active 0xD285 reads 1 and the focus area reads "Wide". The camera disables touch operation at 100p and in
  manual focus.
- Live view needs **no enable command**. The camera does not list a live-view enable control, and frames are
  served as soon as a session is open.

## 6. Properties

Settings are read through `0x9209` (all at once) and written with `0x9205`. After a write the camera reports
the new value **0.8–2.2 s later** (up to 3.8 s; colour temperature 3.7 s). Which properties are writable depends
on the shooting mode, and the camera says so in each property's description (for example in Movie (Scene) it sets
shutter, ISO, exposure compensation and white balance itself and reports them read-only). After a mode change,
allow about 2 s before reading the new choice lists.

### 6.1 Status properties

| Code | Meaning | Values |
|---|---|---|
| 0xD218 | Battery level | percent (libgphoto2's `batterylevel`) |
| 0xD21D | Movie recording state | 0 idle, 1 recording, 2 failed |
| 0xD24A | Recording time left on the card | seconds (0 in a photo mode) |
| 0xD249 | Photos left on the card | count (0 in a movie mode) |
| 0xD251 | Overheat status | 0 normal |
| 0xD215 | Photos waiting for collection | 0x8001, 0x8002, … (section 8) |
| 0xD25B | Zoom enable status | — |
| 0xD25D | Zoom bar | top byte = number of ranges (2), next byte = range in use (0 optical, 1 Clear Image Zoom), low 16 bits = 0–100 within the range |
| 0xD25C | Zoom scale | ×1000, 1000–2000 in the Clear Image Zoom range |
| 0xD214 | Zoom position | reads 0xFFFFFFFF: not usable. Use 0xD25D |
| 0xD284 | Touch operation allowed | 1 = yes |
| 0xD285 | Touch focus or tracking active (can be cancelled) | 1 = yes |
| 0xD278 | Live-view URL | `http://192.168.122.1:60152/liveviewstream?…` (not tried) |

### 6.2 Settings this project writes

The usual exposure, focus and colour settings are read and written through libgphoto2's widgets (`expprogram`,
`shutterspeed`, `f-number`, `iso`, `exposurecompensation`, `exposuremetermode`, `whitebalance`,
`colortemperature`, `focusmode`, `focusarea`, `dro`). Every one of them was written and read back over the phone
service. The exposure program offers 25 choices (Movie P/A/S/M/Scene among them). Colour temperature goes from
2500 to 9900 K in steps of 100, with white balance set to its colour-temperature choice. `focalposition` (focus
distance) is read-only in every mode tried; move it with the manual-focus step.

Vendor properties written with 0x9205 by code:

| Code | Meaning | Values seen |
|---|---|---|
| 0xD241 | Movie file format | 8 = XAVC S 4K, 9 = XAVC S HD |
| 0xD242 | Movie recording setting | HD: 4 = 50p 50M, 25 = 50p 25M, 5 = 25p 50M, 27 = 25p 16M, 29 and 31 = 100p. 4K: 33 = 25p 100M, 36 = 25p 60M (50 Hz camera) |
| 0xD26A | Live-view quality | 1 = 640×360, 2 = 1024×576 (no other values offered) |
| 0xD283 | Touch function | 3 = touch focus, 4 = touch tracking |
| 0xD23F | Picture profile | 0 off, 1–10 |
| 0xD240 | Creative style | 1 Standard, 2 Vivid, 3 Portrait, 4 Landscape, 5 Sunset, 6 B/W, 13 Sepia |
| 0xD21B | Picture effect | 0x8000 = off |
| 0xD201 | D-Range Optimizer | as listed by the camera |
| 0xD25F | Zoom setting | 1 optical only, 3 Clear Image Zoom, 4 digital |
| 0xD210 | White-balance shift green–magenta | 192 = none, 0.25 step per unit, below 192 = magenta |
| 0xD21C | White-balance shift amber–blue | 192 = none, below 192 = blue; range 164–220 in steps of 2 in Movie (P) |
| 0xD223 | Date/time | string, write-only (reads back empty), see below |

All of 0xD23F, 0xD240, 0xD21B, 0xD201, 0xD25F, 0xD210 and 0xD21C were set in Movie (P) and reported back in
1.8–3.8 s. Movie (Scene) locks all of them except 0xD25F. In Movie (Scene), colour temperature (0xD20F) keeps
showing the last value set even while white balance is automatic and locked. The time-left property 0xD24A follows
the movie setting at once (for example 33,837 s at HD 50p 25M against 8,808 s at 4K 100M on the same card).

**Clock (0xD223).** Write a PTP string `yyyyMMddTHHmmss.s±hhmm` in local time with the offset from UTC, for example
`20261121T142104.0+0400`. A string whose length byte counts the closing zero (the normal PTP form) is accepted.
Checked: with the clock sent 600 s behind, the next clip's metadata carried a creation time 600 s behind and the
right zone; after setting it correctly, the next clip matched the record command to the second. Live view and
control carry on through the write. The camera's clock cannot be read back.

## 7. Live view

- Each frame: `GetObject` 0x1009 of the pseudo-handle **0xFFFFC002**. The data phase starts with a small
  header: the first 32-bit word is the offset at which the JPEG begins. Searching for the JPEG start marker
  `FF D8` also works.
- Size is chosen with 0xD26A: 1 → 640×360 (about 36 KB a frame), 2 → 1024×576 (about 135–153 KB).
- No pause between requests is needed. Ask for the next frame as soon as the last one has arrived. The first frame
  after a reconnect or a card session sometimes fails; asking again at once works.
- **While zooming**, the camera takes 0.2–3 s to deliver a frame. Tether Studio stops requesting frames
  until the zoom button is released.
- In 4K movie mode live view is slower than in HD mode (about 9 against 15 frames/s at 640×360 through the bridge).

Rates are in section 13.

## 8. Photos

libgphoto2's capture (half press, full press, release, see section 5) takes a photo over phone control in a photo
mode (P/A/S/M/auto). The full-size photo stays on the card. The camera holds a copy for the client to collect:
0xD215 counts them (0x8001, 0x8002 …), and the copy is fetched as pseudo-handle **0xFFFFC001**. Over phone
control the collected copy was always a **1920×1080 JPEG (about 750 KB)**, whatever the image-size setting. About
3–3.5 s from the press to the file on the Mac. Copies left uncollected by an earlier run are still waiting in the
next session and should be fetched first. Reopening the session cleared two left waiting.

A timelapse of 1,500 frames at 8 s intervals ran for 3 h 20 min (4.5–4.8 s per photo with a 2 s exposure). The
camera took all 1,500, and 3 were not fetched ("unknown error" from libgphoto2, next frame on time). See section 10
for the focus-mode refusal right after a photo.

## 9. Reading the card over phone control

### 9.1 Switching between control and card

The remote-control session and the card session cannot be open together. To reach the card:

1. Close the remote-control session (`CloseSession`) and both TCP connections. Wait about 0.4 s.
2. New PTP/IP connection (section 3.1), `GetDeviceInfo`.
3. `SDIO_OpenSession (1, 1)`.
4. `SDIO_Connect (1,0,0)`, `(2,0,0)`, `SDIO_GetExtDeviceInfo (300)`, `SDIO_Connect (3,0,0)`, `GetDeviceInfo`.
5. `SetContentsTransferMode 0x9212 (2, 1, 0)`.
6. Poll `GetStorageIDs` every 0.5 s. The first answer still holds no card; about a second later it returns
   **0x00010001**.
7. **`GetObjectHandles (0x00010001, 0, 0)`, always, before anything else** (see 9.3).

To give the card back: `SetContentsTransferMode (2, 0, 0)`, `CloseSession`, close the connections, then reopen
remote control as in section 3.3. Both switches are by command only. Nothing has to be touched on the camera.
Times: card session open in 0.7 s through the fast bridge (2–3 s with the slow one), back to remote control in
about 3 s.

A card session that the client drops without closing (process killed mid-copy) does not block the camera. A new
remote session opened a second later, and the next card session could continue the same file.

### 9.2 Objects and handles

- Handles have the form `0x40000000 | index << 4 | type`: type 0 = date folder (parent 0), 1 = still, 9 = movie.
  Files have their date folder as parent. Folders have format 0x3001.
- In transfer mode the card is presented as date folders (`2026-11-18/C0188.MP4`), not the camera's own
  `PRIVATE/M4ROOT/CLIP` layout seen when the card is mounted as a disk.
- Handles stayed the same across sessions, across new recordings (a new clip gets the next index) and across a
  power cycle the same evening. A client can therefore cache descriptions and only ask about new handles. It should
  still describe a file again just before copying it and check that the name and size match.
- A clip listed about 3 s after recording stopped already had its final size.
- `GetObjectInfo` takes about 250 ms each through the slow bridge (58 entries in 14 s). Through the fast bridge the
  same 58 entries take 3.3 s.

### 9.3 Quirk: describe before list returns an empty description

In a fresh card session, `GetObjectInfo` sent **before** any `GetObjectHandles` answers **OK** with 88 bytes
that parse to an empty name and size 0. After `GetObjectHandles (storage, 0, 0)` the same handle is described
properly. Always list first in every session, and refuse descriptions without a usable name. An early version of
the app built a destination path from such an empty name, and the result was a folder instead of a file.

### 9.4 Reading file contents

`0x9211 (handle, offset low, offset high, length)` returns that piece of the file in the data phase.

- Reads of 3 MB, 16 MB and 48 MB in one request are all accepted at the same rate. Tether Studio uses 3 MB
  (3,145,728 bytes).
- A read that runs past the end returns the bytes that exist.
- **Files of 4 GB or more**: the ObjectInfo size field is 0xFFFFFFFF. `GetObjectPropValue 0x9803 (handle, 0xDC04)`
  answers with the size as 8 bytes. Reads with the high offset word set work on both sides of the 4 GB line.
  Checked on a 4,798,399,611-byte 4K clip, including pieces at 4 GB − 3 MB, 4 GB and the end.

**Wrong-position fault and the read-spacing rule.** Within one file, a read that **starts** soon after the previous
read started is sometimes served from the *previous read's offset*, with the new length, answer OK and nothing to
tell it apart. Measured with 32 KB reads at scattered offsets against a verified copy:

| Gap between read starts (same file) | Wrong pieces |
|---|---|
| 0.4 s | 7 of 30 |
| 0.8 s, 1.2 s, 2.0 s | 0 of 90 |
| 0–100 ms after a 32 KB read | about half |
| any gap, after a read that itself took ≥ 1 s | 0 of 144 |
| alternating between two files, 0.4 s | 0 of 120 |

Rule used by Tether Studio: **at least 1.0 s between the starts of two reads**. Second safeguard: if a piece begins
with the same bytes as the piece before it, read it again after a pause (at most twice). At about 1 MB/s a 3 MB
piece takes 3 s anyway, so the rule costs nothing through the bridge. On a faster link it would limit a copy to
about 3 MB/s with 3 MB pieces, and to more with larger pieces.

One observation about the data itself: a 4.8 GB clip had about 3 MB of zero bytes shortly before its end, and the
camera returned the same zeros on a second read. The clip decodes completely.

## 10. Timing quirks

| Situation | What happens | What works |
|---|---|---|
| Record command 0–1 s after remote control reopens after a card session | Answered OK, **no recording** (0xD21D stays 0) | Wait 1.5 s, send, then confirm with 0xD21D. Resend once if it has not changed |
| Recording state after a command | 0xD21D follows a start after 1.4–2.3 s, a stop of a 4K 100M clip after 3.4–4.5 s | Show "recording" only once 0xD21D says so |
| Changing a setting (e.g. focus mode) **right after a photo** | Refused (libgphoto2: "Bad parameters"), seen after the first and after the last frame of a timelapse | Wait 1 s and try again (up to 4 times) |
| Ending touch focus within ~1 s of the touch | DeviceBusy 0x2019 | Retry after 0.4 s |
| Opening the card session right after closing remote control | Occasionally refused | Wait 0.4 s first, retry after 0.8 s |
| `GetStorageIDs` right after `SetContentsTransferMode (2,1,0)` | No card yet | Poll for about 1 s (allow 12 s) |
| Mode change | New choice lists only about 2 s later | Re-read all settings after a change |
| Zoom held | Live-view frames take up to 3 s | Pause live view until release |
| Recording stops and restarts between two polls (2 s apart) | Two clips for what looked like one stop | After a stop, copy every clip numbered above the last known one |

**Control port that stopped answering.** Once, after the bridge left and rejoined the camera's network while
PTP/IP connections were still open (one in its first exchange), the camera accepted TCP connections on 15740 for
about ten minutes but answered no Init Command Request. Its description page on 64321 still answered. The cause is
not proven. Since the bridge closes its connections cleanly before any rejoin and does not rejoin on every start,
it has not happened again. A camera power cycle is the sure way out.

**Small packets and delayed acknowledgements.** The camera sends a short answer as several small TCP segments
and holds each one back until the previous one has been acknowledged. A receiver that delays its ACKs (lwIP's
250 ms timer on the ESP32) therefore makes every short transaction cost about 250 ms, while a 2.5 KB answer
arrived complete in 22 ms. A receiver that acknowledges at once avoids this (section 12).

Other observed behaviour:

- Plugging in a USB data cable while in a Wi-Fi mode turns the camera into a USB device. It leaves Wi-Fi, ejecting
  the disk does not release it, and after unplugging it stays off the network (watched 5 and 14 minutes) until it
  is switched off and on. It then reappears at once with pairing intact.
- On a USB charger the battery reading changes very slowly (stayed at 35 % for over half an hour of use).

## 11. libgphoto2 notes

Tether Studio does remote control through libgphoto2 2.5.32 (`PTP/IP Camera` driver for Wi-Fi, the normal PTP
driver for USB) and adds a few things of its own:

- **Empty data packet.** Where the camera has no card to offer (PC Remote), it answers `GetStorageIDs` with
  Start Data of length 0, a **Data packet holding only the transaction id**, End Data and the response
  StoreNotAvailable. libgphoto2's PTP/IP reader takes the empty Data packet for the response and from then on
  reads every answer one transaction late: the session opens but no setting can be read. The app runs libgphoto2
  through a relay on 127.0.0.1 that drops Data packets with no payload. Everything else passes unchanged.
- **Init timeout.** libgphoto2 waits about 2.5 s for the Init Command Ack, which is too short for confirming
  pairing on the camera. The app does the pairing handshake itself with a 60 s wait, closes it properly (event
  connection included), and lets libgphoto2 connect afterwards.
- **Zoom and touch.** libgphoto2 2.5.32 writes 0xD2DD with `0x9205` as an 8-bit value, which the camera
  ignores. The app's relay sends zoom and touch itself as `0x9207` with the widths in section 5, on the open
  command connection, between libgphoto2's own transactions. It uses transaction ids from 0x7A000000 upward, a
  range libgphoto2 never reaches, so it can keep the responses for itself. Only the three controls 0xD2DD, 0xD2E4
  and 0xD2E5 can be sent this way, with values clamped.
- **Card.** libgphoto2 cannot open a contents-transfer session, so the card is read by the app's own small PTP/IP
  client. That client can send only GetDeviceInfo, CloseSession, GetStorageIDs, GetObjectHandles,
  GetObjectInfo, 0x9201, 0x9202, 0x9210, 0x9211, 0x9212 and 0x9803, and it has no host-to-camera data phase.
- Writes go through a fixed list of allowed settings. Anything else, and 0xD2CA in particular, is refused before
  it reaches the camera.

## 12. The ESP32-C3 bridge and its USB framing

The phone service exists only on the camera's own network, so a Mac that joined it would lose its router. Tether
Studio uses an **ESP32-C3** on USB instead. The board joins the camera's network and carries up to **six** TCP
connections between the camera and the Mac over USB. On the Mac the camera then appears at 127.0.0.1:15740 (and
64321). Board program: ESP-IDF 5.3, protocol version 5. The Wi-Fi name and password are sent over USB and kept in
RAM only, never in flash.

### 12.1 Frame format (both directions)

```
offset  0     1     2     3        4         5         6      7 …
        A5    5A    type  channel  len low   len high  check  payload (len bytes, at most 4096)

check = type ^ channel ^ len_low ^ len_high ^ 0xFF
```

A receiver resynchronises by skipping to the next `A5 5A` whose check byte is right. The board's boot messages
appear on the same USB serial port, so the host must skip non-frame bytes. Frames with a bad check or a length
above 4096 are dropped.

### 12.2 Message types

| Type | Direction | Payload | Answer |
|---|---|---|---|
| 0x01 WIFI | host → board | network name, 0x00, password | R_WIFI. If already joined to that name, nothing is cut |
| 0x02 OPEN | host → board | IPv4 (4, network order a.b.c.d), port (2, LE); channel 0–5 | R_OPENED |
| 0x03 DATA | host → board | bytes for the channel's TCP connection | — |
| 0x04 CLOSE | host → board | — | R_CLOSED |
| 0x05 STATUS | host → board | — | R_HELLO, then R_WIFI |
| 0x06 ECHO | host → board | anything | R_ECHO, same payload |
| 0x07 SCAN | host → board | — | R_SCAN (a few seconds) |
| 0x08 FLOOD | host → board | frame count (2) | that many 4096-byte R_FLOOD frames (USB speed test) |
| 0x09 DRAIN | host → board | — | count what the camera sends next and discard it. R_DRAIN once it has been quiet for 1 s |
| 0x81 R_WIFI | board → host | state (0 idle, 1 joining, 2 joined), last disconnect reason (ESP-IDF numbering), IPv4 (4), gateway (4), RSSI (int8) | — |
| 0x82 R_OPENED | board → host | 1 connected, 0 failed | sent before any data of that connection |
| 0x83 R_DATA | board → host | bytes from the camera | — |
| 0x84 R_CLOSED | board → host | — | also sent when the camera closes, Wi-Fi drops or the host stops reading |
| 0x86 R_ECHO | board → host | echo | — |
| 0x87 R_SCAN | board → host | count (0xFF = failed), then per network: RSSI, channel, auth mode, name length, name | — |
| 0x88 R_HELLO | board → host | version (1), boot id (4, LE, random per boot) | a new boot id means the board restarted and forgot the Wi-Fi details |
| 0x89 R_FLOOD | board → host | 4096 bytes of pattern | — |
| 0x8A R_DRAIN | board → host | bytes (4, LE), microseconds from first to last byte (4, LE) | — |

Channel life: OPEN → R_OPENED(1) → DATA / R_DATA both ways → CLOSE → R_CLOSED. The host reuses a channel only
after R_CLOSED. Tether Studio resends CLOSE after 3 s and takes the channel back after 6 s without confirmation.
The camera's address is the gateway from R_WIFI, falling back to 192.168.122.1.

### 12.3 Board behaviour that matters for speed and robustness

- **Immediate ACKs**: after every receive, the board sends any pending delayed TCP acknowledgement at once. This
  is the fix for the 250 ms-per-transaction problem in section 10. Short commands went from about 250 ms to 10–50 ms.
- TCP receive window 57,440 bytes, `TCP_NODELAY`, Wi-Fi power saving off (it added up to 100 ms per answer), 5 s
  connect timeout, 10 s send timeout.
- If the host stops reading USB for 3 s, the board treats it as gone and closes every connection.
- The host sends STATUS every 2 s and treats the board as gone after 8 s without any frame.
- Before rejoining or when a new program takes over the board, close all channels first, so that the camera sees
  its connections close (see the stuck control port in section 10). Only one program may use the board's port at
  a time: two readers take each other's frames.
- The board's USB is full speed (12 Mbit/s). About 0.99 MB/s board → Mac is the ceiling, and copies run at 95 % of it.

## 13. Measured speeds

| Link | Live view 640×360 | Live view 1024×576 | Settings poll | Short command | File copy |
|---|---|---|---|---|---|
| PC Remote, USB cable | 25 frames/s (~37 KB) | 25 frames/s (~153 KB) | 3–13 ms | — | not possible |
| PC Remote, router Wi-Fi | ~10 frames/s | 5–7 frames/s | ~140 ms | — | not possible |
| Phone control, ESP32-C3 bridge (ESP-IDF) | 14–15.5 frames/s (9 in 4K mode) | 6.2 frames/s (4.8 in 4K mode) | 28–52 ms | 10–50 ms | **0.93–0.95 MB/s** |
| Phone control, first bridge (delayed ACKs) | 4 frames/s | 2 frames/s | 46–64 ms | ~250 ms | 0.6 MB/s |
| Card mounted over USB (Mass Storage) | — | — | — | — | ~37 MB/s |

More figures:

- **The camera's own Wi-Fi alone** (DRAIN test: camera → ESP32-C3, no USB in the path, −46 dBm at one metre):
  2.7–2.9 MB/s (22–23 Mbit/s) for 3, 16 and 48 MB reads. Whether that is the camera's or the ESP32-C3's limit is
  not known.
- Wi-Fi live-view rate varies with the link (ping to the camera 9–230 ms). libgphoto2 costs about 10 % against a
  bare loop.
- Card listing, 58 entries: 3.3 s (fast bridge), 14–15 s (first bridge).
- Long run through the fast bridge: 60 files, 9.42 GB, in 2 h 43 min at a steady 0.93–0.95 MB/s, with no failed
  file. Every file was the size the card reports, and a 4.8 GB clip decoded completely.
- Through the bridge a 4K 100M clip takes about 13 times its length to copy, an HD 50p 25M clip about 3.3 times.

## 14. What this project deliberately does not do

- **No firmware operations.** Sony's vendor operation set includes firmware-update operations. Tether Studio
  never sends them and this document does not describe them.
- **No formatting.** The camera lists control 0xD2CA, thought to start a card format. Tether Studio never sends it, and
  its list of allowed writes refuses it.
- **No delete over Wi-Fi.** The camera offers none (section 4). Erasing works only on a card mounted as a disk.
- **No writes through the card client.** It has no host-to-camera data phase.
- No menu navigation, no settings outside the documented list, and no commands that were not tested on the camera.
