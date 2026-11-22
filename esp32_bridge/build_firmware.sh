#!/bin/bash
# Builds the bridge program with ESP-IDF and puts one merged image (bootloader, partition table and
# program, to be written at address 0) into the Mac app, which flashes boards with it.
#   ESP_IDF=~/esp/esp-idf esp32_bridge/build_firmware.sh
set -euo pipefail
cd "$(dirname "$0")/idf"
. "${ESP_IDF:-$HOME/esp/esp-idf}/export.sh" >/dev/null
idf.py build
(cd build && esptool.py --chip esp32c3 merge_bin -o bridge-merged.bin @flash_args)
OUT=../../TetherStudio/Resources/firmware
mkdir -p "$OUT"
cp build/bridge-merged.bin "$OUT/bridge-esp32c3.bin"
VERSION=$(sed -n 's/^#define VERSION \([0-9]*\).*/\1/p' main/bridge.c)
IDF=$(idf.py --version | sed 's/^ESP-IDF //')
SHA=$(shasum -a 256 "$OUT/bridge-esp32c3.bin" | cut -d' ' -f1)
printf '{\n  "version": %s,\n  "chip": "esp32c3",\n  "esp_idf": "%s",\n  "sha256": "%s"\n}\n' "$VERSION" "$IDF" "$SHA" > "$OUT/bridge-esp32c3.json"
echo "==> $OUT/bridge-esp32c3.bin (bridge version $VERSION, $IDF)"
