#!/usr/bin/env python3
"""Remove retired keys from every Localizable.strings table.

"Set up a model provider" is left over from the pre-fork setup offer. No Swift
code references it, and in the six translated tables its value was never filled
in — it was `""`, so anything that did resolve it would render blank. Removing
a key from only one table would break the key-set parity `make test-l10n`
checks, so the key is retired from all seven at once.

Re-running is a no-op once the key is gone.
"""
import pathlib
import re
import sys

RETIRED = ["Set up a model provider"]


def main() -> int:
    root = pathlib.Path(__file__).resolve().parents[1]
    total = 0
    for path in sorted(root.glob("app/*.lproj/Localizable.strings")):
        text = path.read_text(encoding="utf-8")
        new = text
        removed = []
        for key in RETIRED:
            pattern = re.compile(rf'^"{re.escape(key)}"\s*=\s*"[^"]*";\n', re.MULTILINE)
            new, n = pattern.subn("", new)
            if n:
                removed.append(key)
        name = path.parent.name
        if removed:
            path.write_text(new, encoding="utf-8")
            total += len(removed)
            print(f"{name}: removed {len(removed)} retired key(s)")
        else:
            print(f"{name}: nothing to remove")
    print(f"\n{total} retired key(s) removed")
    return 0


if __name__ == "__main__":
    sys.exit(main())
