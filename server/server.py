"""
Minimal ingest server for the realtime AI assistant.

Its only job (for now) is to:
  1. Accept WebSocket connections from the iOS app.
  2. Verify the auth token.
  3. Receive the streamed data (mic audio + whole-device screen frames).
  4. Log / optionally dump it to disk so you can verify the pipeline works.

The actual AI lives BEHIND this. Plug your model in where marked
`# >>> forward to your AI here`.

Run:
    pip install -r requirements.txt
    ASSISTANT_TOKEN=dev-secret-token python server.py
"""

import os
import time
import json
import logging
import pathlib

from fastapi import FastAPI, WebSocket, WebSocketDisconnect, Query, Header
from fastapi.responses import JSONResponse
import uvicorn

logging.basicConfig(
    level=logging.INFO,
    format="%(asctime)s  %(levelname)-5s  %(message)s",
    datefmt="%H:%M:%S",
)
log = logging.getLogger("ingest")

TOKEN = os.environ.get("ASSISTANT_TOKEN", "dev-secret-token")
DUMP = os.environ.get("DUMP_CAPTURES", "0") == "1"
CAPTURE_DIR = pathlib.Path(os.environ.get("CAPTURE_DIR", "./captures"))

app = FastAPI(title="Realtime Assistant Ingest")


def _authorized(token_q: str | None, authorization: str | None) -> bool:
    """Accept the token via ?token=... query param OR an Authorization: Bearer header."""
    if token_q and token_q == TOKEN:
        return True
    if authorization and authorization.startswith("Bearer "):
        return authorization.split(" ", 1)[1] == TOKEN
    return False


@app.get("/healthz")
async def healthz():
    return JSONResponse({"ok": True, "service": "ingest", "dump": DUMP})


@app.websocket("/v1/audio")
async def audio_ingest(
    ws: WebSocket,
    token: str | None = Query(default=None),
    authorization: str | None = Header(default=None),
):
    """Mic uplink from the app. Binary frames = 16 kHz mono PCM16. Text frames = JSON control."""
    if not _authorized(token, authorization):
        await ws.close(code=4401)
        log.warning("audio: rejected unauthorized connection")
        return

    await ws.accept()
    await ws.send_text(json.dumps({"type": "ready", "stream": "audio"}))
    peer = f"{ws.client.host}:{ws.client.port}" if ws.client else "?"
    log.info("audio: connected  %s", peer)

    total = 0
    chunks = 0
    sink = None
    if DUMP:
        CAPTURE_DIR.mkdir(parents=True, exist_ok=True)
        sink = open(CAPTURE_DIR / f"audio-{int(time.time())}.pcm", "wb")

    try:
        while True:
            msg = await ws.receive()
            if msg["type"] == "websocket.disconnect":
                break
            if (data := msg.get("bytes")) is not None:
                total += len(data)
                chunks += 1
                if sink:
                    sink.write(data)
                # >>> forward to your AI here: data is raw PCM16 @ 16kHz mono
                if chunks % 50 == 0:
                    log.info("audio: %d chunks  %.1f KB total", chunks, total / 1024)
            elif (text := msg.get("text")) is not None:
                log.info("audio: control %s", text)
                # echo an ack so the client knows the control round-trips
                await ws.send_text(json.dumps({"type": "ack", "echo": text}))
    except WebSocketDisconnect:
        pass
    finally:
        if sink:
            sink.close()
        log.info("audio: closed  %s  (%d chunks, %.1f KB)", peer, chunks, total / 1024)


@app.websocket("/v1/screen")
async def screen_ingest(
    ws: WebSocket,
    token: str | None = Query(default=None),
    authorization: str | None = Header(default=None),
):
    """Whole-device screen frames from the broadcast extension. Each binary frame = one JPEG."""
    if not _authorized(token, authorization):
        await ws.close(code=4401)
        log.warning("screen: rejected unauthorized connection")
        return

    await ws.accept()
    await ws.send_text(json.dumps({"type": "ready", "stream": "screen"}))
    peer = f"{ws.client.host}:{ws.client.port}" if ws.client else "?"
    log.info("screen: connected  %s", peer)

    frames = 0
    total = 0
    frame_dir = None
    if DUMP:
        frame_dir = CAPTURE_DIR / f"screen-{int(time.time())}"
        frame_dir.mkdir(parents=True, exist_ok=True)

    try:
        while True:
            msg = await ws.receive()
            if msg["type"] == "websocket.disconnect":
                break
            if (data := msg.get("bytes")) is not None:
                frames += 1
                total += len(data)
                if frame_dir:
                    (frame_dir / f"{frames:06d}.jpg").write_bytes(data)
                # >>> forward to your AI here: data is a JPEG screenshot of the whole device
                log.info("screen: frame #%d  %.1f KB", frames, len(data) / 1024)
            elif (text := msg.get("text")) is not None:
                log.info("screen: control %s", text)
    except WebSocketDisconnect:
        pass
    finally:
        log.info("screen: closed  %s  (%d frames, %.1f KB)", peer, frames, total / 1024)


if __name__ == "__main__":
    log.info("token = %r   dump = %s", TOKEN, DUMP)
    uvicorn.run(app, host="0.0.0.0", port=8000)
