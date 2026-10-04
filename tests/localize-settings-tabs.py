#!/usr/bin/env python3
"""Add the Settings tab labels to every Localizable.strings table.

Main.swift asks for these two via String(localized:) but neither key was ever
added, so the Settings window's tab names stayed English in all 7 languages
while every other user-visible string was translated.

Translations follow the terminology already used in each table (the "Clean Up
planner" / "Language" rows), so the vocabulary stays consistent per language.
Re-running is a no-op for keys already present.
"""
import pathlib
import re
import sys

KEYS = {
    "en": {
        "General": "General",
        "Model Providers": "Model Providers",
    },
    "tr": {
        "General": "Genel",
        "Model Providers": "Model Sağlayıcıları",
    },
    "de": {
        "General": "Allgemein",
        "Model Providers": "Modellanbieter",
    },
    "fr": {
        "General": "Général",
        "Model Providers": "Fournisseurs de modèles",
    },
    "es": {
        "General": "General",
        "Model Providers": "Proveedores de modelos",
    },
    "zh-Hans": {
        "General": "通用",
        "Model Providers": "模型提供商",
    },
    "ja": {
        "General": "一般",
        "Model Providers": "モデルプロバイダ",
    },
}


def main() -> int:
    root = pathlib.Path(__file__).resolve().parents[1]
    for code, block in KEYS.items():
        path = root / "app" / f"{code}.lproj" / "Localizable.strings"
        text = path.read_text(encoding="utf-8")
        missing = [k for k in block if f'"{k}" =' not in text]
        if not missing:
            print(f"{code}: up to date")
            continue
        if not text.endswith("\n"):
            text += "\n"
        lines = ["\n/* Settings window tab labels. */"]
        for key in missing:
            lines.append(f'"{key}" = "{block[key]}";')
        path.write_text(text + "\n".join(lines) + "\n", encoding="utf-8")
        print(f"{code}: added {len(missing)} key(s): {', '.join(missing)}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
