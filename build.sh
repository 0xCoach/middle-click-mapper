#!/bin/sh
set -eu

ROOT="$(cd "$(dirname "$0")" && pwd)"
APP="$ROOT/dist/鼠标中键映射助手.app"
BUNDLE_ID="com.middleclick.helper"
DMG="$ROOT/dist/鼠标中键映射助手.dmg"

# ---------------------------------------------------------------------------
# 准备 bundle 目录
# ---------------------------------------------------------------------------
mkdir -p "$APP/Contents/MacOS"
mkdir -p "$APP/Contents/Resources"

cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN"
  "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleDisplayName</key>
  <string>鼠标中键映射助手</string>
  <key>CFBundleExecutable</key>
  <string>鼠标中键映射助手</string>
  <key>CFBundleIconFile</key>
  <string>AppIcon</string>
  <key>CFBundleIdentifier</key>
  <string>$BUNDLE_ID</string>
  <key>CFBundleName</key>
  <string>鼠标中键映射助手</string>
  <key>CFBundlePackageType</key>
  <string>APPL</string>
  <key>CFBundleShortVersionString</key>
  <string>1.1</string>
  <key>CFBundleVersion</key>
  <string>2</string>
  <key>LSMinimumSystemVersion</key>
  <string>13.0</string>
  <key>LSUIElement</key>
  <true/>
  <key>NSHighResolutionCapable</key>
  <true/>
  <key>NSHumanReadableCopyright</key>
  <string>MiddleClickMapper</string>
</dict>
</plist>
PLIST

# ---------------------------------------------------------------------------
# 编译（arm64）并打包资源
# ---------------------------------------------------------------------------
swiftc "$ROOT/src/MiddleClickMapper.swift" \
	-o "$APP/Contents/MacOS/鼠标中键映射助手"
cp "$ROOT/assets/AppIcon.icns" "$APP/Contents/Resources/AppIcon.icns"
chmod +x "$APP/Contents/MacOS/鼠标中键映射助手"

# ---------------------------------------------------------------------------
# ad-hoc 签名：适合免费分发。接收方首次需运行安装脚本绕过 Gatekeeper。
# ---------------------------------------------------------------------------
codesign --force --options runtime --sign - "$APP" >/dev/null

plutil -lint "$APP/Contents/Info.plist" >/dev/null
echo "已构建并签名：$APP"

# ---------------------------------------------------------------------------
# 本机开发场景：ad-hoc 签名的二进制 cdhash 每次构建都会变，TCC 里堆积的
# 旧授权记录会对不上新的 cdhash，导致「检测不到授权 / 反复弹窗」。
# 这里在签名后清理失效记录。需要先关掉运行中的进程（reset 对运行中进程无效），
# 然后重启 app 并重新授权一次即可恢复。
#
# 注意：此步骤仅对本机开发有意义。分发给别人的 DMG 是单一固定版本，
# 接收方机器是干净的，不会堆积失效记录，故分发场景不受影响。
# ---------------------------------------------------------------------------
pkill -f "$APP/Contents/MacOS/鼠标中键映射助手" 2>/dev/null || true
sleep 1
tccutil reset Accessibility "$BUNDLE_ID" 2>/dev/null || true
echo "已清理 TCC 失效授权记录（本机开发用）；重启 app 后需重新授权一次。"

# ---------------------------------------------------------------------------
# 打包 DMG：内含 App、安装脚本、Applications 快捷方式、背景图
# ---------------------------------------------------------------------------
STAGING="$ROOT/dist/dmg-staging"
rm -rf "$STAGING"
mkdir -p "$STAGING/.background"

cp -R "$APP" "$STAGING/"

ln -s /Applications "$STAGING/Applications"

if [ -f "$ROOT/assets/dmg-background.png" ]; then
	cp "$ROOT/assets/dmg-background.png" "$STAGING/.background/background.png"
fi

rm -f "$DMG"
hdiutil create -volname "鼠标中键映射助手" \
	-srcfolder "$STAGING" \
	-fs HFS+ \
	-ov -format UDZO "$DMG" >/dev/null

rm -rf "$STAGING"
echo "已生成 DMG：$DMG"
