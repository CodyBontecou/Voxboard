# ExportKit integration

Vox.md uses the standalone MIT SwiftPM package [`ExportKit`](https://github.com/CodyBontecou/ExportKit) for reusable export orchestration, path planning, preview building, and destination writing. Vox.md does **not** currently use `ExportAutomationKit`: exports are synchronous after a transcript is saved, and there is no scheduled/pending export or export-notification flow.

## Audit summary

- **Exportable domain model:** `Transcript` in `Packages/VoxboardShared/Sources/VoxboardShared/Transcript.swift`.
  - ExportKit adapter: `TranscriptExportRecord` wraps `Transcript` and exposes `exportRecordID` + `exportDate`.
- **Existing settings:** Global export settings live in `AppConstants` UserDefaults keys and per-flow overrides live in `RecordingFlowExportSettings`.
- **Destinations:** Security-scoped folder bookmarks are resolved by `TranscriptFileExporter.exportIfEnabled(...)`; the resolved folder becomes an `ExportDestination`.
- **Formats:** `txt`, `md`, `json`, and `yaml` remain app-owned `ExportFileFormat` cases. YAML can still write `.md` frontmatter for Obsidian Bases.
- **Preview UI:** Vox.md does not have a user-facing export preview screen yet. `TranscriptExportPreviewFactory` now exposes an ExportKit-backed no-write preview builder for future UI.
- **Scheduling/notifications:** No scheduled export, pending export, background export, or export notification logic exists in Vox.md, so `ExportAutomationKit` is intentionally not linked.

## Adapter mapping

All app-specific export decisions stay in VoxboardShared:

| Voxboard type | ExportKit role |
|---|---|
| `TranscriptExportRecord` | `ExportRecord` payload wrapper around `Transcript` |
| `TranscriptExportConfiguration` | App-owned settings snapshot; exposes a domain-free `PortableExportProfileSnapshot` |
| `ExportFileFormat.exportKitDescriptor(...)` | Format descriptors for TXT/Markdown/JSON/YAML |
| `TranscriptExportRenderer` | Renders using Voxboard's existing formatting/template/enrichment logic |
| `TranscriptExportPathPlanner` | Applies Vox.md filename defaults, token rendering, sanitization, uniquing, and ExportKit path safety |
| `TranscriptDestinationWriter` | Writes `PlannedExportFile` values through `ExportFileWriter` |
| `TranscriptExportRun` | Single-transcript export wrapper used by `TranscriptFileExporter.export(...)` |
| `TranscriptExportPreviewFactory` | No-write ExportKit preview builder |
| `TranscriptExportBatchOrchestrator` | Batch wrapper around `ExportRunOrchestrator` for tests/future UI |

## Behavior compatibility

`TranscriptFileExporter.export(...)` and `exportViaTemplate(...)` now route through `TranscriptExportRun`, but file output remains compatible:

- New-file mode still uses the same filename template tokens and `-2`, `-3` uniquing.
- Append mode still writes to the configured append filename.
- TXT/Markdown/YAML append separators are preserved.
- JSON append still produces a valid array of `Transcript` objects.
- Template exports still render through `TemplateRenderer` and write Markdown.
- Folder bookmark resolution, per-flow overrides, smart-folder overrides, auto-organize subfolders, enrichment options, static frontmatter, and audio references remain app-owned.

## Tests

ExportKit adapter coverage lives in `Packages/VoxboardShared/Tests/VoxboardSharedTests/TranscriptExportKitAdapterTests.swift` and covers:

- renderer output for Markdown and JSON
- path planning and traversal rejection through destination writing
- new-file uniquing and append/update merge strategies
- preview generation without writing
- batch orchestration progress/result success
- a non-Vox.md sample `ExportRecord` proving ExportKit remains generic
