
## 2026-09-20 18:xx — capture APP audio too (record the far side of calls)
Manar: "how to make [the other party's voice] recorded?" ScreenBroadcast/SampleHandler.swift
now routes `.audioApp` through the same handleAudio() path as `.audioMic` (was: `.audioApp`
explicitly dropped). Both mix into one mono WAV segment → /ingest-audio = whole call, both
sides. Gated by build-time const `captureAppAudio=true` (App Groups stripped in this build, a
runtime toggle can't reach the extension). CAVEAT flagged to Manar: indiscriminate — records
ALL device playback while broadcasting, not only calls; and §201 StGB (recording another's
non-public speech w/o consent) applies. Shipped to build 14: rebuilt spfiles.tar from berlin
(now INCLUDES SampleHandler.swift — was missing from the tar), scp'd to mac ~/, bumped recipe
13→14, patched sp_deploy2.sh to prompt for MACPW (read -s) so no password exposure. HUMAN STEP
(keychain locked, only Manar has the pw): `ssh -t manar@192.168.0.165 'zsh ~/sp_deploy2.sh'`
with iPhone unlocked → build14 install. Working tree changed, NOT committed (Manar's repo).
