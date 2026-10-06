#!/usr/bin/env python3
"""Check every Localizable.strings table for structural problems.

Fails (exit 1) on:
  - a duplicate key within a table (undefined which entry wins);
  - a key present in one table but not another (a string that silently
    falls back to English in some language);
  - an empty value.

Also reports keys referenced from app/*.swift that no table defines, which is
how the Settings tab labels stayed untranslated. References are collected from
two kinds of surface: `String(localized:)` and the SwiftUI initialisers and
modifiers whose first argument is a LocalizedStringKey when it is a literal —
`Text("…")`, `Button("…")`, `.help("…")` and friends look the key up in the
same tables.

The literal does NOT have to sit directly after the call's `(`. A key chosen by
a ternary or built by a concatenation is looked up just the same:

    .help(ready ? "Show the panel" : "Scan first — the panel needs a scan")

An earlier version of this checker required the quote immediately after the
opening `(`, so that form was invisible and a key defined in no table was
reported as fine. Each call's whole FIRST argument expression is scanned now,
and every string literal in it is a candidate key. Later arguments are
deliberately not scanned: they carry SF Symbol names, JSON keys and file paths
that were never keys, and treating them as keys would fail on literals the app
never localises. `Text(verbatim: "…")` is excluded, because it renders its
literal in every locale.
"""
import pathlib
import re
import sys

PAIR = re.compile(r'^\s*"((?:[^"\\]|\\.)*)"\s*=\s*"((?:[^"\\]|\\.)*)"\s*;', re.M)

# Every surface that asks a .strings table for a key when its first argument
# is a literal. Only the opening is matched; the argument expression itself is
# walked by first_argument_keys, so a literal behind a ternary is still found.
SURFACE = re.compile(
    r'(?:\bString\(localized:'
    r'|\b(?:Text|Button|Label|Toggle|TextField|SecureField|Picker)\('
    r'|\.(?:confirmationDialog|alert|help)\()'
)

# `Text(verbatim: "…")` and friends render the literal itself in every locale,
# so their strings are not keys. Matched on the text just before the quote.
VERBATIM = re.compile(r'verbatim\s*:\s*$')

# Anything without a letter is not a translatable sentence: a bare `%@`, a
# punctuation glyph (`•`) or a numeric format is spelled the same everywhere.
LETTER = re.compile(r'[^\W\d_]', re.UNICODE)

# Keys that are deliberately never translated: the app name, a placeholder
# and a glyph carry no words, and SwiftUI renders the literal itself in every
# locale. Everything else the app references must be in the tables.
UNTRANSLATED = {"AppleTree", "gpt-4o-mini", "…"}


def read_table(path: pathlib.Path) -> list[tuple[str, str]]:
    return PAIR.findall(path.read_text(encoding="utf-8"))


def read_string_literal(src: str, start: int) -> tuple[str, int] | None:
    """Read the Swift string literal opening at src[start] (a quote).

    Returns (text between the quotes, index just past the closing quote), or
    None when the construct does not close on this line. An interpolation is
    scanned with balanced parens and its own string literals are skipped
    recursively, so a quote inside one — `\\(String(format: "%d", n))` — does
    not end the literal early.
    """
    out: list[str] = []
    i = start + 1
    while i < len(src):
        c = src[i]
        if c == "\\":
            if i + 1 < len(src) and src[i + 1] == "(":
                depth, j = 0, i + 1
                while j < len(src):
                    cj = src[j]
                    if cj == '"':
                        nested = read_string_literal(src, j)
                        if nested is None:
                            return None
                        j = nested[1]
                        continue
                    if cj == "(":
                        depth += 1
                    elif cj == ")":
                        depth -= 1
                        if depth == 0:
                            break
                    j += 1
                if depth != 0:
                    return None
                out.append(src[i:j + 1])
                i = j + 1
                continue
            out.append(src[i:i + 2])
            i += 2
            continue
        if c == '"':
            return "".join(out), i + 1
        if c == "\n":
            return None
        out.append(c)
        i += 1
    return None


# An interpolated expression that Swift formats as an INTEGER, whose
# localization key is therefore `%lld` and not `%@`. Only the shapes this
# project writes are matched: a bare `x.count`, optionally minus a literal.
INT_INTERPOLATION = re.compile(r"^[A-Za-z_][\w.]*\.count(\s*-\s*\d+)?$")

