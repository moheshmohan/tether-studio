# Publishing Tether Studio on the Mac App Store

The App Store version is the same app, built to run in Apple's **App Sandbox** and packaged as an
installer for App Store Connect. The GitHub DMG stays as it is.

## Status

- 22 Nov 2026: bundle ID registered, Mac App Store provisioning profile created (via the App Store Connect
  API), app record created, and build **1.0.0 (1)** uploaded. Apple processed it as valid.
- Next: the listing (texts, screenshots, privacy answers), a TestFlight check, then **Submit for Review**.

## What is ready

- **Build:** `TetherStudio/scripts/make_appstore.sh` builds the sandboxed app and, with your
  certificates and profile, the signed `.pkg` to upload.
- **Entitlements:** [`TetherStudio/Resources/appstore/TetherStudio.entitlements`](../TetherStudio/Resources/appstore/TetherStudio.entitlements)
  asks only for what the app uses, with no temporary exceptions:

  | Entitlement | Used for |
  |---|---|
  | `app-sandbox` | Required for the Mac App Store |
  | `network.client` | The camera over PTP/IP, and finding it on the network |
  | `network.server` | The MCP server and the board relay, both on `127.0.0.1` only |
  | `device.usb` | The camera on a USB cable (PC Remote), through libusb |
  | `device.serial` | The ESP32-C3 board: the bridge and the board set-up |
  | `assets.movies.read-write` | Clips and photos go to `~/Movies/ZV-E10` by default |
  | `files.user-selected.read-write`, `files.bookmarks.app-scope` | Another download folder, or the camera's card mounted as a disk, picked by the user once |

- **Sandbox behaviour (added for this build):** the sandbox lets the app see that the card is mounted but
  not read it. So the clip list shows **Allow Access to the Card…**, which opens an Open panel at the
  card. The choice is remembered per card. A download folder chosen outside `~/Movies` is remembered
  the same way (`SandboxAccess.swift`).
- **Tried in the sandbox on 22 Nov 2026 with the camera:**
  - connecting through the board, and live view;
  - the MCP server;
  - a photo saved to `~/Movies`;
  - listing boards, and flashing the board (18.9 s, verified);
  - a card mounted as a disk: asking for access, remembered after a relaunch, listing, copying,
    and erasing with the typed confirmation.
- **Info.plist:** `ITSAppUsesNonExemptEncryption` = false (the app has no encryption of its own), category
  Photography, icon as an asset catalog (`Assets.car`) and `.icns`, minimum macOS 13.

## What you need to do in your Apple Developer account

You have the **Apple Distribution** certificate already. Still needed:

1. **Mac Installer Distribution certificate:** developer.apple.com ▸ Certificates ▸ + ▸ *Mac Installer
   Distribution*. Install it in Keychain Access. It shows up as `3rd Party Mac Developer Installer: …`.
2. **App ID:** Identifiers ▸ + ▸ App IDs ▸ App. Use the explicit Bundle ID
   `io.github.moheshmohan.tetherstudio`; no extra capabilities are needed.
3. **Provisioning profile:** Profiles ▸ + ▸ *Mac App Store Connect* (Distribution). Choose the App ID and
   the Apple Distribution certificate, then download the `.provisionprofile`.
4. **App record:** App Store Connect ▸ Apps ▸ + ▸ New App. Platform macOS, name **Tether Studio** (if
   taken: "Tether Studio for ZV-E10" is not allowed, so pick another name, such as "Tether Studio
   Camera Remote"), Bundle ID as above, SKU `tetherstudio-mac`.

## Build and upload

```bash
cd TetherStudio && scripts/build_deps.sh
```

```bash
VERSION=1.0.0 BUILD=1 SIGN_ID="Apple Distribution: Your Name (TEAMID)" INSTALLER_ID="3rd Party Mac Developer Installer: Your Name (TEAMID)" PROFILE=~/Downloads/Tether_Studio.provisionprofile scripts/make_appstore.sh
```

Upload `dist/TetherStudio-1.0.0-appstore.pkg` with Apple's **Transporter** app (free on the Mac App
Store). Each upload needs a higher `BUILD` number.

To try the signed build before it goes to review, add it to **TestFlight** in App Store Connect and
install it with the TestFlight app on your Mac. Quit the DMG version first: both use the same bundle ID.
To try only the sandbox, `scripts/make_appstore.sh` without any variables builds an ad-hoc signed,
sandboxed app in `build/` that runs on this Mac.

