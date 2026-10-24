#!/bin/bash
# Re-vendor the MyMu iOS client (~/Projects/mymu/MyMu) into ios/MyMuChat — the
# MyAgent app's chat IS MyMu's chat, verbatim (Manar 2026-10-24). Idempotent:
# rsync, the harness logos, the two host patches, and the VENDORING.md stamp.
#   scripts/vendor-mymu.sh [path-to-mymu-checkout]
set -euo pipefail
SRC=${1:-$HOME/Projects/mymu}
cd "$(dirname "$0")/.."
rsync -a --delete --exclude 'App/' --exclude 'Assets.xcassets' --exclude 'Info.plist' \
      --exclude '*.entitlements' --exclude '*.xcprivacy' --exclude VENDORING.md \
      "$SRC/MyMu/" ios/MyMuChat/
cp -r "$SRC"/MyMu/Assets.xcassets/harness-*.imageset ios/App/Assets.xcassets/
python3 - <<'PY'
import re
p='ios/MyMuChat/Core/AppGroup.swift'; s=open(p).read()
old='''enum AppGroup {
    static let id = "group.com.mymu.app"'''
new='''enum AppGroup {
    // HOST PATCH (MyAgent app, 2026-10-24): this client is vendored into the
    // MyAgent app, whose dev-signed builds carry NO app-group entitlement
    // (headless provisioning can't register one — see sp_deploy2.sh). The
    // MyMu group id would be a foreign group anyway. Use the host's own group
    // name for the defaults domain (works as a plain domain without the
    // entitlement) and keep Keychain items app-private, or every token write
    // fails with errSecMissingEntitlement and the sign-in never sticks.
    static let id = SharedConfig.appGroup
    static let keychainSharing = false'''
if 'HOST PATCH' not in s:
    assert old in s, 'AppGroup.swift changed upstream — re-check the patch'
    open(p,'w').write(s.replace(old,new))
p='ios/MyMuChat/Core/Keychain.swift'; s=open(p).read()
old='        if shared { query[kSecAttrAccessGroup as String] = AppGroup.id }'
new='        if shared, AppGroup.keychainSharing { query[kSecAttrAccessGroup as String] = AppGroup.id }  // HOST PATCH, see AppGroup'
if 'HOST PATCH' not in s:
    assert old in s, 'Keychain.swift changed upstream — re-check the patch'
    open(p,'w').write(s.replace(old,new))
print('host patches in place')
PY
HEAD=$(git -C "$SRC" rev-parse --short HEAD)
DIRTY=$(git -C "$SRC" status --short MyMu | wc -l | tr -d ' ')
cat > ios/MyMuChat/VENDORING.md <<MD
# Vendored MyMu client

\`ios/MyMuChat/\` is the MyMu iOS client (\`~/Projects/mymu/MyMu/{Core,Views}\`)
copied verbatim — it IS the chat of the MyAgent app (Manar 2026-10-24: "use the
chat from MyMu exactly as it is; it is hard to reimplement"). Do not restyle or
fork it here; fix things in MyMu and re-vendor with \`scripts/vendor-mymu.sh\`.

Last vendored: $(date +%F\ %H:%M) from MyMu HEAD $HEAD (+ $DIRTY uncommitted files in its tree).

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
MD
echo "vendored MyMu $HEAD (+$DIRTY dirty) into ios/MyMuChat"
