# Canonical Icon Provenance And Technical Review

- Status: source ownership attested; assets generated at the owner's direction;
  small-size visual review pending
- Canonical file: `media-sources/icon.png`
- SHA-256: `438060d1a8740e69cb1330ee60c218e23556edcf6c4a5d6333ee21b051201eeb`
- Attesting owner: `L-K-M`
- Attestation date: 2026-07-31

## Owner Attestation

`L-K-M` attests that the hash-identified image was generated at their direction
with OpenAI GPT Image 2.0, used no third-party logo, artwork, screenshot, or
Keyguard-derived input, and did not use Keyguard, Bitwarden, Vaultwarden, or
Proton material as an input or reference. `L-K-M` authorizes VaultSquire to
preserve, modify, generate macOS derivatives from, reproduce, and distribute the
image under the rights available through the applicable OpenAI terms.

This is a project provenance record, not legal advice. It does not establish
trademark clearance or copyright treatment in every jurisdiction.

## Technical Metadata

| Property | Result |
|---|---|
| Format | Valid non-interlaced PNG; chunk CRCs pass |
| Dimensions | 1254 x 1254 pixels |
| Color | 8-bit truecolor RGB, 24 bits per pixel |
| Transparency | None; no alpha channel or `tRNS` chunk |
| Color profile | None embedded; no `sRGB`, `gAMA`, or `cHRM` chunk |
| Density | No `pHYs` metadata |
| C2PA | Private `caBX` C2PA/JUMBF manifest identifies `gpt-image` 2.0 and trained-algorithmic media; dedicated trust-chain validation not yet performed |

The source is large enough to create 16, 32, 64, 128, 256, 512, and 1024 pixel
macOS icon slots without upscaling.

## Remaining Visual Gate

Generated assets exist (see the Derived Asset Record below) but remain
unshippable until Workstream 1 records human review of actual 16, 32, and 64
pixel output at 1:1 scale in Finder and the Dock, on light and dark
backgrounds, under the selected color profile and macOS mask. Review must
address:

- loss of chainmail, scratches, rivets, vents, highlights, and the small keyhole;
- low-contrast dark steel against the dark vault interior;
- isolated bright pixels or resize halos;
- opaque corners and content near the mask boundary; and
- whether the shield-shaped lower badge creates confusing third-party trade
  dress or contradicts the product's no-imitation branding rule.

Do not replace this source, strip its provenance metadata, or — except at the
owner's recorded direction, as happened below — generate shipping assets before
that review. Derived assets must record tool, exact command, profile,
dimensions, output hashes, reviewer, and source hash.

## Derived Asset Record (2026-08-09)

Generated at the attesting owner's explicit direction ahead of the visual
review, which remains open: the owner reviews the 16, 32, and 64 pixel
renderings at 1:1 in Finder and the Dock per the gate above.

- Tool: `scripts/generate-app-icon.py` (Python 3.11.15, Pillow 12.3.0,
  Lanczos resampling). Pillow is a derivation-host tool only: it never
  executes inside the product or its build, no package manifest exists, and
  the ADR 0003 in-process dependency gate is therefore not triggered
- Exact command: `python3 scripts/generate-app-icon.py`
- Verification: `python3 scripts/generate-app-icon.py --check` re-derives and
  compares pixels; the script refuses any source whose SHA-256 differs from the
  attested hash below
- Source: `media-sources/icon.png`, SHA-256
  `438060d1a8740e69cb1330ee60c218e23556edcf6c4a5d6333ee21b051201eeb`
  (unmodified; its C2PA manifest stays intact in the source file)
- Color profile: none embedded in source or outputs; pixels are copied under
  default (sRGB-assumed) interpretation with no conversion
- Outputs: `VaultSquire/Resources/Assets.xcassets/AppIcon.appiconset/`, all
  derived by downscaling (no slot upscales); derived PNGs carry no C2PA or
  other source metadata
- Reviewer: pending (owner)

| Output | Pixels | SHA-256 |
|---|---|---|
| `icon_16x16.png` | 16 | `4cff67f9414de8f4c41e3fc8695180e5378512093ddd7cfc6ae7c50f5efa28ce` |
| `icon_16x16@2x.png` | 32 | `cba6a50eea52de2b209f974afce4e69e2cac4e604a827856f17d97b4e9387087` |
| `icon_32x32.png` | 32 | `cba6a50eea52de2b209f974afce4e69e2cac4e604a827856f17d97b4e9387087` |
| `icon_32x32@2x.png` | 64 | `fdd581f1adddbbb1439585b546b8ca915b5bbab5f58518140b1fedd6f1587056` |
| `icon_128x128.png` | 128 | `e569925dd0bbc9c8121f72abff460574b02f366462595aca074c3e76d340447e` |
| `icon_128x128@2x.png` | 256 | `af0e36a247286a7ebf138cfd160709294445e883331c8da0a3a4a6547d928b52` |
| `icon_256x256.png` | 256 | `af0e36a247286a7ebf138cfd160709294445e883331c8da0a3a4a6547d928b52` |
| `icon_256x256@2x.png` | 512 | `2c2cc14f9c8c49ec99516ce6afb1400f4650505135cef982dccf0036320ffd66` |
| `icon_512x512.png` | 512 | `2c2cc14f9c8c49ec99516ce6afb1400f4650505135cef982dccf0036320ffd66` |
| `icon_512x512@2x.png` | 1024 | `f808ac6e2437b7af72dc32d788e1f06bdd2c58a652a077edbcbdea62fd130a43` |

Same-pixel-count slots are byte-identical by construction, which is the
determinism the `--check` mode verifies. The artwork ships full-bleed with no
pre-applied mask: macOS 26 applies the system icon mask itself, and earlier
macOS versions in the support range render the unmasked square, which the open
visual review covers.
