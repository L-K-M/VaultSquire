# Canonical Icon Provenance And Technical Review

- Status: source ownership attested; generated assets not yet approved
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

Generated assets remain blocked until Workstream 1 records human review of
actual 16, 32, and 64 pixel output at 1:1 scale in Finder and the Dock, on light
and dark backgrounds, under the selected color profile and macOS mask. Review
must address:

- loss of chainmail, scratches, rivets, vents, highlights, and the small keyhole;
- low-contrast dark steel against the dark vault interior;
- isolated bright pixels or resize halos;
- opaque corners and content near the mask boundary; and
- whether the shield-shaped lower badge creates confusing third-party trade
  dress or contradicts the product's no-imitation branding rule.

Do not replace this source, strip its provenance metadata, or generate shipping
assets before that review. Derived assets must record tool, exact command,
profile, dimensions, output hashes, reviewer, and source hash.
