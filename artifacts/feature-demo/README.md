# Voxboard Watch feature capture

Captured on `Apple Watch Ultra 3 (49mm)` simulator (`watchOS 26.5`, UDID `91AFFCAE-0DB7-4971-B587-FD609AC919C2`).

## Final videos

- `clipwright/renders/00-watch-feature-reel.mp4` — combined reel, starting from a Watch face widget tap
- `clipwright/renders/01-watch-local-recording.mp4` — Watch face widget tap → record → stop → saved/synced lifecycle
- `clipwright/renders/02-watch-queue-sync.mp4` — offline Watch queue → syncing → synced state

Copies were also placed in `~/Downloads/Voxboard-Watch-Clipwright/`.

## Capture + render details

- Raw simulator captures: `videos/`
- Raw contact sheets: `video-thumbnails/`
- Clipwright specs: `clipwright/specs/`
- Clipwright thumbnails/contact sheets: `clipwright/thumbnails/`, `clipwright/contact-sheets/`
- Capture plan: `capture-plan.json`
- Watch face widget intro art: `watch-face-widget.png`

All Clipwright renders use:

- white background (`#FFFFFF`)
- Apple Watch-style device frame
- muted audio
- no Clipwright text overlays (`text_label` effects are not used)

## Debug hooks used

The Watch app was launched with DEBUG-only demo args:

- `--voxboard-demo record-flow`
- `--voxboard-demo queue-flow`

These hooks create deterministic demo state without using the microphone or requiring a paired iPhone transfer. They are guarded by `#if DEBUG` in the Watch target.

## Clipwright Apple Watch preset

Clipwright did not include a built-in Apple Watch device preset, so rendering used the patch saved at:

- `clipwright-watch-device-preset.patch`

`clipwright/render-all.sh` applies that patch to `/Users/codybontecou/projects/AppShowcase/AppShowcase` temporarily, renders, then restores the Clipwright source file.
