#!/bin/zsh
set -euo pipefail

PROJECT_DIR="${0:A:h}"

# Optionally roll the semantic version before building: build-pkg.sh --bump [part]
if [[ "${1:-}" == "--bump" ]]; then
  "$PROJECT_DIR/bump-version.sh" "${2:-patch}" >/dev/null
fi

SERVICE_NAME="com.ginsbc.wifi-proxy-daemon"
BUILD_DIR="${WIFI_PROXY_BUILD_DIR:-$PROJECT_DIR/build/pkg}"
ROOT_DIR="$BUILD_DIR/root"
DIST_DIR="${WIFI_PROXY_DIST_DIR:-$PROJECT_DIR/dist}"
INSTALL_DIR="$ROOT_DIR/usr/local/libexec/wifi-proxy-daemon"
SHARE_DIR="$ROOT_DIR/usr/local/share/wifi-proxy-daemon"
SYSTEM_BINARY_PATH="/usr/local/libexec/wifi-proxy-daemon/wifi-proxy-daemon"
STAGED_BINARY_PATH="$INSTALL_DIR/wifi-proxy-daemon"
PLIST_PATH="$ROOT_DIR/Library/LaunchDaemons/$SERVICE_NAME.plist"
APP_PATH="$ROOT_DIR/Applications/Utilities/WiFiProxyNotifier.app"
NOTIFIER_APP_PATH="/Applications/Utilities/WiFiProxyNotifier.app"
STATE_PATH="/var/run/wifi-proxy-daemon.state"
LOG_PATH="/var/log/wifi-proxy-daemon.log"
DOMAIN_MATCH="${WIFI_PROXY_DOMAIN_MATCH:-cat.com}"
VPN_MATCH="${WIFI_PROXY_VPN_MATCH:-Cisco Secure Client}"
PROXY_HOST="${WIFI_PROXY_HOST:-proxy.cat.com}"
PROXY_PORT="${WIFI_PROXY_PORT:-80}"
LISTEN_PORT="${WIFI_PROXY_LISTEN_PORT:-3128}"
PROXY_NO_PROXY="${WIFI_PROXY_NO_PROXY:-localhost,127.0.0.1,::1,.cat.com,169.254.169.254}"
PROXY_NON_PROXY_HOSTS="${WIFI_PROXY_NON_PROXY_HOSTS:-*.cat.com|localhost|127.0.0.1|::1}"
PACKAGE_VERSION="${PACKAGE_VERSION:-$(<"$PROJECT_DIR/VERSION")}"
PACKAGE_VERSION="${PACKAGE_VERSION//[[:space:]]/}"
PACKAGE_PATH="$DIST_DIR/WiFiProxyDaemon-$PACKAGE_VERSION.pkg"
export WIFI_PROXY_VERSION="$PACKAGE_VERSION"

rm -rf "$BUILD_DIR"
mkdir -p "$INSTALL_DIR" "$SHARE_DIR" "$ROOT_DIR/Library/LaunchDaemons" "$DIST_DIR"

swiftc -swift-version 6 "$PROJECT_DIR"/Sources/*.swift -O -o "$STAGED_BINARY_PATH"
chmod 755 "$STAGED_BINARY_PATH"

"$PROJECT_DIR/build-notifier-app.sh" "$APP_PATH"

cp "$PROJECT_DIR/uninstall.sh" "$INSTALL_DIR/uninstall.sh"
chmod 755 "$INSTALL_DIR/uninstall.sh"

cp "$PROJECT_DIR/shell-integration.zsh" "$SHARE_DIR/shell-integration.zsh"
chmod 644 "$SHARE_DIR/shell-integration.zsh"

python3 "$PROJECT_DIR/render_plist.py" \
  "$PROJECT_DIR/com.ginsbc.wifi-proxy-daemon.plist.template" \
  "$PLIST_PATH" \
  "BINARY_PATH=$SYSTEM_BINARY_PATH" \
  "DOMAIN_MATCH=$DOMAIN_MATCH" \
  "STATE_PATH=$STATE_PATH" \
  "LOG_PATH=$LOG_PATH" \
  "VPN_MATCH=$VPN_MATCH" \
  "PROXY_HOST=$PROXY_HOST" \
  "PROXY_PORT=$PROXY_PORT" \
  "LISTEN_PORT=$LISTEN_PORT" \
  "PROXY_NO_PROXY=$PROXY_NO_PROXY" \
  "PROXY_NON_PROXY_HOSTS=$PROXY_NON_PROXY_HOSTS" \
  "NOTIFIER_APP=$NOTIFIER_APP_PATH"

pkgbuild \
  --root "$ROOT_DIR" \
  --scripts "$PROJECT_DIR/pkg-scripts" \
  --identifier "$SERVICE_NAME" \
  --version "$PACKAGE_VERSION" \
  --install-location / \
  "$PACKAGE_PATH"

printf 'Built package: %s\n' "$PACKAGE_PATH"