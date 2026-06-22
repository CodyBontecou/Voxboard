# Voxboard Apple Watch simulator recordings

Captured on Apple Watch Ultra 3 (49mm) simulator, watchOS 26.5, UDID `91AFFCAE-0DB7-4971-B587-FD609AC919C2`.

Build:

- Last refreshed: 2026-06-20 10:18 AST
- Scheme: `Voxboard Watch`
- Configuration: `Debug`
- Bundle ID: `bontecou.Voxboard.watchkitapp`
- Build log: `logs/build-watch.log`

Videos:

- `videos/01-watch-local-recording.mp4` — Watch local recording lifecycle: ready → recording → saved locally → syncing → sent. 422×514, 12.3s.
- `videos/02-watch-queue-sync.mp4` — Offline Watch queue sync: queued recordings → syncing → sent. 422×514, 10.1s.

Clipwright renders:

- `clipwright/renders/01-notelet-watch-white-strong-zoom.mp4` — Notelet-ready 1:1 (1080×1080), 6.6s, pure white background, no overlay text, muted, strong push-in zoom that holds to the final frame. Copied to `~/Downloads/01-notelet-watch-white-strong-zoom.mp4`.
- `clipwright/renders/01-notelet-watch-feature-square.mp4` — Notelet-ready 1:1 (1080×1080) Watch feature snippet with headline/subtitle. Copied to `~/Downloads/voxboard-watch-notelet-square.mp4`.
- `Voxboard/ReleaseNotes/voxboard-watch-notelet-square-mobile.mp4` — mobile-optimized bundled Notelet asset generated from the white strong-zoom render, 720×720 H.264, 6.6s, 94 KB. Copied to `~/Downloads/voxboard-watch-notelet-square-mobile.mp4`.
- `clipwright/renders/00-watch-square-black-frame.mp4` — 1:1 (1080×1080) lifecycle video using Clipwright's black Apple Watch frame.
- Source media for the white strong-zoom spec: `clipwright/01-notelet-watch-white-zoom-source.mp4`
- White strong-zoom spec: `clipwright/specs/01-notelet-watch-white-strong-zoom.clipwright.json`
- White strong-zoom contact sheet: `clipwright/contact-sheets/01-notelet-watch-white-strong-zoom-contact.jpg`
- Source media for the earlier Notelet spec: `clipwright/01-notelet-watch-feature-source.mp4`
- Earlier Notelet spec: `clipwright/specs/01-notelet-watch-feature-square.clipwright.json`
- Earlier Notelet contact sheet: `clipwright/contact-sheets/01-notelet-watch-feature-square-contact.jpg`
- Original black-frame source/spec/contact sheet: `clipwright/00-watch-square-source-lifecycle-clean.mp4`, `clipwright/specs/00-watch-square-black-frame.clipwright.json`, `clipwright/contact-sheets/00-watch-square-black-frame-contact.jpg`

Verification assets:

- Contact sheets: `contact-sheets/`
- Thumbnails: `thumbnails/`
- Install/launch logs: `logs/record-flow.log`, `logs/queue-flow.log`

Both videos use the app's DEBUG-only demo launch args:

- `--voxboard-demo record-flow`
- `--voxboard-demo queue-flow`
