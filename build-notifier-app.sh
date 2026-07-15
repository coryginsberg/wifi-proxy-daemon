#!/bin/zsh
set -euo pipefail

if [[ $# -ne 1 ]]; then
  echo "usage: build-notifier-app.sh <output-app-path>" >&2
  exit 1
fi

PROJECT_DIR="${0:A:h}"
APP_PATH="$1"
CONTENTS_DIR="$APP_PATH/Contents"
MACOS_DIR="$CONTENTS_DIR/MacOS"
RESOURCES_DIR="$CONTENTS_DIR/Resources"
EXECUTABLE_PATH="$MACOS_DIR/WiFiProxyNotifier"

rm -rf "$APP_PATH"
mkdir -p "$MACOS_DIR" "$RESOURCES_DIR"

swiftc "$PROJECT_DIR/notification_helper.swift" \
  -parse-as-library \
  -framework AppKit \
  -framework UserNotifications \
  -o "$EXECUTABLE_PATH"

cp "$PROJECT_DIR/WiFiProxyNotifier-Info.plist" "$CONTENTS_DIR/Info.plist"
chmod 755 "$EXECUTABLE_PATH"

# Generate the proxy app icon and place it in the bundle before signing so it is
# bound to the signature. Rendering is done with a small Swift program so the
# build has no external image-tooling dependencies.
ICON_BUILD_DIR="$(mktemp -d)"
ICONSET_DIR="$ICON_BUILD_DIR/AppIcon.iconset"
swiftc "$PROJECT_DIR/make-icon.swift" -framework AppKit -o "$ICON_BUILD_DIR/make-icon"
"$ICON_BUILD_DIR/make-icon" "$ICONSET_DIR"
iconutil -c icns "$ICONSET_DIR" -o "$RESOURCES_DIR/AppIcon.icns"
rm -rf "$ICON_BUILD_DIR"

# Re-sign the fully assembled bundle so the Info.plist and bundle identifier are
# bound to the signature. UNUserNotificationCenter requires a stable code
# signature with a valid bundle identifier; the linker-applied ad-hoc signature
# on the bare executable is not sufficient because the Info.plist is unbound.
CODESIGN_IDENTITY="${WIFI_PROXY_CODESIGN_IDENTITY:--}"
codesign --force --sign "$CODESIGN_IDENTITY" \
  --identifier "com.ginsbc.wifi-proxy-notifier" \
  "$APP_PATH"