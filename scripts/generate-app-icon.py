#!/usr/bin/env python3
"""Derive the macOS AppIcon asset set from the canonical icon source.

The canonical source is `media-sources/icon.png`, whose SHA-256 is attested in
ICON_PROVENANCE.md and pinned by scripts/check-repository.sh. This script
refuses to run against any other source, downscales the 1254x1254 original
into every macOS icon slot (no slot upscales), and writes the asset catalog
entries the Xcode project references. Derived files carry no metadata from the
source; provenance lives in ICON_PROVENANCE.md, which records the SHA-256 of
each committed output.

Modes:
    generate (default)  Write the appiconset PNGs and Contents.json files.
    --check             Re-derive in memory and compare pixels and JSON against
                        the committed files. Pixel comparison is stable across
                        Pillow releases in a way compressed bytes are not; the
                        committed byte hashes recorded in ICON_PROVENANCE.md
                        identify the exact shipped artifacts.
"""

import hashlib
import io
import json
import pathlib
import sys

from PIL import Image

ROOT = pathlib.Path(__file__).resolve().parent.parent
SOURCE = ROOT / "media-sources" / "icon.png"
SOURCE_SHA256 = "438060d1a8740e69cb1330ee60c218e23556edcf6c4a5d6333ee21b051201eeb"
CATALOG = ROOT / "VaultSquire" / "Resources" / "Assets.xcassets"
ICONSET = CATALOG / "AppIcon.appiconset"

# macOS slots: (point size, scale). Pixel size is size * scale; the largest is
# 1024, below the 1254-pixel source, so every slot is a downscale.
SLOTS = [(16, 1), (16, 2), (32, 1), (32, 2), (128, 1), (128, 2),
         (256, 1), (256, 2), (512, 1), (512, 2)]

CATALOG_CONTENTS = {"info": {"author": "xcode", "version": 1}}


def slot_filename(size: int, scale: int) -> str:
    suffix = "" if scale == 1 else f"@{scale}x"
    return f"icon_{size}x{size}{suffix}.png"


def iconset_contents() -> dict:
    images = []
    for size, scale in SLOTS:
        images.append({
            "filename": slot_filename(size, scale),
            "idiom": "mac",
            "scale": f"{scale}x",
            "size": f"{size}x{size}",
        })
    return {"images": images, "info": {"author": "xcode", "version": 1}}


def load_source() -> Image.Image:
    data = SOURCE.read_bytes()
    digest = hashlib.sha256(data).hexdigest()
    if digest != SOURCE_SHA256:
        raise SystemExit(
            f"Canonical icon hash mismatch: {digest} (expected {SOURCE_SHA256}). "
            "Refusing to derive assets from an unattested source."
        )
    image = Image.open(io.BytesIO(data))
    image.load()
    if image.mode != "RGB" or image.size != (1254, 1254):
        raise SystemExit(
            f"Unexpected source geometry {image.mode} {image.size}; "
            "the attested source is 1254x1254 RGB."
        )
    return image


def derive(source: Image.Image) -> dict:
    outputs = {}
    for size, scale in SLOTS:
        pixels = size * scale
        outputs[slot_filename(size, scale)] = source.resize(
            (pixels, pixels), Image.LANCZOS
        )
    return outputs


def json_bytes(value: dict) -> bytes:
    return (json.dumps(value, indent=2, sort_keys=True) + "\n").encode()


def generate() -> int:
    source = load_source()
    ICONSET.mkdir(parents=True, exist_ok=True)
    (CATALOG / "Contents.json").write_bytes(json_bytes(CATALOG_CONTENTS))
    (ICONSET / "Contents.json").write_bytes(json_bytes(iconset_contents()))
    for name, image in derive(source).items():
        path = ICONSET / name
        image.save(path, format="PNG")
        digest = hashlib.sha256(path.read_bytes()).hexdigest()
        print(f"{digest}  {path.relative_to(ROOT)}")
    print("Record the hashes above in ICON_PROVENANCE.md.")
    return 0


def check() -> int:
    source = load_source()
    failures = []

    for path, expected in [
        (CATALOG / "Contents.json", json_bytes(CATALOG_CONTENTS)),
        (ICONSET / "Contents.json", json_bytes(iconset_contents())),
    ]:
        if not path.is_file() or path.read_bytes() != expected:
            failures.append(f"{path.relative_to(ROOT)} does not match the expected JSON")

    for name, image in derive(source).items():
        path = ICONSET / name
        if not path.is_file():
            failures.append(f"{path.relative_to(ROOT)} is missing")
            continue
        committed = Image.open(path)
        committed.load()
        if committed.mode != image.mode or committed.size != image.size:
            failures.append(f"{path.relative_to(ROOT)} has unexpected geometry")
        elif committed.tobytes() != image.tobytes():
            failures.append(f"{path.relative_to(ROOT)} pixels differ from a fresh derivation")

    if failures:
        print("\n".join(failures), file=sys.stderr)
        return 1
    print(f"App icon assets match a fresh derivation from {SOURCE.relative_to(ROOT)}.")
    return 0


def main() -> int:
    arguments = sys.argv[1:]
    if arguments == ["--check"]:
        return check()
    if arguments:
        print(__doc__, file=sys.stderr)
        return 2
    return generate()


if __name__ == "__main__":
    raise SystemExit(main())
