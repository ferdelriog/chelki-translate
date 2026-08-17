#!/bin/bash
# Compila Traductor.app (barra de menús) sin necesidad de abrir Xcode.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")" && pwd)"
APP_NAME="Traductor"
BUILD_DIR="$ROOT/build"
APP="$BUILD_DIR/$APP_NAME.app"
MACOS_DIR="$APP/Contents/MacOS"
RES_DIR="$APP/Contents/Resources"

echo "▸ Limpiando…"
rm -rf "$APP"
mkdir -p "$MACOS_DIR" "$RES_DIR"

echo "▸ Compilando Swift…"
swiftc \
  -O \
  -swift-version 5 \
  -target arm64-apple-macos15.0 \
  -framework AppKit \
  -framework SwiftUI \
  -framework Translation \
  -framework Vision \
  -framework NaturalLanguage \
  -framework AVFoundation \
  -framework ServiceManagement \
  -framework Carbon \
  -o "$MACOS_DIR/$APP_NAME" \
  "$ROOT"/Sources/ChelkiTranslate/*.swift

echo "▸ Empaquetando…"
cp "$ROOT/Resources/Info.plist" "$APP/Contents/Info.plist"
if [ -f "$ROOT/Resources/AppIcon.icns" ]; then
  cp "$ROOT/Resources/AppIcon.icns" "$RES_DIR/AppIcon.icns"
fi

# La app se firma con App Sandbox y SIN permisos de red: es el sistema
# operativo el que impide que este proceso abra cualquier conexión.
echo "▸ Firmando con sandbox y sin permisos de red…"
codesign --force \
  --sign - \
  --entitlements "$ROOT/Resources/Traductor.entitlements" \
  "$APP"

echo "▸ Verificando que no haya permisos de red…"
if codesign -d --entitlements - --xml "$APP" 2>/dev/null | grep -q "network"; then
  echo "❌ La app quedó con permisos de red. Revisa Resources/Traductor.entitlements"
  exit 1
fi
echo "   ✓ sin com.apple.security.network.*"

echo "✅ Listo: $APP"
