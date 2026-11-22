# Security

## Reporting a problem

Please report security problems privately, through
[GitHub's private vulnerability reporting](../../security/advisories/new) for this repository, rather
than in a public issue. Say what you found, how to reproduce it, and which version you used. You will get
an answer within a week.

## What the app exposes

- **MCP server:** `http://127.0.0.1:8765/mcp`, listening on the loopback address only. Every request
  needs the bearer token in `~/Library/Application Support/Tether Studio/mcp-token` (mode 0600), and
  requests with a web page's `Origin` are refused. Turn it off with **Camera ▸ MCP Server for AI
  Assistants**. To change the token, quit the app, delete the file and open the app again. Then set up your
  MCP clients again with the new token.
- **Bridge relay:** while the ESP32 bridge is on, the app listens on `127.0.0.1` (ports 15740 and 64321)
  to carry the camera's connection. These are also loopback only.
- **Stored secrets:** the camera's Wi-Fi password, in `bridge.json` in the same folder (mode 0600). The
  board keeps it in RAM only.
- **Actions that cannot be undone:** erasing the card and writing the board's flash. Both need a person to
  confirm in the app's window. MCP clients can only open those sheets.

## What the app never does

- It sends no firmware-update or card-format operations to the camera.
- It never deletes or overwrites files on the Mac's own disks.
- It writes only to ESP32-C3 chips, after checking the chip type and MAC address in the chip's
  bootloader.
- It sends nothing to the internet.
