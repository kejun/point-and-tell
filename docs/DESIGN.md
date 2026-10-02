# Design

## Constraints

macOS 11+, Universal x86_64 + arm64, 8 GB RAM. Swift + AppKit + AVFoundation, no external dependencies. Source capture uses AVCaptureScreenInput and AVCaptureDeviceInput into a single AVCaptureMovieFileOutput with H.264/AAC. Video is source-scaled to fit 1920×1080, keeps aspect ratio, 5 fps default / 10 fps optional. Encoder hardware preference is supplied only when supported; system fallback is permitted. Hardware use is not measured or claimed.

The movie output streams to disk with two-second fragments and a 128 MB finalization reserve. A 256 MB free-space preflight prevents starting nearly full. Neither frames nor the entire recording accumulate in RAM. A serial state machine rejects concurrent starts and completes repeated stops consistently. Device/sleep/runtime interruption and start/finish watchdogs preserve partial files; recovery still needs real-device testing.

## One timeline

Screen and microphone share one capture output. Bookmark time reads that output’s recordedDuration at screenshot capture, not wall-clock button time. Accuracy has capture-buffer/frame granularity. Audio extraction uses AVAssetReader sample PTS on the original movie timeline; initial microphone offset is preserved in chunk metadata. Later PCM gaps receive silence, overlaps are trimmed. Every chunk is 16 kHz/16-bit mono WAV, at most 180 seconds (5.76 MB PCM, about 7.68 MB Base64).

ASR supplies chunk-relative millisecond times. The app adds chunk.startSeconds once. Missing/invalid times stay missing, never synthesized. Review lets the user fix timing manually. Pen mode records the frozen screenshot’s capture time and a separate annotation end time; frame matching uses that active interval so speech during drawing prefers the final annotated screenshot. Retina coordinates use display bounds for normalized pointers and screenshot pixel dimensions for rendering.

## Transcription

Explicit user action uploads only WAV audio. URLSession has no disk cache/cookie persistence and rejects redirects. Responses are buffered with an 8 MiB hard cap. The API key is ephemeral, never in manifest/export/logs; there is no Keychain-saving feature in this preview. One request runs at a time. JSON and SSE are normalized; only sentence_end finalized events count. Responses without reliable times remain untimed. Input size/duration is checked before network dispatch. No request auto-retry means unexpected billing is avoided; user retries completed/pending chunks through saved state.

Project states and chunk states are atomically persisted. Reopening recovers in-flight states to interrupted/pending. Raw recording and audio files remain immutable. A cancelled request might already have reached/billed the provider; cancellation cannot retract transmitted data.

## Review and export

FrameMatcher prioritizes pen then bookmark then ordinary video frames inside the actual utterance interval; long intervals use multiple temporal windows. Manual frame choices are authoritative. Transcripts/cards are independently editable so edits do not corrupt provider evidence. HTML embeds PNG Base64 and inline CSS with escaped user text, a restrictive CSP and no scripts or remote assets. Bundle export adds separate PNG files, Markdown and a minimal export JSON schema. Images are resolved only inside the project root; traversal/symlink escapes are rejected. Missing images are visible warnings, never silent text-only success.

## Persistence

A `.pointtell` folder contains project.json, recording.mov, frames/*.png and audio/*.wav. Manifest writes are atomic. There is no automatic cleanup. No telemetry, DB, account or server. User selects new destination for each recording. Export never overwrites project source files.
