#!/usr/bin/env python3
"""Validate a JSONC file (JSON with `//` comments and trailing commas).

Used by install.sh before it rewrites
~/.config/omarchy/extensions/omarchy-menu.jsonc, and by CI on the block that
`devstack <project> menu` generates. Prints the parsed JSON on stdout and exits
0 when the file is valid; on error prints the reason on stderr and exits 1.

The comment stripper only drops lines that *start* with `//`, so URLs inside
string values survive untouched.
"""

import json
import re
import sys


def strip(raw: str) -> str:
    without_comments = re.sub(r"^\s*//[^\n]*\n?", "", raw, flags=re.M)
    return re.sub(r",(\s*[}\]])", r"\1", without_comments)


def main() -> int:
    if len(sys.argv) != 2:
        print("usage: jsonc-check.py <file>", file=sys.stderr)
        return 2
    path = sys.argv[1]
    try:
        with open(path, encoding="utf-8") as handle:
            data = json.loads(strip(handle.read()))
    except Exception as error:  # noqa: BLE001 - any parse failure is the same answer
        print(f"{path}: {error}", file=sys.stderr)
        return 1
    json.dump(data, sys.stdout)
    sys.stdout.write("\n")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
