# Native agent-chat — build & integration handoff (for claude-code-cli-ui)

You're replacing the flaky **Chat tab** (currently a WKWebView on
`code.kaxtus.com`) with a native SwiftUI agent chat. This doc has everything to
build, install, and integrate. Written by `mymu-voice` (owns the app's
voice/critter/music integration); the CHAT surface is now yours.

---

## 1. The iPhone app

- **Repo:** `git@github.com:OverDriveGain/mutibrain.git`, branch **`main`**,
  working copy at **`~/Projects/multibrain`** on berlin (10.10.0.2).
- **iOS project:** `ios/` — XcodeGen (`ios/project.yml`), NOT a committed
  `.xcodeproj` (it's generated). Two targets: `AIAssistant` (app, sources
  `App/` + `Shared/`) and `ScreenBroadcast` (extension).
- **The app is a TabView** (`ios/App/AIAssistantApp.swift`):
  - **Buddy** — voice + 3D critter (mymu-voice's; don't touch).
  - **Chat** — `ChatView()` — **THIS is what you replace.**
- **What Chat is today:** `ios/App/ChatView.swift`, a `UIViewRepresentable`
  WKWebView loading `SharedConfig.load().chatURL`
  (`https://code.kaxtus.com/?token=<agent-view JWT>`). Replace this view with a
  native SwiftUI chat; keep the same tab slot and the `chatURL`/token source.
- **Min iOS 16**, Swift 5. Third-party deps: the project has NO SPM packages
  wired yet — if you add one (e.g. a markdown renderer), add it in
  `project.yml` under `packages:` + the target's `dependencies:` and re-run
  xcodegen. Keep it lean; the extension shares `Shared/`.

## 2. How the app gets the token (your auth)

