#!/bin/bash
# 打发布版：跑测试 → 通用二进制 → Developer ID 签名 → 公证 → 装订 → DMG（DMG 也签名、公证、装订）。
#
#   SIGN_ID="Developer ID Application: 名字 (TEAMID)" TEAM=TEAMID NOTARY_PROFILE=钥匙串配置名 tools/build_release.sh
#
# 成品：dist/RouDaiGuanJia.dmg（发布用）和 dist/肉呆大管家.app（本机安装用）
set -euo pipefail

: "${SIGN_ID:?请设置 SIGN_ID，比如 Developer ID Application: 名字 (TEAMID)}"
: "${TEAM:?请设置 TEAM（开发者团队 ID）}"
: "${NOTARY_PROFILE:?请设置 NOTARY_PROFILE（notarytool store-credentials 存的配置名）}"

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
NAME="肉呆大管家"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
OUT="$ROOT/dist"
DMG="$OUT/RouDaiGuanJia.dmg"

"$ROOT/Tests/run.sh" | tail -1

xcodebuild -project "$ROOT/TidyPaw.xcodeproj" -scheme TidyPaw -configuration Release \
    -derivedDataPath "$WORK/dd" ARCHS="arm64 x86_64" ONLY_ACTIVE_ARCH=NO \
    CODE_SIGN_STYLE=Manual CODE_SIGN_IDENTITY="$SIGN_ID" DEVELOPMENT_TEAM="$TEAM" \
    CODE_SIGN_INJECT_BASE_ENTITLEMENTS=NO OTHER_CODE_SIGN_FLAGS="--timestamp" \
    build > "$WORK/build.log" 2>&1 || { tail -30 "$WORK/build.log"; exit 1; }

APP="$WORK/dd/Build/Products/Release/$NAME.app"
codesign --verify --deep --strict "$APP"
echo "架构：$(lipo -archs "$APP/Contents/MacOS/$NAME")"

# 先公证 App 并装订，这样从 DMG 拖出来后离线也能通过系统检查
ditto -c -k --keepParent "$APP" "$WORK/app.zip"
xcrun notarytool submit "$WORK/app.zip" --keychain-profile "$NOTARY_PROFILE" --wait --timeout 20m
xcrun stapler staple "$APP"
xcrun stapler validate "$APP"

mkdir -p "$OUT" "$WORK/stage"
ditto "$APP" "$WORK/stage/$NAME.app"
ln -s /Applications "$WORK/stage/Applications"
rm -f "$DMG"
hdiutil create -quiet -volname "$NAME" -srcfolder "$WORK/stage" -format UDZO -ov "$DMG"
codesign --force --timestamp --sign "$SIGN_ID" "$DMG"
xcrun notarytool submit "$DMG" --keychain-profile "$NOTARY_PROFILE" --wait --timeout 20m
xcrun stapler staple "$DMG"
xcrun stapler validate "$DMG"
spctl -a -vvv -t open --context context:primary-signature "$DMG" 2>&1 | head -3

rm -rf "$OUT/$NAME.app"
ditto "$APP" "$OUT/$NAME.app"
spctl -a -vvv -t exec "$OUT/$NAME.app" 2>&1 | head -3
echo "成品：${DMG}，$(du -h "$DMG" | cut -f1)"
shasum -a 256 "$DMG"
