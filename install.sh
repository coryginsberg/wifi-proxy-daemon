#!/bin/zsh
set -euo pipefail

SERVICE_NAME="com.ginsbc.wifi-proxy-daemon"
PROJECT_DIR="${0:A:h}"
INSTALL_DIR="/usr/local/libexec/wifi-proxy-daemon"
BINARY_PATH="$INSTALL_DIR/wifi-proxy-daemon"
SHARE_DIR="/usr/local/share/wifi-proxy-daemon"
SHELL_INTEGRATION_PATH="$SHARE_DIR/shell-integration.zsh"
NOTIFIER_APP_PATH="/Applications/Utilities/WiFiProxyNotifier.app"
LEGACY_NOTIFIER_APP_PATH="/Applications/WiFiProxyNotifier.app"
PLIST_PATH="/Library/LaunchDaemons/$SERVICE_NAME.plist"
LOG_PATH="/var/log/wifi-proxy-daemon.log"
STATE_PATH="/var/run/wifi-proxy-daemon.state"
DOMAIN_MATCH="${WIFI_PROXY_DOMAIN_MATCH:-cat.com}"
VPN_MATCH="${WIFI_PROXY_VPN_MATCH:-Cisco Secure Client}"
PROXY_URL="${WIFI_PROXY_URL:-http://proxy.cat.com:80}"
PROXY_HOST="${WIFI_PROXY_HOST:-proxy.cat.com}"
PROXY_PORT="${WIFI_PROXY_PORT:-80}"
PROXY_NO_PROXY="${WIFI_PROXY_NO_PROXY:-localhost,127.0.0.1,::1,.cat.com,169.254.169.254}"
PROXY_NON_PROXY_HOSTS="${WIFI_PROXY_NON_PROXY_HOSTS:-*.cat.com|localhost|127.0.0.1|::1}"

if [[ $EUID -ne 0 ]]; then
  echo "Run install.sh with sudo." >&2
  exit 1
fi

mkdir -p "$INSTALL_DIR"
swiftc "$PROJECT_DIR/main.swift" -o "$BINARY_PATH"
chmod 755 "$BINARY_PATH"
chown root:wheel "$BINARY_PATH"

rm -rf "$LEGACY_NOTIFIER_APP_PATH"
"$PROJECT_DIR/build-notifier-app.sh" "$NOTIFIER_APP_PATH"
chown -R root:wheel "$NOTIFIER_APP_PATH"

cp "$PROJECT_DIR/uninstall.sh" "$INSTALL_DIR/uninstall.sh"
chmod 755 "$INSTALL_DIR/uninstall.sh"
chown root:wheel "$INSTALL_DIR/uninstall.sh"

mkdir -p "$SHARE_DIR"
cp "$PROJECT_DIR/shell-integration.zsh" "$SHELL_INTEGRATION_PATH"
chmod 644 "$SHELL_INTEGRATION_PATH"
chown root:wheel "$SHELL_INTEGRATION_PATH"

python3 "$PROJECT_DIR/render_plist.py" \
  "$PROJECT_DIR/com.ginsbc.wifi-proxy-daemon.plist.template" \
  "$PLIST_PATH" \
  "$BINARY_PATH" \
  "$DOMAIN_MATCH" \
  "$STATE_PATH" \
  "$LOG_PATH" \
  "$VPN_MATCH" \
  "$PROXY_URL" \
  "$PROXY_HOST" \
  "$PROXY_PORT" \
  "$PROXY_NO_PROXY" \
  "$PROXY_NON_PROXY_HOSTS" \
  "$NOTIFIER_APP_PATH"

chmod 644 "$PLIST_PATH"
chown root:wheel "$PLIST_PATH"

launchctl bootout system "$PLIST_PATH" >/dev/null 2>&1 || true

# Force a clean baseline on reinstall before the daemon starts watching state
# again. This clears any previously managed proxy settings and then drops the
# persisted state so startup always reconciles from scratch.
WIFI_PROXY_TEST_NETWORK="" WIFI_PROXY_TEST_VPN="" "$BINARY_PATH" --once >/dev/null 2>&1 || true
rm -f "$STATE_PATH"

launchctl bootstrap system "$PLIST_PATH"
launchctl enable "system/$SERVICE_NAME"
launchctl kickstart -k "system/$SERVICE_NAME"

CONSOLE_USER="$(stat -f '%Su' /dev/console 2>/dev/null || true)"
if [[ -n "$CONSOLE_USER" && "$CONSOLE_USER" != "root" && "$CONSOLE_USER" != "loginwindow" && -d "$NOTIFIER_APP_PATH" ]]; then
  CONSOLE_UID="$(id -u "$CONSOLE_USER")"
  launchctl asuser "$CONSOLE_UID" /usr/bin/open -n -a "$NOTIFIER_APP_PATH" --args --request-permission >/dev/null 2>&1 || true
fi

# Register the restart-proxy shell integration in the console user's .zshrc.
if [[ -n "$CONSOLE_USER" && "$CONSOLE_USER" != "root" && "$CONSOLE_USER" != "loginwindow" ]]; then
  USER_HOME="$(dscl . -read "/Users/$CONSOLE_USER" NFSHomeDirectory 2>/dev/null | awk '{print $2}')"
  [[ -z "$USER_HOME" ]] && USER_HOME="/Users/$CONSOLE_USER"
  ZSHRC="$USER_HOME/.zshrc"
  MARKER="# >>> wifi-proxy-daemon shell integration >>>"
  if [[ ! -f "$ZSHRC" ]] || ! grep -qF "$MARKER" "$ZSHRC"; then
    {
      printf '\n%s\n' "$MARKER"
      printf '%s\n' '[ -f /usr/local/share/wifi-proxy-daemon/shell-integration.zsh ] && source /usr/local/share/wifi-proxy-daemon/shell-integration.zsh'
      printf '%s\n' "# <<< wifi-proxy-daemon shell integration <<<"
    } >> "$ZSHRC"
    chown "$CONSOLE_USER" "$ZSHRC" 2>/dev/null || true
  fi
fi

printf 'Installed %s\n' "$SERVICE_NAME"
printf 'Binary: %s\n' "$BINARY_PATH"
printf 'Notifier: %s\n' "$NOTIFIER_APP_PATH"
printf 'Plist: %s\n' "$PLIST_PATH"
printf 'Shell integration: %s\n' "$SHELL_INTEGRATION_PATH"
printf 'Domain match: %s\n' "$DOMAIN_MATCH"
printf 'VPN match: %s\n' "$VPN_MATCH"
printf 'Proxy URL: %s\n' "$PROXY_URL"
