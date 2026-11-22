# Third-party notices

Tether Studio's own code is under the [MIT License](LICENSE). The downloadable app and the ESP32-C3
board image also contain the software below, each under its own licence. None of it has been modified.

## In the Mac app (`Tether Studio.app/Contents/Frameworks`)

These libraries are dynamically linked. They are built unmodified from the source archives below for
macOS 13 and later (`TetherStudio/scripts/build_deps.sh`), and copied into the app bundle. You may replace
any of them with your own build of the same library: put it in `Contents/Frameworks` under the same name
and re-sign the app (`codesign --force --deep --sign - "Tether Studio.app"`).

| Library | Version | Licence | Source |
|---|---|---|---|
| libgphoto2 and libgphoto2_port, with the `ptp2` camera driver and the `ptpip`, `usb1` and `disk` port drivers | 2.5.34 (port library 0.12.2) | LGPL-2.1-or-later | https://github.com/gphoto/libgphoto2 |
| libltdl (from GNU Libtool) | 2.6.2 | LGPL-2.1-or-later | https://www.gnu.org/software/libtool/ |
| libusb | 1.0.30 | LGPL-2.1-or-later | https://github.com/libusb/libusb |

The full text of the GNU Lesser General Public License 2.1 is in the app at
`Contents/Resources/licenses/LGPL-2.1.txt`, and in this repository at
[`TetherStudio/Resources/licenses/`](TetherStudio/Resources/licenses).

**Source code:** every GitHub release of Tether Studio has the exact source archives these libraries
were built from attached (`third-party-sources-<version>.tar`). If an archive is ever missing, open an
issue and it will be provided, for at least three years after the release.

## In the ESP32-C3 board image (`TetherStudio/Resources/firmware/bridge-esp32c3.bin`)

The bridge program is built with Espressif's [ESP-IDF](https://github.com/espressif/esp-idf) v5.3.3,
whose components are linked into the image:

| Component | Licence |
|---|---|
| ESP-IDF (drivers, system, bootloader) | Apache-2.0 |
| Espressif Wi-Fi and PHY libraries (`esp32-wifi-lib`, `esp-phy`) | Apache-2.0, distributed in binary form by Espressif |
| FreeRTOS kernel | MIT |
| lwIP TCP/IP stack | BSD-3-Clause |
| Mbed TLS | Apache-2.0 |

ESP-IDF's full list of component licences is in its repository, in `COPYRIGHT.rst`.

## Trademarks

Sony, ZV-E10 and Imaging Edge are trademarks of Sony Group Corporation or its affiliates. Espressif, ESP32
and ESP-IDF are trademarks of Espressif Systems. Seeed Studio and XIAO are trademarks of Seeed Technology
Co., Ltd. macOS and Mac are trademarks of Apple Inc. They are used only to say what this software works
with. Tether Studio is not affiliated with, endorsed by or sponsored by any of these companies.
