# Geist UI Source of Truth

Vox.md’s UI follows the vendored Vercel Geist specifications in this directory:

- `design.md` — light theme
- `design.dark.md` — dark theme

`Voxboard/GeistTheme.swift` is the SwiftUI implementation of those documents, and `website/geist.css` is the web implementation. UI changes must use their documented color, typography, spacing, radius, control-size, elevation, motion, and content tokens. Do not introduce product-specific visual tokens or decorative treatments.

The bundled Geist Sans and Geist Mono files live in `Voxboard/Fonts/` and `website/fonts/` under Vercel’s license. Geist Sans is for UI and prose. Geist Mono is reserved for code, file formats, timers, sizes, percentages, and tabular data.

When the upstream specifications change, replace both Markdown files first, then update `GeistTheme.swift` and `website/geist.css` to match. The Markdown files remain authoritative.
