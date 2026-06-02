# Realtime AI Assistant — iOS client + ingest server

An iPhone app that **streams your microphone and your whole-device screen to a
server in real time**, and plays back whatever audio the server sends in reply
(your assistant's voice). The server here is intentionally dumb: it authenticates
the connection, receives the data, and logs it. **You** put the real AI behind it.

```
 iPhone                                   Your server
 ┌───────────────────────────┐           ┌─────────────────────────┐
 │ Mic  ──► AudioStreamer ────┼─ ws ─────►│ /v1/audio  (PCM16 16k)  │
 │ TTS  ◄── speaker      ◄────┼─ ws ──────│   ◄─ assistant audio    │
 │                            │           │                         │
 │ Screen ─► Broadcast Ext ───┼─ ws ─────►│ /v1/screen (JPEG frames)│
 └───────────────────────────┘           └─────────────────────────┘
                                              │  forward to YOUR AI
```

## What the server receives

- **`/v1/audio`** — binary WebSocket messages, each a chunk of raw **PCM16, 16 kHz,
  mono**. Text messages are JSON control frames. The server may push binary audio
  back down the same socket (16 kHz mono PCM16) and the app will play it.
- **`/v1/screen`** — binary WebSocket messages, each **one JPEG** screenshot of the
  whole device (downscaled to ≤720px wide, ~2 fps).

Both connections authenticate with a token, sent as `Authorization: Bearer <token>`
(and also accepted as `?token=` for convenience).

## Run the server

```bash
cd server
pip install -r requirements.txt
ASSISTANT_TOKEN=dev-secret-token DUMP_CAPTURES=1 python server.py
# DUMP_CAPTURES=1 writes received audio (.pcm) and screen frames (.jpg) to ./captures
```

Health check: `curl http://localhost:8000/healthz`

Find your machine's LAN IP (the phone must reach it): `ipconfig getifaddr en0` (macOS).

## Build the iOS app

The project is defined with [XcodeGen](https://github.com/yonsm/XcodeGen) so it
stays plain-text and reproducible.

```bash
brew install xcodegen
cd ios
xcodegen generate
open AIAssistant.xcodeproj
```

Then, once in Xcode:

1. Select both targets → **Signing & Capabilities** → set your **Team**.
2. Confirm both targets share the **App Group** `group.com.example.aiassistant`
   (already in the entitlements files — adjust the ID if you change the bundle prefix).
3. Run on a **real device** (screen broadcast + background audio don't work in the
   Simulator).

In the app:

1. Enter your server as `ws://<your-lan-ip>:8000` and the token.
2. **Start microphone** → audio begins streaming (watch the server log).
3. Tap the **screen** button → **Start Broadcast** → whole-device frames stream.

## "Keeps recording when the phone is closed"

- **Microphone: yes.** The app declares the `audio` background mode and holds an
  active record session, so the mic keeps streaming when the app is backgrounded
  or the phone is **locked**.
- **Screen: while the display is on.** ReplayKit can only capture frames that are
  actually being rendered. When the screen is fully **off/locked**, there is
  nothing to capture, so screen frames pause and resume when the screen lights up.
  (This is an OS-level limitation, not something the app can bypass.)

## Where your AI plugs in

In `server/server.py`, look for the two `# >>> forward to your AI here` markers —
that's where the PCM audio and JPEG frames arrive. Send the assistant's spoken
reply back to the app by calling `await ws.send_bytes(pcm16)` on the `/v1/audio`
socket.

## Identifiers to change for your own app

- Bundle IDs: `com.example.aiassistant` and `…ScreenBroadcast`
- App Group: `group.com.example.aiassistant`

Change them in `project.yml`, both `*.entitlements`, and `Shared/SharedConfig.swift`
(`appGroup`, `extensionBundleID`).
