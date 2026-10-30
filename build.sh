#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")"

APP_NAME="阮·梅桌宠"
APP="dist/${APP_NAME}.app"
BIN="RuanMeiPet"

echo "==> 生成图标"
rm -rf assets/AppIcon.icns
iconutil -c icns assets/AppIcon.iconset -o assets/AppIcon.icns

echo "==> 编译"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
mkdir -p .build/tmp .build/modulecache
TMPDIR="$PWD/.build/tmp" swiftc -O -swift-version 5 \
    -module-cache-path "$PWD/.build/modulecache" \
    -target "$(uname -m)-apple-macos13.0" \
    Sources/*.swift \
    -o "$APP/Contents/MacOS/$BIN"

echo "==> 组装 App"
cp Info.plist "$APP/Contents/Info.plist"
cp assets/ruanmei.png "$APP/Contents/Resources/ruanmei.png"
cp assets/fx_*.png "$APP/Contents/Resources/"
cp assets/ruanmei_voice.m4a "$APP/Contents/Resources/"
cp assets/ruanmei_greet.m4a "$APP/Contents/Resources/"
cp assets/ruanmei_move.m4a "$APP/Contents/Resources/"
cp assets/ruanmei_click1.m4a "$APP/Contents/Resources/"
cp assets/ruanmei_click2.m4a "$APP/Contents/Resources/"
cp assets/ruanmei_click3.m4a "$APP/Contents/Resources/"
cp assets/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"
printf 'APPL????' > "$APP/Contents/PkgInfo"

echo "==> 临时签名"
codesign --force --sign - --timestamp=none "$APP" >/dev/null 2>&1 || true

echo "==> 完成：$APP"