`ios/Shared/SharedConfig.swift`:
- `defaultChat = "https://code.kaxtus.com/?token=__MYMU_TOKEN__"` — the
  `__MYMU_TOKEN__` placeholder is **sed-replaced at build time** on the Mac
  (see §3) with a real **agent-view JWT** (claim `agentView: "special-agent"`,
  signed with the CCUI instance's `JWT_SECRET`, 180-day).
- Stored/overridable at runtime via `@AppStorage("chatURL")`.
- So your native ChatView should read the same `chatURL` (or just its
  `?token=`), parse the JWT/token out, and use it as the Bearer for whatever
  API you build. **The token already scopes to special-agent** server-side
  (`agent_allow` from the `agentView` claim) — REST, WS, files all enforce it.

## 3. Mac build + install pipeline (THE key info)

Builds run on the **fleet macbook `192.168.0.165`** over SSH from berlin
(berlin's key is trusted). Xcode 15.2 at
`/Applications/Xcode-15.2.0.app`. Target device: **Manar's iPhone 13 mini**,
udid **`00008110-00022D3001D9401E`**.

**Full recipe (each step from berlin):**
```bash
# 1. push source to the mac (rsync --delete WIPES the generated .xcodeproj)
rsync -a --delete --exclude .git --exclude .agent \
  ~/Projects/multibrain/ manar@192.168.0.165:~/multibrain/

# 2. inject the real tokens into the mac copy (placeholders -> secrets)
#    __GADK_TOKEN__  = manar's mymu-voice subscriber token (agents/manar/token)
#    __MYMU_TOKEN__  = the agent-view JWT (mint recipe below)
ssh manar@192.168.0.165 "sed -i '' \
  -e 's/__GADK_TOKEN__/<gadk>/' -e 's/__MYMU_TOKEN__/<mymu>/' \
  ~/multibrain/ios/Shared/SharedConfig.swift"

# 3. build + install (keychain unlock MUST be in the SAME ssh command)
ssh manar@192.168.0.165 "\
  security unlock-keychain -p '<mac-login-pw>' ~/Library/Keychains/login.keychain-db; \
  export DEVELOPER_DIR=/Applications/Xcode-15.2.0.app/Contents/Developer; \
  cd ~/multibrain/ios && ~/xcodegen-dist/xcodegen/bin/xcodegen generate && \
  xcodebuild -project AIAssistant.xcodeproj -scheme AIAssistant -configuration Debug \
    -destination 'id=00008110-00022D3001D9401E' -allowProvisioningUpdates \
    DEVELOPMENT_TEAM=7276Y3726M CODE_SIGN_STYLE=Automatic -derivedDataPath /tmp/dd build && \
  xcrun devicectl device install app --device 00008110-00022D3001D9401E \
    /tmp/dd/Build/Products/Debug-iphoneos/AIAssistant.app"
```

**Gotchas (all learned the hard way):**
- **Keychain**: `errSecInternalComponent` at CodeSign = keychain locked. The
  unlock does NOT persist across SSH sessions — put `security unlock-keychain`
  in the SAME `ssh` invocation as `xcodebuild`. One-time per machine also run:
  `security set-key-partition-list -S apple-tool:,apple:,codesign: -s -k <pw> \
   -D "Apple Development: over-drive-gain@hotmail.com (89CSAJ75S2)" \
   ~/Library/Keychains/login.keychain-db` (MUST target the key with `-D`).
- **xcodegen every sync**: rsync `--delete` removes the generated `.xcodeproj`.
  Binary lives at `~/xcodegen-dist/xcodegen/bin/xcodegen` (not on PATH).
- **7-DAY SIGNING EXPIRY**: free personal-team profiles die after 7 days →
  "app is not available" on the phone. Fix: `rm ~/Library/MobileDevice/
  Provisioning\ Profiles/*.mobileprovision` on the mac, rebuild (mints fresh).
- **USB is flaky**: `-402652910` / `RSD` / `CoreDevice error 1000` on install →
  loop-retry with `sleep`, and if the device shows `unavailable` it's usually a
  **bad cable** (`system_profiler SPUSBDataType | grep -i iphone` = empty →
  physical, not software). After an iPhone reboot the device needs UNLOCK
  before it's visible.
- `devicectl` needs `DEVELOPER_DIR` exported in every non-login ssh command.
- Signing identity: `Apple Development: over-drive-gain@hotmail.com (89CSAJ75S2)`,
  DEVELOPMENT_TEAM `7276Y3726M`. Mac login password: ask Manar (not stored).
- Bundle ids: `com.manarz.aiassistant` (+ `.ScreenBroadcast`).

## 4. Mint an agent-view token (the `__MYMU_TOKEN__` value)

The CCUI instance runs on **berlin:10099** (`~/Projects/claudecodeui`), public
at `code.kaxtus.com`. Admin can mint via
`POST /api/auth/agent-view-token {"agent":"special-agent"}`. Headless (JWT
secret from the live process):
```bash
P=$(ss -ltnp | grep :10099 | grep -oE 'pid=[0-9]+' | head -1 | cut -d= -f2)
SECRET=$(tr '\0' '\n' < /proc/$P/environ | grep '^JWT_SECRET=' | cut -d= -f2-)
cd ~/Projects/claudecodeui && JWT_SECRET="$SECRET" node -e \
  'console.log(require("jsonwebtoken").sign({agentView:"special-agent"},process.env.JWT_SECRET,{expiresIn:"180d"}))'
```

## 5. The data source — READ THIS BEFORE DESIGNING THE NATIVE CHAT

special-agent runs on **another host (thinkpad), not this CCUI box**. MyMu
surfaces its conversation as a **`remote:<sessionId>` project streamed over the
remote-control relay** (see `src/components/app/AppContent.tsx` agentView
auto-open, and `useChatRealtimeHandlers.ts`). So the chat is NOT a plain REST
message-history fetch — **history + live both come over the relay WebSocket**.
`/api/projects` returns `[]` for an agent-view token because the agent isn't a
local project. You know this protocol far better than I do — that's exactly why
this is your build, not mine. Whatever stable surface you expose (a mobile chat
API, or a documented relay-client contract), the native ChatView will consume
it; I'll wire the tab, token, and layout on the app side.

## 6. Division of labor
- **You (claude-code-cli-ui):** the native chat view + whatever CCUI-side API/
  contract it needs. You own the relay/agent semantics.
- **Me (mymu-voice):** the app shell — tab wiring, token plumbing
  (`SharedConfig`/`chatURL`), build/install via the pipeline above, layout/safe
  areas. Ping me (via Manar/special-agent) when you have a `ChatView.swift` to
  drop in, and I'll build + install it.
