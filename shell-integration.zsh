# Managed by wifi-proxy-daemon. Provides the `restart-proxy` command.

# Restart the wifi-proxy-daemon and notify the current proxy state when done.
function restart-proxy {
    local service="com.ginsbc.wifi-proxy-daemon"
    local state_file="/var/run/wifi-proxy-daemon.state"
    local notifier="/Applications/WiFiProxyNotifier.app"

    echo "Restarting ${service}..."

    local prev_mtime
    prev_mtime="$(stat -f %m "$state_file" 2>/dev/null || echo 0)"

    if ! sudo launchctl kickstart -k "system/${service}"; then
        echo "restart-proxy: failed to restart ${service}" >&2
        return 1
    fi

    # Wait for the daemon to re-evaluate and rewrite its state file.
    local attempt=0 cur_mtime
    while (( attempt < 40 )); do
        cur_mtime="$(stat -f %m "$state_file" 2>/dev/null || echo 0)"
        [[ "$cur_mtime" != "$prev_mtime" ]] && break
        sleep 0.25
        (( attempt++ ))
    done

    local json enabled network
    json="$(cat "$state_file" 2>/dev/null)"
    enabled="$(print -r -- "$json" | sed -n 's/.*"wasProxyEnabled":\([a-z]*\).*/\1/p')"
    network="$(print -r -- "$json" | sed -n 's/.*"lastNetwork":"\([^"]*\)".*/\1/p')"

    local subtitle body
    if [[ "$enabled" == "true" ]]; then
        subtitle="Proxy enabled"
        if [[ -n "$network" ]]; then
            body="Active on ${network}"
        else
            body="Proxy is currently on"
        fi
    elif [[ "$enabled" == "false" ]]; then
        subtitle="Proxy disabled"
        body="Proxy is currently off"
    else
        subtitle="Proxy state unknown"
        body="Could not read daemon state"
    fi

    echo "restart-proxy: ${subtitle}${network:+ (${network})}"

    if [[ -d "$notifier" ]]; then
        open -n -a "$notifier" --args --notify \
            --title "Wi-Fi Proxy" \
            --subtitle "$subtitle" \
            --body "$body" >/dev/null 2>&1
    fi
}
