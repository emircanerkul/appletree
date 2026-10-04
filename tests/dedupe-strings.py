#!/usr/bin/env python3
"""Drop duplicate keys from every Localizable.strings table.

Duplicate keys are invalid in a .strings table: which entry wins is undefined,
and a translator editing one copy sees no change. They accumulated because
localize-planner.py appends a key whenever `"<key>" =` is absent from the text,
and a run that lost/renamed an entry re-appended it rather than updating it.

The first occurrence of a key is kept (it is the one a translator is most
likely to have already reviewed); later duplicates are removed.

Everything that is not a key/value pair — the /* ... */ comment blocks and
blank lines — is preserved as-is, in order.
"""
import pathlib
import re
import sys

PAIR = re.compile(r'^"((?:[^"\\]|\\.)*)"\s*=\s*"(?:[^"\\]|\\.)*";\s*$')


def dedupe(text: str) -> tuple[str, list[str]]:
    """Return (new_text, removed_keys). Keeps the first occurrence in order."""
    lines = text.split("\n")
    seen: set[str] = set()
    kept: list[str] = []
    removed: list[str] = []
    for line in lines:
        m = PAIR.match(line.strip())
        if m:
            key = m.group(1)
            if key in seen:
                removed.append(key)
                continue
            seen.add(key)
        kept.append(line)
    return "\n".join(kept), removed


def main() -> int:
    root = pathlib.Path(__file__).resolve().parents[1]
    total = 0
    for path in sorted(root.glob("app/*.lproj/Localizable.strings")):
        text = path.read_text(encoding="utf-8")
        new, removed = dedupe(text)
        name = path.parent.name
        if removed:
            path.write_text(new, encoding="utf-8")
            total += len(removed)
            print(f"{name}: removed {len(removed)} duplicate key(s)")
            for key in removed:
                print(f"    - {key[:90]}")
        else:
            print(f"{name}: no duplicates")
    print(f"\n{total} duplicate key(s) removed across 7 tables")
    return 0


if __name__ == "__main__":
    sys.exit(main())
