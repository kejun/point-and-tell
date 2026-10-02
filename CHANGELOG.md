# Changelog

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
