# Wi-Fi Proxy Daemon

This package installs a macOS `launchd` daemon that watches network changes.

Behavior:

- When the active network's DNS domain matches `cat.com`, it enables the configured macOS and shell proxy settings.
- When a connected VPN name matches `Cisco Secure Client`, it also enables the configured proxy settings.
- When the proxy is enabled, it posts a macOS notification to the logged-in user.
- When neither a matching network domain nor a matching VPN connection is active, it disables those proxy settings.
- When the proxy is disabled, it posts a macOS notification to the logged-in user.
- On daemon startup, including immediately after `./install.sh` and on boot, it reconciles the current network and VPN state before waiting for future network changes.

> NOTE: Detection uses the DHCP/resolver DNS domain rather than the Wi-Fi SSID. Recent macOS releases gate the SSID behind Location Services, which a root LaunchDaemon cannot obtain, so the SSID is unreadable (it reports `<redacted>`). The DNS domain is readable from a root context and identifies the corporate network reliably, including over Ethernet and VPN.

Proxy propagation:

- macOS system web and HTTPS proxy settings are toggled for enabled network services, which covers browsers and apps that follow system proxy configuration.
- User `launchctl` environment variables are updated for newly launched GUI apps such as VS Code, Zed, Terminal, and iTerm.
- The daemon writes `~/.config/wifi-proxy-daemon/proxy-env.zsh`, which new `zsh` shells can source to pick up proxy settings.
- Global git `http.proxy` and `https.proxy` are set and unset along with the proxy state.

## Files

- `main.swift`: Swift daemon that subscribes to macOS network change notifications.
- `notification_helper.swift`: Swift notification helper app used for user-visible system notifications and permission prompts.
- `install.sh`: Builds and installs the daemon as a system LaunchDaemon.
- `uninstall.sh`: Removes the LaunchDaemon and installed binary.
- `build-pkg.sh`: Builds a macOS installer package.
- `com.ginsbc.wifi-proxy-daemon.plist.template`: LaunchDaemon template.

## Install

```sh
cd ~/wifi-proxy-daemon
sudo ./install.sh
```

The install script also installs `WiFiProxyNotifier.app`, restarts the LaunchDaemon, and best-effort requests notification permission for the currently logged-in user.

If you want to match a different network domain:

```sh
sudo WIFI_PROXY_DOMAIN_MATCH=example.com ./install.sh
```

If your VPN service should be matched by a different name fragment:

```sh
sudo WIFI_PROXY_VPN_MATCH='Your VPN Name' ./install.sh
```

If the proxy host, port, or bypass list need to change:

```sh
sudo WIFI_PROXY_URL='http://proxy.cat.com:80' \
     WIFI_PROXY_HOST='proxy.cat.com' \
     WIFI_PROXY_PORT='80' \
     WIFI_PROXY_NO_PROXY='localhost,.cat.com,169.254.169.254' \
     WIFI_PROXY_NON_PROXY_HOSTS='*.cat.com|localhost' \
     ./install.sh
```

## Uninstall

```sh
cd ~/wifi-proxy-daemon
sudo ./uninstall.sh
```

## Package

Build an installer package with the current configuration baked in:

```sh
cd ~/wifi-proxy-daemon
./build-pkg.sh
```

The package is written to `dist/WiFiProxyDaemon-1.0.0.pkg` by default. Override `PACKAGE_VERSION` or any `WIFI_PROXY_*` variables when building to bake in different defaults.

On package install, the postinstall script bootstraps the LaunchDaemon immediately and best-effort requests notification permission for the logged-in user.

## Logs

- Daemon log: `/var/log/wifi-proxy-daemon.log`
- State file: `/var/run/wifi-proxy-daemon.state`

## Shell Integration

New `zsh` sessions should source `~/.config/wifi-proxy-daemon/proxy-env.zsh` during shell startup. Existing shells keep their current environment until you start a new tab or run `exec zsh`.

## Notification Permissions

Notification permission prompting only works when a real user session is active at install time. If no user is logged in, or the prompt is dismissed, install still succeeds and the notifier app will request permission again the first time it tries to show a notification.
