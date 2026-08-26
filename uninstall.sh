#!/bin/zsh
set -euo pipefail

SERVICE_NAME="com.ginsbc.wifi-proxy-daemon"
INSTALL_DIR="/usr/local/libexec/wifi-proxy-daemon"
BINARY_PATH="$INSTALL_DIR/wifi-proxy-daemon"
NOTIFIER_APP_PATH="/Applications/Utilities/WiFiProxyNotifier.app"
LEGACY_NOTIFIER_APP_PATH="/Applications/WiFiProxyNotifier.app"
PLIST_PATH="/Library/LaunchDaemons/$SERVICE_NAME.plist"

if [[ $EUID -ne 0 ]]; then
  echo "Run uninstall.sh with sudo." >&2
  exit 1
fi

launchctl bootout system "$PLIST_PATH" >/dev/null 2>&1 || true

CONSOLE_USER="$(stat -f '%Su' /dev/console 2>/dev/null || true)"
if [[ "$CONSOLE_USER" == "root" || "$CONSOLE_USER" == "loginwindow" ]]; then
  CONSOLE_USER=""
fi

# Every proxy setting on this machine points at the daemon's loopback listener,
# which is about to stop existing. Revert before deleting anything, or the user
# is left with no working network path.
REVERTED=0
if [[ -x "$BINARY_PATH" ]] && "$BINARY_PATH" --reset >/dev/null 2>&1; then
  REVERTED=1
fi

# The daemon is the only thing that knows every surface it touched, so falling
# back by hand is best-effort. It still beats stranding the machine.
if [[ $REVERTED -ne 1 ]]; then
  echo "Daemon reset failed; reverting proxy settings manually." >&2

  networksetup -listallnetworkservices 2>/dev/null \
    | tail -n +2 \
    | sed 's/^\*//' \
    | while IFS= read -r service; do
        [[ -z "$service" ]] && continue
        networksetup -setwebproxystate "$service" off >/dev/null 2>&1 || true
        networksetup -setsecurewebproxystate "$service" off >/dev/null 2>&1 || true
        networksetup -setproxybypassdomains "$service" Empty >/dev/null 2>&1 || true
      done || true

  if [[ -n "$CONSOLE_USER" ]]; then
    # Unguarded this would abort the script under `set -e`, stranding git and
    # the launchd environment still pointing at a listener that is going away.
    CONSOLE_UID="$(id -u "$CONSOLE_USER" 2>/dev/null || true)"
    # Keep in sync with launchdEnvironmentEntries in main.swift.
    for name in ALL_PROXY all_proxy HTTP_PROXY http_proxy HTTPS_PROXY https_proxy \
                NO_PROXY no_proxy JAVA_OPTS java_opts ES_JAVA_OPTS SBT_OPTS sbt_opts; do
      [[ -n "$CONSOLE_UID" ]] && launchctl asuser "$CONSOLE_UID" /bin/launchctl unsetenv "$name" >/dev/null 2>&1 || true
    done
    sudo -H -u "$CONSOLE_USER" git config --global --unset http.proxy >/dev/null 2>&1 || true
    sudo -H -u "$CONSOLE_USER" git config --global --unset https.proxy >/dev/null 2>&1 || true
  fi
fi

rm -f "$PLIST_PATH"
rm -rf "$INSTALL_DIR"
rm -rf "$NOTIFIER_APP_PATH" || true
rm -rf "$LEGACY_NOTIFIER_APP_PATH" || true
rm -rf /usr/local/share/wifi-proxy-daemon || true
rm -f /var/run/wifi-proxy-daemon.state

# Remove the restart-proxy shell integration, and the env file that older
# versions generated before the daemon stopped writing one.
if [[ -n "$CONSOLE_USER" ]]; then
  USER_HOME="$(dscl . -read "/Users/$CONSOLE_USER" NFSHomeDirectory 2>/dev/null \
    | tr '\n' ' ' | sed -n 's/^NFSHomeDirectory: *//p' | sed 's/ *$//')"
  [[ -z "$USER_HOME" ]] && USER_HOME="/Users/$CONSOLE_USER"
  ZSHRC="$USER_HOME/.zshrc"
  if [[ -f "$ZSHRC" ]]; then
    /usr/bin/sed -i '' '/# >>> wifi-proxy-daemon shell integration >>>/,/# <<< wifi-proxy-daemon shell integration <<</d' "$ZSHRC"
  fi
  rm -rf "$USER_HOME/.config/wifi-proxy-daemon"
fi

printf 'Removed %s\n' "$SERVICE_NAME"
printf 'Open a new shell so the proxy environment variables are cleared.\n'
