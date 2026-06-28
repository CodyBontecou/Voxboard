# Meeting / Call Speaker Transcript Research

## Summary

Vox.md can ship a useful meeting/call import MVP now, but accurate line-by-line `Speaker 1` / `Speaker 2` diarization should be treated as a separate research/model dependency.

The implemented MVP path is:

1. Import an arbitrary audio file.
2. Transcribe it locally with the selected Whisper/Parakeet model.
3. Create a custom Meeting / Call flow to export structured notes with frontmatter and best-effort action items.

This satisfies private meeting-note workflows without promising speaker labels that the current engines do not provide.

## Current engine constraints

- `WhisperContext` currently returns a single plain-text transcript string.
- The wrapper sets `params.no_timestamps = true`, so segment timestamps are not exposed today.
- `ParakeetContext` currently returns `result.text`, not speaker turns.
- Neither current path performs speaker diarization.

## Feasible next steps

### Phase 1 — Timestamped transcript

Expose model segments from Whisper before diarization:

- Set `params.no_timestamps = false` or add a separate timestamped transcription path.
- Return an array of segments: start time, end time, text.
- Export as Markdown like:

```md
[00:00:03] We should launch this next week.
[00:00:12] I'll write the announcement.
```

This is feasible with the current Whisper wrapper and would improve meetings even without speaker IDs.

### Phase 2 — Best-effort speaker grouping

Once segments exist, evaluate simple heuristics:

- Paragraph breaks on long pauses.
- Alternating speaker labels only when confidence is clear.
- UI language should say "speaker groups" or "best effort", not accurate diarization.

This is low-confidence but may help short two-person call recordings.

### Phase 3 — Real diarization

Reliable speaker labels require a diarization model or service. Requirements:

- Runs on-device or is explicitly opt-in if cloud-based.
- Fits iOS memory/CPU constraints.
- Produces speaker embeddings or speaker-change boundaries.
- Works with common meeting/call audio quality.

Until such a model is validated, avoid promising line-by-line speakers.

## Product recommendation

Ship these now:

- Imported audio transcription.
- Custom Meeting / Call flow.
- Markdown meeting notes with action items.
- Optional saved source audio attachment.

Defer these:

- Accurate speaker labels.
- Phone-call recording claims.
- Cloud diarization, unless introduced later as an explicit opt-in non-default mode.

## Platform/legal note

iOS does not provide a general-purpose API for silently recording phone calls, and call recording laws vary by jurisdiction. Vox.md should frame this feature as importing recordings the user already has permission to record/transcribe, not as built-in phone call recording.