def interpolations_to_format(raw: str) -> str:
    """Spell an interpolation the way the table's key does.
    Swift picks the specifier from the interpolated value's TYPE: a `String`
    renders as `%@`, an `Int` as `%lld`. Rewriting EVERY interpolation to `%@`
    masked a real bug: the batch dialog wrote `"\(items.count) items"`, whose
    key is `"%lld items"`, while all seven tables defined `"%@ items"`. The
    checker called those tables complete while six translations silently fell
    back to English.
    """
    out: list[str] = []
    i = 0
    while i < len(raw):
        if raw[i] == "\\" and i + 1 < len(raw) and raw[i + 1] == "(":
            depth, j = 0, i + 1
            while j < len(raw):
                c = raw[j]
                if c == '"':
                    j += 1
                    while j < len(raw) and raw[j] != '"':
                        j += 2 if raw[j] == "\\" else 1
                elif c == "(":
                    depth += 1
                elif c == ")":
                    depth -= 1
                    if depth == 0:
                        break
                j += 1
            expr = raw[i + 2:j].strip()
            out.append("%lld" if INT_INTERPOLATION.match(expr) else "%@")
            i = j + 1
        else:
            out.append(raw[i])
            i += 1
    return "".join(out)


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


def first_argument_keys(src: str, open_paren: int) -> list[str]:
    """Every string literal in the first argument that starts at open_paren.

    The argument is walked rather than pattern-matched, so the literal may be
    behind a ternary, a `+`, or anything else. Scanning stops at the comma that
    separates the first argument from the second, or at the call's own `)`.
    A nested call is stepped over whole: `Text(String(format: "%.1f s", …))`
    passes `"%.1f s"` to `String`, not to `Text`, so it is not a key — the
    tables never contained it. Comments are skipped too, so a quote in one is
    not mistaken for a literal.
    """
    keys: list[str] = []
    i = open_paren + 1
    while i < len(src):
        c = src[i]
        if c == "/" and src.startswith("//", i):
            j = src.find("\n", i)
            i = len(src) if j == -1 else j + 1
            continue
        if c == "/" and src.startswith("/*", i):
            j = src.find("*/", i + 2)
            i = len(src) if j == -1 else j + 2
            continue
        if c == ",":
            break
        if c == ")":
            break
        if c == "(":
            i = end_of_parens(src, i)
            continue
        if c == '"':
            quote = i
            if src.startswith('"""', i):
                end = src.find('"""', i + 3)
                if end == -1:
                    break
                raw, i = src[i + 3:end], end + 3
            else:
                literal = read_string_literal(src, i)
                if literal is None:
                    i += 1
                    continue
                raw, i = literal
            if VERBATIM.search(src[max(0, quote - 12):quote]):
                continue
            key = unescape_swift(interpolations_to_format(raw))
            if key.strip() and key not in UNTRANSLATED and LETTER.search(key):
                keys.append(key)
            continue
        i += 1
    return keys


def end_of_parens(src: str, open_paren: int) -> int:
    """Index just past the `)` that closes the `(` at open_paren."""
    depth, i = 0, open_paren
    while i < len(src):
        c = src[i]
        if c == '"':
            if src.startswith('"""', i):
                end = src.find('"""', i + 3)
                if end == -1:
                    return len(src)
                i = end + 3
                continue
            literal = read_string_literal(src, i)
            i = literal[1] if literal else i + 1
            continue
        if c == "(":
            depth += 1
        elif c == ")":
            depth -= 1
            if depth == 0:
                return i + 1
        i += 1
    return len(src)


def referenced_keys(root: pathlib.Path) -> set[str]:
    """Keys the app asks a table for, from every localising surface."""
    keys: set[str] = set()
    for f in root.glob("app/*.swift"):
        src = f.read_text(encoding="utf-8")
        for m in SURFACE.finditer(src):
            keys.update(first_argument_keys(src, m.end() - 1))
    return keys


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
    undefined = sorted(k for k in used if k not in reference)
    print(f"\nKeys referenced from app/*.swift: {len(used)}")
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