## Listing (draft)

| Field | Text |
|---|---|
| Name (30) | Tether Studio |
| Subtitle (30) | Remote for Sony ZV-E10 |
| Category | Photography (secondary: Utilities) |
| Price | Free |
| Age rating | 4+ |
| Keywords (100) | camera remote,tether,vlog,live view,timelapse,clip transfer,ESP32,MCP,mirrorless,ZV-E10 |
| Support URL | https://github.com/moheshmohan/tether-studio/issues |
| Marketing URL | https://github.com/moheshmohan/tether-studio |
| Privacy policy URL | https://github.com/moheshmohan/tether-studio/blob/main/PRIVACY.md |
| App Privacy | Data Not Collected |

**Promotional text:** Control your Sony ZV-E10 from your Mac. Live view, record, and every clip copied
as soon as it is made, while your Mac stays on your own Wi-Fi.

**Description:**

> Tether Studio turns your Mac into a remote control and clip downloader for the Sony ZV-E10 camera.
>
> • Live view with touch focus and tracking
> • Start and stop recording; a ready check warns about a full card, a low battery or heat
> • Each clip is copied to your Mac when you stop recording
> • Every camera setting, plus one-click presets (4K, smooth HD, slow motion, film look, low light…)
> • Photos and timelapses, made into a movie on your Mac
> • Power zoom, manual focus steps and autofocus
> • An alert when a take ends by itself: card full, battery flat, camera hot, link lost
> • Sets the camera's clock from your Mac
> • Built-in MCP server, so AI assistants such as Claude can run the camera for you
>
> To control the camera over its own Wi-Fi while your Mac stays on your network, Tether Studio uses an
> inexpensive Seeed Studio XIAO ESP32-C3 board on USB. The app sets the board up for you with one
> click. You can also connect the camera directly by USB.
>
> Tether Studio is free and open source (MIT). It is an independent project, not affiliated with or
> endorsed by Sony.

**Screenshots:** App Store Connect wants 16:10 images, for example 2880×1800 or 1440×900. Frame the
README screenshots on a plain background at that size, with the camera pointed at something you are
happy to show.

## Notes for App Review

Paste into *App Review Information ▸ Notes*:

> Tether Studio controls a Sony ZV-E10 camera and needs that camera to do anything useful. To reach the
> camera's own Wi-Fi without taking the Mac off its network, it uses a small ESP32-C3 USB board. The
> app can install its open-source bridge program on that board (source:
> github.com/moheshmohan/tether-studio/tree/main/esp32_bridge); this writes only to the external board,
> never runs code on the Mac. Without the camera the app opens and shows "No camera connected". A video
> of the app with the camera is at: <add a link to a short screen recording>.
>
> The local MCP server listens on 127.0.0.1 only and requires a token. It lets AI assistants on the same
> Mac use the app's features. The app collects no data and makes no internet connections.

Reviewers can't test camera hardware, so the short screen recording matters. Show connecting,
recording, a clip being copied, and the board set-up.

## Points to be aware of

- **Trademarks (guideline 5.2):** "Sony" and "ZV-E10" appear only to say which camera the app works
  with (subtitle, description). There are no Sony logos or Sony-like icons. If review objects to the
  subtitle, use "Camera remote and clip copy" and keep the camera name in the description.
- **LGPL libraries:** libgphoto2, libltdl and libusb are dynamically linked and unmodified, their
  licence and source are provided (THIRD_PARTY_NOTICES.md), and the full app source is public. This is
  the usual basis for shipping LGPL libraries in the App Store. Some people argue that the App Store's
  terms clash with the LGPL. If that worries you, ask the libgphoto2 maintainers.
- **Apple silicon only:** the bundled libraries are arm64. Intel Macs would need a universal build of
  them (`build_deps.sh` with `-arch x86_64` added, then `lipo`).
- **Separate settings:** the App Store version keeps its settings in its sandbox container, so its
  first launch starts fresh: enter the camera's network and password again. Its MCP token is different
  too: use **Camera ▸ Copy MCP Setup Command** again. Don't run the DMG and App Store versions at the
  same time.
- **Not in the sandbox build:** copying old "ZVE10 Studio" settings (another app's data), and, for MCP
  clients, the README's `$(cat …mcp-token)` path. The copied setup command already contains the token.
