#!/usr/bin/env bash
#
# Собирает РЕЛИЗНЫЙ (Release) билд Salteca, ad-hoc подписывает его (без платного
# Apple Developer аккаунта) и упаковывает в оформленный .dmg с симлинком на
# /Applications.
#
# Требования: Xcode CLT, create-dmg (`brew install create-dmg`).
# Запуск:     ./scripts/build-dmg.sh
# Результат:  dist/Salteca-<version>.dmg
#
set -euo pipefail

# --- Пути и параметры ------------------------------------------------------
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SCHEME="Salteca"
CONFIG="Release"
APP_NAME="Salteca"
BUILD_DIR="$ROOT/build"
DIST_DIR="$ROOT/dist"
STAGE_DIR="$BUILD_DIR/dmg-stage"

cd "$ROOT"

# Версия для имени dmg — из настроек проекта (единый источник правды).
VERSION="$(xcodebuild -scheme "$SCHEME" -configuration "$CONFIG" -showBuildSettings 2>/dev/null \
  | awk -F' = ' '/ MARKETING_VERSION =/ {print $2; exit}')"
VERSION="${VERSION:-0.0.0}"
DMG_PATH="$DIST_DIR/${APP_NAME}-${VERSION}.dmg"

echo "▶︎ Сборка $SCHEME ($CONFIG), версия $VERSION"

# --- 1. Чистый релизный билд ----------------------------------------------
rm -rf "$BUILD_DIR"
# CODE_SIGNING_ALLOWED=NO — не подписываем на этапе Xcode-сборки: подпишем ad-hoc
# сами (ниже), предварительно сняв расширенные атрибуты. Иначе in-build codesign
# падает на «resource fork / Finder information / similar detritus not allowed».
xcodebuild \
  -scheme "$SCHEME" \
  -configuration "$CONFIG" \
  -derivedDataPath "$BUILD_DIR/dd" \
  -destination 'platform=macOS' \
  CODE_SIGNING_ALLOWED=NO \
  clean build \
  | tail -1

APP_PATH="$BUILD_DIR/dd/Build/Products/$CONFIG/$APP_NAME.app"
[ -d "$APP_PATH" ] || { echo "✗ Не найден $APP_PATH"; exit 1; }

# --- 2. Ad-hoc подпись -----------------------------------------------------
# У нас нет Developer ID (нет платного аккаунта), поэтому подписываем ad-hoc
# ("-"): это делает подпись валидной (приложение не считается «повреждённым»),
# но НЕ является нотаризацией — Gatekeeper всё равно предупредит (см. README).
echo "▶︎ Ad-hoc подпись"
# Снять «детрит» (расширенные атрибуты), иначе codesign откажет.
xattr -cr "$APP_PATH"
codesign --force --deep --sign - --timestamp=none "$APP_PATH"
codesign --verify --verbose "$APP_PATH" 2>&1 | tail -1 || true

# --- 3. Иконка тома (.icns из ассетов) -------------------------------------
ICONSET="$BUILD_DIR/Salteca.iconset"
ASSETS="$ROOT/Salteca/Assets.xcassets/AppIcon.appiconset"
mkdir -p "$ICONSET"
cp "$ASSETS/icon_16.png"   "$ICONSET/icon_16x16.png"
cp "$ASSETS/icon_32.png"   "$ICONSET/icon_16x16@2x.png"
cp "$ASSETS/icon_32.png"   "$ICONSET/icon_32x32.png"
cp "$ASSETS/icon_64.png"   "$ICONSET/icon_32x32@2x.png"
cp "$ASSETS/icon_128.png"  "$ICONSET/icon_128x128.png"
cp "$ASSETS/icon_256.png"  "$ICONSET/icon_128x128@2x.png"
cp "$ASSETS/icon_256.png"  "$ICONSET/icon_256x256.png"
cp "$ASSETS/icon_512.png"  "$ICONSET/icon_256x256@2x.png"
cp "$ASSETS/icon_512.png"  "$ICONSET/icon_512x512.png"
cp "$ASSETS/icon_1024.png" "$ICONSET/icon_512x512@2x.png"
VOLICON="$BUILD_DIR/Salteca.icns"
iconutil -c icns "$ICONSET" -o "$VOLICON"

# --- 4. Стейджинг и сборка .dmg -------------------------------------------
rm -rf "$STAGE_DIR"; mkdir -p "$STAGE_DIR" "$DIST_DIR"
cp -R "$APP_PATH" "$STAGE_DIR/"
rm -f "$DMG_PATH"

echo "▶︎ Упаковка .dmg"
# create-dmg сам добавляет симлинк на /Applications (--app-drop-link) и раскладку
# окна «перетащи в Applications». Раскладка ставится через Finder/AppleScript —
# при первом запуске macOS может спросить разрешение на автоматизацию Finder.
create-dmg \
  --volname "$APP_NAME $VERSION" \
  --volicon "$VOLICON" \
  --window-pos 200 120 \
  --window-size 600 400 \
  --icon-size 128 \
  --icon "$APP_NAME.app" 150 190 \
  --hide-extension "$APP_NAME.app" \
  --app-drop-link 450 190 \
  --no-internet-enable \
  "$DMG_PATH" \
  "$STAGE_DIR"

echo "✓ Готово: $DMG_PATH"
