"""Generate assets/AppIcon.icon, an Icon Composer document (macOS 26+).

The flat AppleTree tree-treemap logo (assets/logo.svg) on a transparent
background, no glass or background fill. `actool` compiles it to Assets.car
and a flat AppIcon.icns fallback for older systems; see build.sh.
"""
import json
import pathlib
import shutil

OUT = pathlib.Path(__file__).parent / "AppIcon.icon"
LOGO = pathlib.Path(__file__).parent / "logo.svg"

assets = OUT / "Assets"
assets.mkdir(parents=True, exist_ok=True)
for old in assets.glob("*.svg"):
    if old.name != "logo.svg":
        old.unlink()
shutil.copyfile(LOGO, assets / "logo.svg")

icon = {
    "groups": [{
        "layers": [{
            "name": "logo",
            "image-name": "logo.svg",
            "glass": False,
        }],
        "lighting": "individual",
        "specular": False,
        "translucency": {"enabled": False, "value": 0.0},
    }],
    "supported-platforms": {"squares": ["macOS"]},
}
(OUT / "icon.json").write_text(json.dumps(icon, indent=2) + "\n")
