#!/bin/zsh
set -euo pipefail

SERVICE_NAME="com.ginsbc.wifi-proxy-daemon"
INSTALL_DIR="/usr/local/libexec/wifi-proxy-daemon"
NOTIFIER_APP_PATH="/Applications/WiFiProxyNotifier.app"
PLIST_PATH="/Library/LaunchDaemons/$SERVICE_NAME.plist"

if [[ $EUID -ne 0 ]]; then
  echo "Run uninstall.sh with sudo." >&2
  exit 1
fi

launchctl bootout system "$PLIST_PATH" >/dev/null 2>&1 || true
rm -f "$PLIST_PATH"
rm -rf "$INSTALL_DIR"
rm -rf "$NOTIFIER_APP_PATH"
rm -rf /usr/local/share/wifi-proxy-daemon
rm -f /var/run/wifi-proxy-daemon.state

# Remove the restart-proxy shell integration from the console user's .zshrc.
CONSOLE_USER="$(stat -f '%Su' /dev/console 2>/dev/null || true)"
if [[ -n "$CONSOLE_USER" && "$CONSOLE_USER" != "root" && "$CONSOLE_USER" != "loginwindow" ]]; then
  USER_HOME="$(dscl . -read "/Users/$CONSOLE_USER" NFSHomeDirectory 2>/dev/null | awk '{print $2}')"
  [[ -z "$USER_HOME" ]] && USER_HOME="/Users/$CONSOLE_USER"
  ZSHRC="$USER_HOME/.zshrc"
  if [[ -f "$ZSHRC" ]]; then
    /usr/bin/sed -i '' '/# >>> wifi-proxy-daemon shell integration >>>/,/# <<< wifi-proxy-daemon shell integration <<</d' "$ZSHRC"
  fi
fi

printf 'Removed %s\n' "$SERVICE_NAME"
