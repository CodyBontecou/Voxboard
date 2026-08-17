# Meeting / Call Speaker Transcripts

## Implemented approach

Vox.md supports opt-in, on-device speaker diarization for voice recordings that run a Capture Preset.

The pipeline is:

1. Record or import audio and normalize it to 16 kHz mono WAV.
2. Transcribe locally with Apple Speech, Whisper, or Parakeet while retaining timed text units.
3. If the selected Capture Preset has **Identify Speakers** enabled, run FluidAudio’s offline Pyannote Community-1/VBx diarizer on the same audio.
4. Assign every timed text unit to the overlapping speaker segment. When there is no overlap, use the nearest segment midpoint.
5. Group adjacent units into anonymous `Speaker 1`, `Speaker 2`, and later turns.
6. Save both rendered speaker-labelled text and structured speaker turns in history and JSON exports.

This follows the mobile approach in `~/dev/rescript`: diarization is a post-transcription, best-effort pass; its model is downloaded only after opt-in; and a diarization failure never discards a valid transcript. Vox.md uses its existing, newer FluidAudio dependency rather than adding Rescript’s separate SpeakerKit dependency.

## Product behavior

- The toggle is per Capture Preset and defaults to off for new and existing presets.
- Processing and audio stay on device.
- The speaker model downloads on first use.
- Direct preset recordings, imported audio, Capture draft voice recordings/imports, Watch transcript presets, and the native Mac app can use diarization.
- Draft delivery remains draft-only: the selected preset contributes only its immutable voice-processing choice, not formatting, export, or destination behavior.
- Keyboard insertion, transcription-only clipboard capture, and Watch **Recording Only** mode do not use diarization.
- FluidAudio's URL-based diarization path streams through a disk-backed sample source. The earlier import normalization step is separate and is not claimed to be disk-backed.
- History displays the detected speaker count. TXT/Markdown/Capture exports naturally include the rendered labels; JSON also includes structured turns and timestamps.
- User edits to the raw transcript invalidate structured turns. Enrichment-only updates preserve them.

## Engine timing support

- Whisper enables token timestamps and merges timestamped tokens into words, with segment timestamps as a fallback.
- Parakeet maps FluidAudio token timings into words.
- Apple Speech requests `audioTimeRange` attributes from final iOS 26 results, with each result’s time range as a fallback.
- Live Apple Speech is still used for previews, but an opted-in preset runs batch recognition at completion so diarization has timestamps.

## Limitations

Speaker labels are anonymous and recording-local; Vox.md does not identify people by name or persist voice embeddings. Accuracy varies with background noise, overlapping speech, short utterances, and similar voices. If timestamps, first-use model download/preparation, storage, or inference are unavailable, Vox.md saves the plain transcript and stores a visible nonfatal reason in History.

## Platform/legal note

iOS does not provide a general-purpose API for silently recording phone calls, and call-recording laws vary by jurisdiction. Vox.md should frame this feature as recording or importing audio the user has permission to process, not as built-in phone-call recording.
