# Design

## Constraints

macOS 11+, Universal x86_64 + arm64, 8 GB RAM. Swift + AppKit + AVFoundation, no external dependencies. Source capture uses AVCaptureScreenInput and AVCaptureDeviceInput into a single AVCaptureMovieFileOutput with H.264/AAC. Video is source-scaled to fit 1920×1080, keeps aspect ratio, 5 fps default / 10 fps optional. Encoder hardware preference is supplied only when supported; system fallback is permitted. Hardware use is not measured or claimed.

The movie output streams to disk with two-second fragments and a 128 MB finalization reserve. A 256 MB free-space preflight prevents starting nearly full. Neither frames nor the entire recording accumulate in RAM. A serial state machine rejects concurrent starts and completes repeated stops consistently. Device/sleep/runtime interruption and start/finish watchdogs preserve partial files; recovery still needs real-device testing.

## One timeline

Screen and microphone share one capture output. Start/pause/resume/stop run at its native audio sample boundaries. Bookmark time reads the effective sample-PTS clock around screenshot capture, not wall-clock button time; only media intervals written between boundaries count. Raw recordedDuration can include preroll excluded by MOV edits and is retained only for diagnostics. No sample buffers are retained or rewritten. Screenshot accuracy still has capture-buffer/frame granularity. Audio extraction uses AVAssetReader sample PTS on the original movie timeline; initial microphone offset is preserved in chunk metadata. Later PCM gaps receive silence, overlaps are trimmed. Every chunk is 16 kHz/16-bit mono WAV, at most 180 seconds (5.76 MB PCM, about 7.68 MB Base64).

ASR supplies chunk-relative millisecond times. The app adds chunk.startSeconds once. Missing/invalid times stay missing, never synthesized. Review lets the user fix timing manually. Pen mode records the frozen screenshot’s capture time and a separate annotation end time; frame matching uses that active interval so speech during drawing prefers the final annotated screenshot. Retina coordinates use display bounds for normalized pointers and screenshot pixel dimensions for rendering.

## Transcription

First-run setup blocks workspace access until screen/microphone permissions, hardware, an API key and automatic-upload consent are ready. The key is stored in the local macOS Keychain on a background queue, never in manifest/export/logs or UserDefaults. After successful recording finalization and local audio checks, one automatic transcription attempt uploads only WAV audio. Quiet or unusable audio pauses for review; manual retries retain explicit consent.

URLSession has no disk cache/cookie persistence and rejects redirects. Responses are buffered with an 8 MiB hard cap. One request runs at a time. Qwen requests final JSON below 60 seconds and SSE at 60 seconds or longer, following the documented timestamp protocol. Every finalized SSE sentence is collected; an unfinished tail or a mismatch against cumulative full text rejects the reply. Complete untimed source text is retained and assigned to screenshot cards as well; timestamp completion remains an optional consented retry. Truncated responses and invalid timing fail safely without replacing old text or inventing times. Input size/duration is checked before network dispatch. Requests never retry automatically; successful complete chunks are reused. See QWEN-ASR.md for the provider's documented response limitations.

Project states and chunk states are atomically persisted. Reopening recovers in-flight states to interrupted/pending. Raw recording and audio files remain immutable. A cancelled request might already have reached/billed the provider; cancellation cannot retract transmitted data.

## Review and export

Recording screenshots own stable independent cards. ScreenshotCardMatcher partitions the entire transcript into that card count using ordered O(KN) dynamic programming: punctuation and real pauses favor natural boundaries, with soft screenshot/pen timing scores and only a weak length tie-break. Every original text slice is assigned once; low scores never reject speech. Sentence-only subdivisions reference the enclosing source interval, not synthesized word times. Exact source spans support first/last passage moves between neighboring cards with atomic persistence. Reopening regenerates untouched automatic cards locally; manual edits, timing, screenshot choices and deletion tombstones remain authoritative. Legacy FrameMatcher behavior is retained only for old non-screenshot flows. See SCREENSHOT-CARDS.md. Transcripts/cards are independently editable so edits do not corrupt provider evidence. HTML embeds PNG Base64 and inline CSS with escaped user text, a restrictive CSP and no scripts or remote assets. Bundle export adds separate PNG files, Markdown and a minimal export JSON schema. Images are resolved only inside the project root; traversal/symlink escapes are rejected. Missing images are visible warnings, never silent text-only success.

## Persistence

A `.pointtell` folder contains project.json, recording.mov, frames/*.png and audio/*.wav. Manifest writes are atomic. There is no automatic cleanup. No telemetry, DB, account or server. User selects new destination for each recording. Export never overwrites project source files.


## Recording toolbar

A nonactivating NSPanel sits above normal, floating and annotation windows, joins all Spaces, and supports other apps' full-screen Spaces. It cannot hide with the app or become the main/key window. App/Space transitions and a lightweight timer restore its frontmost order without activating the app. The timer and observers are removed after recording finishes or fails. The HUD starts on the selected recording display and can be dragged.

Bookmarks use CGWindowListCreateImage below the toolbar's window ID so the controls remain visible while the saved screenshot excludes them. Pen annotation windows and their controls sit below the recording HUD, keeping Stop available. The source MOV may still include these controls. macOS secure system surfaces retain system-controlled ordering; real multi-display, full-screen and Spaces behavior belongs in the device checklist.
