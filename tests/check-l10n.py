#!/usr/bin/env python3
"""Check every Localizable.strings table for structural problems.

Fails (exit 1) on:
  - a duplicate key within a table (undefined which entry wins);
  - a key present in one table but not another (a string that silently
    falls back to English in some language);
  - an empty value.

Also reports keys referenced with String(localized:) in app/*.swift that no
table defines, which is how the Settings tab labels stayed untranslated.
"""
import glob
import os
import pathlib
import re
import sys

PAIR = re.compile(r'^\s*"((?:[^"\\]|\\.)*)"\s*=\s*"((?:[^"\\]|\\.)*)"\s*;', re.M)


def read_table(path: pathlib.Path) -> list[tuple[str, str]]:
    return PAIR.findall(path.read_text(encoding="utf-8"))


def referenced_keys(root: pathlib.Path) -> set[str]:
    """Keys asked for via String(localized:"..."), with interpolations as %@."""
    keys: set[str] = set()
    for f in root.glob("app/*.swift"):
        src = f.read_text(encoding="utf-8")
        for m in re.finditer(r'String\(localized:\s*"((?:[^"\\]|\\.)*)"', src):
            lit = m.group(1)
            # Replace each \( ... ) interpolation with %@, respecting nesting.
            out, i = [], 0
            while i < len(lit):
                if lit[i] == "\\" and i + 1 < len(lit) and lit[i + 1] == "(":
                    depth, j = 0, i + 1
                    while j < len(lit):
                        c = lit[j]
                        if c == '"':
                            j += 1
                            while j < len(lit) and lit[j] != '"':
                                j += 2 if lit[j] == "\\" else 1
                        elif c == "(":
                            depth += 1
                        elif c == ")":
                            depth -= 1
                            if depth == 0:
                                break
                        j += 1
                    out.append("%@")
                    i = j + 1
                else:
                    out.append(lit[i])
                    i += 1
            keys.add("".join(out))
    return keys


def unescape_swift(literal: str) -> str:
    """Resolve the Swift escapes that also appear in .strings keys.

    Swift writes typographic quotes as `\\u{201C}`, while a .strings file holds
    the character itself. Comparing them raw reported a false mismatch, so both
    sides are normalised to the same characters.
    """
    out, i = [], 0
    while i < len(literal):
        if literal[i] == "\\" and literal.startswith("\\u{", i):
            end = literal.find("}", i)
            if end != -1:
                try:
                    out.append(chr(int(literal[i + 3:end], 16)))
                    i = end + 1
                    continue
                except ValueError:
                    pass
        out.append(literal[i])
        i += 1
    return "".join(out)


def main() -> int:
    root = pathlib.Path(__file__).resolve().parents[1]
    paths = sorted(root.glob("app/*.lproj/Localizable.strings"))
    if not paths:
        print("no Localizable.strings tables found")
        return 1

    tables = {p.parent.name.replace(".lproj", ""): read_table(p) for p in paths}
    problems = 0

    print(f"{len(tables)} tables\n")
    for name, pairs in tables.items():
        keys = [k for k, _ in pairs]
        dupes = sorted({k for k in keys if keys.count(k) > 1})
        empty = sorted(k for k, v in pairs if not v)
        flags = []
        if dupes:
            flags.append(f"{len(dupes)} duplicate key(s): {dupes[:3]}")
        if empty:
            flags.append(f"{len(empty)} empty value(s)")
        print(f"  {name:9} {len(pairs):4} keys   " + ("; ".join(flags) if flags else "ok"))
        problems += len(dupes) + len(empty)

    reference = set(k for k, _ in tables["en"]) if "en" in tables else set()
    print()
    for name, pairs in tables.items():
        keys = {k for k, _ in pairs}
        missing = reference - keys
        extra = keys - reference
        if missing or extra:
            problems += len(missing) + len(extra)
            print(f"  {name}: {len(missing)} key(s) missing vs en, {len(extra)} extra")
            for k in sorted(missing)[:5]:
                print(f"      missing: {k[:80]}")
            for k in sorted(extra)[:5]:
                print(f"      extra:   {k[:80]}")

    used = referenced_keys(root)
    undefined = sorted(k for k in used if unescape_swift(k) not in reference and k.strip())
    print(f"\nString(localized:) keys used in app/*.swift: {len(used)}")
    if undefined:
        problems += len(undefined)
        print(f"  {len(undefined)} not defined in any table:")
        for k in undefined:
            print(f"      - {k[:80]}")
    else:
        print("  all defined in the tables")

    print()
    if problems:
        print(f"FAIL: {problems} problem(s)")
        return 1
    print("PASS: key sets identical, no duplicates, every referenced key defined")
    return 0


if __name__ == "__main__":
    sys.exit(main())
