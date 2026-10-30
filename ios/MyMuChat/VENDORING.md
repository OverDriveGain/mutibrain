# Vendored MyMu client

`ios/MyMuChat/` is the MyMu iOS client (`~/Projects/mymu/MyMu/{Core,Views}`)
copied verbatim — it IS the chat of the MyAgent app (Manar 2026-10-24: "use the
chat from MyMu exactly as it is; it is hard to reimplement"). Do not restyle or
fork it here; fix things in MyMu and re-vendor with `scripts/vendor-mymu.sh`.

Last vendored: 2026-10-24 10:13 from MyMu HEAD ab6b906 (+ 0 uncommitted files in its tree).

The script re-applies the HOST PATCHES (grep "HOST PATCH"):
  * Core/AppGroup.swift — id = SharedConfig.appGroup, keychainSharing = false
  * Core/Keychain.swift — access group only when keychainSharing
(the app's dev-signed builds have no app-group entitlement; a shared-keychain
write fails and the MyMu sign-in would never persist).

Not wired on purpose: MyMuApp.swift (excluded in project.yml), PushManager
(the app has its own APNs path in App/PushNotifications.swift), the mymu://
URL scheme (QRAccess). MyMu's own Info.plist / assets / entitlements are not
copied (the harness logos are, into App/Assets.xcassets). The host side lives
in App/BrainChat.swift (sign-in + which agent) and App/ChatDrawer.swift +
App/PetView.swift (the voice <-> chat drawer).


## Host patches (re-apply after a re-vendor)

- `Core/ProjectsStore.swift` — `agentFilter: [String]?` + `agents` honouring it
  (the drawer's curated swipe roster, 2026-10-30).
- `Views/ChatView.swift` — `.onReceive(Dictation.shared.$result)` → `pendingInsert`
  (dictation lands in the composer, 2026-10-30).
