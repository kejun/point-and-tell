# Changelog

## 0.2.0 — Native workspace and app identity

- Ship the selected forest-teal card icon in the application bundle; retain the 1024px master and Xcode icon set under Resources/Brand.
- Replace the dense control sheet with a native sidebar, numbered card list, focused editor, preview and export menu.
- Add onboarding and empty-project states, semantic light/dark colors, scrollable settings/editor, accessible labels and File menu shortcuts.
- Show saved text feedback; validate and save timing drafts before changing cards, opening/creating projects or exporting.
- Keep unassigned cards' previews empty and distinguish previewed images from assigned export images.
- Preserve the v0.1.1 capture, local audio checks and opt-in transcription pipeline.
- Extend native smoke evidence to welcome/review/empty states and dark compact layouts.

## 0.1.1 — 2026-10-02

Audio-chain diagnostics and capture reliability update.

- Explicit microphone selector (including system default and named built-in/external inputs), actual device name and bounded live dBFS meter
- Require an enabled, active audio connection before reporting recording startup; preserve and surface interrupted/partial recording errors
- Inspect the saved recording for a readable audio track and decoded PCM samples; no usable audio blocks transcription
- Local in-app recording playback; low-level/silence warning with an explicit per-attempt override before audio upload
- Recheck each actual WAV before upload, including retry files; amplitude is not treated as speech detection
- Staged request, transport, HTTP/provider and response-parsing diagnostics with safe status/code/request ID; no raw provider message, key or response persistence
- Native nonzero AAC-in-MOV fixtures at 44.1/48 kHz cover resampling, 180-second splitting, timeline offset, silence, absent tracks, corrupt input and non-destructive retry

The user's original Big Sur no-audio failure has not been reproduced from a supplied recording. These changes address confirmed validation/diagnostic gaps; they do not establish a particular hardware or API-key root cause. Physical microphone capture on macOS 11.7.11 and paid provider integration remain device/user-verification steps.


## 0.1.0 — 2026-10-02

Initial preview for macOS 11+ Intel and Apple Silicon Macs.

- Native AppKit screen + microphone recording at 5 or 10 fps, streamed to fragmented MOV
- Floating Stop / Mark / Pen controls, Control–Option–M bookmark shortcut
- Frozen-frame pen annotation while voice recording continues, with undo and clear
- Optional Alibaba Cloud audio-only transcription with local 180-second WAV chunks, explicit status and retry
- Editable review cards, exact provider timestamps when available, manual frame selection
- Offline self-contained HTML and PNG + Markdown + JSON export
- Core fixture tests and Intel and ARM macOS CI builds

Preview limitations: real API billing/network integration, macOS 11 permission flows, crash recovery, and 10-minute Intel performance are device-verification tasks. CI on a newer macOS verifies build compatibility, not those runtime claims. No license has been selected.
