#!/usr/bin/env python3
import plistlib
import sys
from pathlib import Path


def main() -> int:
    if len(sys.argv) != 14:
        print(
            "usage: render_plist.py template output binary domain_match state_path log_path vpn_match proxy_url proxy_host proxy_port proxy_no_proxy proxy_non_proxy_hosts notifier_app",
            file=sys.stderr,
        )
        return 1

    _, template_path, output_path, binary_path, domain_match, state_path, log_path, vpn_match, proxy_url, proxy_host, proxy_port, proxy_no_proxy, proxy_non_proxy_hosts, notifier_app = sys.argv
    template_text = Path(template_path).read_text(encoding="utf-8")
    rendered_text = (
        template_text.replace("__BINARY_PATH__", binary_path)
        .replace("__DOMAIN_MATCH__", domain_match)
        .replace("__STATE_PATH__", state_path)
        .replace("__LOG_PATH__", log_path)
        .replace("__VPN_MATCH__", vpn_match)
        .replace("__PROXY_URL__", proxy_url)
        .replace("__PROXY_HOST__", proxy_host)
        .replace("__PROXY_PORT__", proxy_port)
        .replace("__PROXY_NO_PROXY__", proxy_no_proxy)
        .replace("__PROXY_NON_PROXY_HOSTS__", proxy_non_proxy_hosts)
        .replace("__NOTIFIER_APP__", notifier_app)
    )

    plist_data = plistlib.loads(rendered_text.encode("utf-8"))
    with open(output_path, "wb") as handle:
        plistlib.dump(plist_data, handle, sort_keys=False)

    return 0


if __name__ == "__main__":
    raise SystemExit(main())
