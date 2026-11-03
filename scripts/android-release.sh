#!/usr/bin/env bash
# Build a signed MyAgent APK and publish it at https://agent.kaxtus.com/static/android/
# (the voice server's static/ is bind-mounted on the cloud host — live on copy, no rebuild).
#
#   scripts/android-release.sh            # bump versionCode, build, publish
#   scripts/android-release.sh --no-bump  # rebuild the current versionCode
#   scripts/android-release.sh --local    # build only, don't publish
#
# Needs: android/keystore.properties (symlink to ~/.vault/myagent-android-keystore.properties)
# and, for baked secrets, android/app/src/main/assets/baked.properties (gitignored).
set -euo pipefail
cd "$(dirname "$0")/../android"
BUMP=1; PUBLISH=1
for a in "$@"; do case $a in --no-bump) BUMP=0;; --local) PUBLISH=0;; esac; done

[ -f keystore.properties ] || { echo "no keystore.properties (see ~/.vault/myagent-android-keystore.properties)"; exit 1; }
G=app/build.gradle.kts
if [ $BUMP = 1 ]; then
  v=$(grep -oP 'versionCode = \K[0-9]+' $G); n=$((v + 1))
  sed -i "s/versionCode = $v/versionCode = $n/" $G
  echo "versionCode $v -> $n"
fi
CODE=$(grep -oP 'versionCode = \K[0-9]+' $G)
NAME=$(grep -oP 'versionName = "\K[^"]+' $G)

./gradlew --no-daemon -q assembleRelease
APK=app/build/outputs/apk/release/app-release.apk
"$HOME/Android/Sdk/build-tools/36.0.0/apksigner" verify "$APK"
OUT=/tmp/myagent-android; mkdir -p $OUT
cp "$APK" "$OUT/myagent.apk"; cp "$APK" "$OUT/myagent-b$CODE.apk"
printf '{"versionCode":%s,"versionName":"%s","apk":"myagent-b%s.apk","sha256":"%s"}\n' \
  "$CODE" "$NAME" "$CODE" "$(sha256sum "$APK" | cut -d' ' -f1)" > "$OUT/latest.json"
echo "built $NAME ($CODE): $(du -h "$APK" | cut -f1)"

[ $PUBLISH = 1 ] || exit 0
DEST=/home/manar/mymu-voice/static/android
ssh 10.10.0.1 "mkdir -p $DEST"
scp -q "$OUT/myagent-b$CODE.apk" "$OUT/latest.json" dist/index.html dist/icon.png 10.10.0.1:$DEST/
ssh 10.10.0.1 "cd $DEST && cp myagent-b$CODE.apk myagent.apk"
curl -sfI https://agent.kaxtus.com/static/android/myagent.apk | head -1
echo "published: https://agent.kaxtus.com/static/android/"
