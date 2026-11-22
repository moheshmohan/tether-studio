# Privacy policy

*Tether Studio, effective 22 November 2026*

Tether Studio does not collect, store or share any personal data with its developer or with anyone
else.

- **No accounts, no analytics, no ads, no tracking.** The app contains no analytics or advertising code
  and makes no connections to the internet.
- **What stays on your Mac:** the app's settings, your presets, the camera's Wi-Fi name and password
  (so the bridge board can join the camera), and a random access token for its local AI interface. All
  of this stays in the app's own storage on your Mac.
- **Who the app talks to:** your camera (over its Wi-Fi network, through the ESP32-C3 board on USB, or
  over a USB cable); the board itself; and AI assistants you set up yourself on the same Mac, through
  its local MCP server at `127.0.0.1`. That server is reachable only from your Mac and only with the
  token.
- **Your clips and photos:** they are copied from the camera's card to the folder you choose on your
  Mac. They are never uploaded anywhere.
- **AI assistants:** if you connect one, what it reads from the app (status, settings, a live view
  picture) goes to that assistant, under that assistant's own privacy policy. Nothing is sent unless
  you set one up.

Questions: open an issue at https://github.com/moheshmohan/tether-studio/issues.
