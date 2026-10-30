#!/bin/bash
# CodexDog 安装脚本：编译桌宠并安装到 ~/Applications
set -e
cd "$(dirname "$0")"
APP="$HOME/Applications/CodexDog.app"
BUILD="build/CodexDog.app"

echo "🐶 编译中…"
rm -rf build
mkdir -p "$BUILD/Contents/MacOS" "$BUILD/Contents/Resources"
swiftc -O -target "$(uname -m)-apple-macos14.0" main.swift -o "$BUILD/Contents/MacOS/CodexDog"
cp Info.plist "$BUILD/Contents/"
cp photos/*.heic photos/sausage.jpg photos/sleep.jpg clean_images.py "$BUILD/Contents/Resources/"
cp -R photos/beg photos/stand photos/look "$BUILD/Contents/Resources/"
codesign --force --sign - "$BUILD" >/dev/null 2>&1

echo "📦 安装到 ~/Applications …"
pkill -x CodexDog 2>/dev/null || true
rm -rf "$HOME/Library/Application Support/CodexDog"   # 重新抠图
mkdir -p "$HOME/Applications"
rm -rf "$APP"
cp -R "$BUILD" "$APP"
rm -rf build

open "$APP"
echo "✅ 完成！小黑平时躲着，在屏幕右下角来回晃鼠标它就出来。点它清理，拖它移动，右键有更多选项。"
