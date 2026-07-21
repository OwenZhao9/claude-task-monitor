#!/bin/bash
# 构建 ClaudeTaskMonitor 并组装成 .app bundle
# 输出：<项目根>/build/ClaudeTaskMonitor.app
set -euo pipefail

# ★ 项目路径含中文和空格，一律用 "$(dirname "$0")" 而不是硬编码
cd "$(dirname "$0")"
APP_DIR="$(pwd)"
ROOT_DIR="$(cd .. && pwd)"

NAME="ClaudeTaskMonitor"
OUT_DIR="$ROOT_DIR/build"
APP="$OUT_DIR/$NAME.app"
BIN="$APP_DIR/.build/release/$NAME"

echo "==> swift build -c release"
swift build -c release

if [ ! -x "$BIN" ]; then
  echo "!! 构建产物不存在: $BIN" >&2
  exit 1
fi

echo "==> 组装 $APP"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN" "$APP/Contents/MacOS/$NAME"

cat > "$APP/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleName</key>              <string>ClaudeTaskMonitor</string>
  <key>CFBundleDisplayName</key>       <string>Claude 任务监控</string>
  <key>CFBundleExecutable</key>        <string>ClaudeTaskMonitor</string>
  <key>CFBundleIdentifier</key>        <string>local.claude.taskmonitor</string>
  <key>CFBundlePackageType</key>       <string>APPL</string>
  <key>CFBundleShortVersionString</key><string>0.1</string>
  <key>CFBundleVersion</key>           <string>1</string>
  <key>LSMinimumSystemVersion</key>    <string>14.0</string>
  <key>LSUIElement</key>               <true/>
  <key>NSHighResolutionCapable</key>   <true/>
</dict>
</plist>
PLIST

# ad-hoc 签名：让 TCC 身份稳定，否则每次重建都可能重新申请权限
echo "==> codesign (ad-hoc)"
codesign --force --sign - "$APP"
codesign -dv "$APP" 2>&1 | sed 's/^/    /'

echo ""
echo "==> 完成: $APP"
echo "    直跑（stdout 可见）: \"$APP/Contents/MacOS/$NAME\""
echo "    LaunchServices 启动: open \"$APP\""
