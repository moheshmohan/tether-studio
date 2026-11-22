# Contributing

Thanks for helping. Issues and pull requests are welcome.

- **Bugs:** say which Mac and macOS version you use, the camera's firmware version, how the camera was
  connected (board, its Wi-Fi, USB PC Remote or Mass Storage), and what the app showed. The app writes a
  debug log to `$TMPDIR/tether-studio-debug.log`. Look through it before attaching it: it holds clip
  names and the camera's network name.
- **Other cameras:** reports from other Sony models are very welcome, working or not.
- **Pull requests:** run `swift test` in `TetherStudio/` and the Python tests (`python3 -m unittest
  discover -s tests`). Keep changes focused, and add tests for new behaviour.

## Ground rules for camera commands

Tether Studio must never risk a camera. A new operation or property goes on the app's fixed list only
after it has been tried on a real camera, and these are never added: firmware update or upload
operations, and card formatting over the camera link. Anything that deletes or writes for good (the
card, the board's flash) needs a confirmation by a person in the window, and stays out of reach of MCP
clients.

## Clean-room rule

Don't contribute code, text or binaries taken from Sony's software, SDKs or documentation. Describe what
you observed on the camera or on the wire, in your own words.
