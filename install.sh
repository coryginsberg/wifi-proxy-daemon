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
PROXY_HOST="${WIFI_PROXY_HOST:-proxy.cat.com}"
PROXY_PORT="${WIFI_PROXY_PORT:-80}"
LISTEN_PORT="${WIFI_PROXY_LISTEN_PORT:-3128}"
PROXY_NO_PROXY="${WIFI_PROXY_NO_PROXY:-localhost,127.0.0.1,::1,.cat.com,169.254.169.254}"
PROXY_NON_PROXY_HOSTS="${WIFI_PROXY_NON_PROXY_HOSTS:-*.cat.com|localhost|127.0.0.1|::1}"

if [[ $EUID -ne 0 ]]; then
  echo "Run install.sh with sudo." >&2
  exit 1
fi

if /usr/bin/nc -z 127.0.0.1 "$LISTEN_PORT" >/dev/null 2>&1; then
  echo "Port $LISTEN_PORT is in use; the daemon will pick the next free port." >&2
fi

mkdir -p "$INSTALL_DIR"
swiftc -swift-version 6 "$PROJECT_DIR"/Sources/*.swift -O -o "$BINARY_PATH"
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
  "BINARY_PATH=$BINARY_PATH" \
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

chmod 644 "$PLIST_PATH"
chown root:wheel "$PLIST_PATH"

launchctl bootout system "$PLIST_PATH" >/dev/null 2>&1 || true

# Clear any previously managed proxy settings so startup reconciles from a
# known-clean baseline.
"$BINARY_PATH" --reset >/dev/null 2>&1 || true
rm -f "$STATE_PATH"

if ! launchctl bootstrap system "$PLIST_PATH"; then
  echo "Failed to bootstrap $SERVICE_NAME; rolling back." >&2
  "$BINARY_PATH" --reset >/dev/null 2>&1 || true
  rm -f "$PLIST_PATH"
  exit 1
fi
launchctl enable "system/$SERVICE_NAME"
launchctl kickstart -k "system/$SERVICE_NAME"

# Every proxy setting on this machine now points at the daemon's loopback
# listener, so a daemon that came up without binding would break all networking.
# The daemon records the port it actually bound, which is not necessarily
# $LISTEN_PORT, so read it back rather than assuming.
BOUND_PORT=""
for _ in $(seq 1 40); do
  BOUND_PORT="$(/usr/bin/python3 -c "import json,sys
try: print(json.load(open('$STATE_PATH')).get('listenPort') or '')
except Exception: pass" 2>/dev/null || true)"
  if [[ -n "$BOUND_PORT" ]] && /usr/bin/nc -z 127.0.0.1 "$BOUND_PORT" >/dev/null 2>&1; then
    break
  fi
  BOUND_PORT=""
  sleep 0.25
done

if [[ -z "$BOUND_PORT" ]]; then
  echo "wifi-proxy-daemon never reported a listening port; rolling back." >&2
  launchctl bootout system "$PLIST_PATH" >/dev/null 2>&1 || true
  "$BINARY_PATH" --reset >/dev/null 2>&1 || true
  # Leaving the plist behind would re-bootstrap the failing daemon on next boot.
  rm -f "$PLIST_PATH"
  echo "Proxy settings reverted. See $LOG_PATH" >&2
  exit 1
fi

CONSOLE_USER="$(stat -f '%Su' /dev/console 2>/dev/null || true)"
if [[ -n "$CONSOLE_USER" && "$CONSOLE_USER" != "root" && "$CONSOLE_USER" != "loginwindow" && -d "$NOTIFIER_APP_PATH" ]]; then
  CONSOLE_UID="$(id -u "$CONSOLE_USER" 2>/dev/null || true)"
  [[ -n "$CONSOLE_UID" ]] && launchctl asuser "$CONSOLE_UID" /usr/bin/open -n -a "$NOTIFIER_APP_PATH" --args --request-permission >/dev/null 2>&1 || true
fi

# Run as the console user rather than root: appending as root would follow a
# symlink at ~/.zshrc, and it avoids having to chown the result back.
if [[ -n "$CONSOLE_USER" && "$CONSOLE_USER" != "root" && "$CONSOLE_USER" != "loginwindow" ]]; then
  sudo -H -u "$CONSOLE_USER" /bin/zsh -c '
    zshrc="$HOME/.zshrc"
    marker="# >>> wifi-proxy-daemon shell integration >>>"
    if [[ ! -f "$zshrc" ]] || ! grep -qF "$marker" "$zshrc"; then
      {
        printf "\n%s\n" "$marker"
        printf "%s\n" "[ -f /usr/local/share/wifi-proxy-daemon/shell-integration.zsh ] && source /usr/local/share/wifi-proxy-daemon/shell-integration.zsh"
        printf "%s\n" "# <<< wifi-proxy-daemon shell integration <<<"
      } >> "$zshrc"
    fi' || true
fi

printf 'Installed %s\n' "$SERVICE_NAME"
printf 'Binary: %s\n' "$BINARY_PATH"
printf 'Notifier: %s\n' "$NOTIFIER_APP_PATH"
printf 'Plist: %s\n' "$PLIST_PATH"
printf 'Shell integration: %s\n' "$SHELL_INTEGRATION_PATH"
printf 'Domain match: %s\n' "$DOMAIN_MATCH"
printf 'VPN match: %s\n' "$VPN_MATCH"
printf 'Upstream proxy: %s:%s\n' "$PROXY_HOST" "$PROXY_PORT"
printf 'Local listener: http://127.0.0.1:%s\n' "$BOUND_PORT"
printf '\n'
printf 'All proxy settings now point at the local listener. If networking ever\n'
printf 'stops working, restore direct access with:\n'
printf '  sudo %s --reset\n' "$BINARY_PATH"
printf 'or remove everything with:\n'
printf '  sudo %s/uninstall.sh\n' "$INSTALL_DIR"
