# Meth logo

An Erlenmeyer flask holding a faceted crystal: recognisable as a silhouette at 16 px, and
detailed enough to carry a 1024 px app icon.

| File | Use |
| --- | --- |
| `meth-appicon.svg` | Full-colour app icon, including the rounded macOS plate. Source for `AppIcon.icns`. |
| `meth-mark-light.svg` | Mark only, for light backgrounds. |
| `meth-mark-dark.svg` | Mark only, for dark backgrounds. |
| `meth-wordmark-light.svg` | Mark + "Meth" lockup, for light backgrounds. |
| `meth-wordmark-dark.svg` | Mark + "Meth" lockup, for dark backgrounds. |

Run [`../../scripts/generate_logo_assets.sh`](../../scripts/generate_logo_assets.sh) after
changing any of these to regenerate `Assets/rendered/*.png` and
`Sources/Meth/Resources/AppIcon.icns`. The generated files are committed.

## Palette

| Role | Light variant | Dark variant |
| --- | --- | --- |
| Glass | `#1E293B` | `#E2E8F0` |
| Crystal highlight | `#A5F3FC` | `#EAFDFF` |
| Crystal mid | `#22D3EE` / `#38BDF8` | `#22D3EE` / `#67E8F9` |
| Crystal shadow | `#0369A1` | `#0EA5E9` |
| App icon plate | `#4C2E9B` → `#100A2E` | (same; app icons do not follow the theme) |

## Typography

The wordmarks set "Meth" in **SF Pro Display Bold** and the tagline in **SF Pro Text
Medium**, with a Helvetica/Arial fallback stack. The SVGs reference the font by name rather
than embedding outlines, so a renderer without SF Pro installed substitutes the fallback —
which is why the committed PNGs in `Assets/rendered` are the canonical README artwork.

The menu bar glyph is not generated from these files; see
[`MenuBarIcon.swift`](../../Sources/Meth/UI/MenuBarIcon.swift).
