#!/usr/bin/env python3
import plistlib
import sys
from pathlib import Path

# Placeholders are passed as NAME=VALUE pairs rather than positionally. The
# previous positional form took fourteen arguments, which made it easy to add a
# daemon setting and silently never wire it through.
PLACEHOLDERS = {
    "BINARY_PATH",
    "DOMAIN_MATCH",
    "STATE_PATH",
    "LOG_PATH",
    "VPN_MATCH",
    "PROXY_HOST",
    "PROXY_PORT",
    "LISTEN_PORT",
    "PROXY_NO_PROXY",
    "PROXY_NON_PROXY_HOSTS",
    "NOTIFIER_APP",
}


def main() -> int:
    if len(sys.argv) < 3:
        print(
            "usage: render_plist.py TEMPLATE OUTPUT NAME=VALUE...\n"
            "  names: " + ", ".join(sorted(PLACEHOLDERS)),
            file=sys.stderr,
        )
        return 1

    template_path, output_path = sys.argv[1], sys.argv[2]

    values = {}
    for argument in sys.argv[3:]:
        name, separator, value = argument.partition("=")
        if not separator:
            print(f"render_plist.py: expected NAME=VALUE, got {argument!r}", file=sys.stderr)
            return 1
        if name not in PLACEHOLDERS:
            print(f"render_plist.py: unknown placeholder {name!r}", file=sys.stderr)
            return 1
        values[name] = value

    missing = PLACEHOLDERS - values.keys()
    if missing:
        print(f"render_plist.py: missing values for {', '.join(sorted(missing))}", file=sys.stderr)
        return 1

    rendered_text = Path(template_path).read_text(encoding="utf-8")
    for name, value in values.items():
        rendered_text = rendered_text.replace(f"__{name}__", value)

    leftover = [name for name in PLACEHOLDERS if f"__{name}__" in rendered_text]
    if leftover:
        print(f"render_plist.py: template still contains {', '.join(sorted(leftover))}", file=sys.stderr)
        return 1

    plist_data = plistlib.loads(rendered_text.encode("utf-8"))
    with open(output_path, "wb") as handle:
        plistlib.dump(plist_data, handle, sort_keys=False)

    return 0


if __name__ == "__main__":
    raise SystemExit(main())
