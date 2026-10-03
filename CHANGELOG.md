# Changelog

## 0.4.1 — 2026-10-03

- Create one durable card for each completed recording bookmark or pen session, before transcription. Keep screenshot event IDs stable across duplicate callbacks, retries and reopen; equal-time events stay separate.
- Associate real word/sentence timestamps back to screenshots using pen intervals, adjacent screenshot boundaries and speech pauses. Keep ambiguous/untimed source text available for manual review, without splitting sentences into invented word times.
- Remove post-transcription automatic frame extraction. Keep explicit manual extraction as an atomic replacement on the selected card; failed writes leave existing cards untouched.
- Preserve generated-versus-edited content and screenshot deletion decisions. Legacy adoption keeps stored cards intact; screenshot cards export in exactly the editor's order and grouping.
- Add association details and a source-transcript viewer, including a File menu entry when no cards exist. Save timing when editing ends; block navigation after an unsuccessful text write until saving succeeds.
- Retain pen strokes when saving fails, allowing retry or explicit cancellation.

Native automated fixtures do not establish real Qwen response accuracy or timing precision on physical Big Sur recording hardware. See [screenshot card behavior and device checks](docs/SCREENSHOT-CARDS.md).

## 0.4.0 — 2026-10-03

- Add Sparkle 2.9.6, preserving macOS 11 and Universal support. Official builds check a signed HTTPS feed every 24 hours, expose Check for Updates and Automatic Checks, and require confirmation before installation.
- Defer automatic offers during recording startup/finalization, transcription, export, screenshots, annotations and modal panels. Interactive updating temporarily locks new work; cancellation or failure restores editing.
- Save the whole project again before updating or quitting, including text whose earlier autosave failed. Recheck active work and persistence before termination.
- Embed Sparkle's framework and helpers with inside-out signing, preserving executable permissions, symlinks, resources and helper entitlements.
- Add a main-branch release workflow: native checks, monotonic versions/builds, Ed25519-signed archive/feed, immutable archive URLs and a single fast-forward publication. Missing/mismatched keys stop publication.
- Add maintainer Keychain/GitHub signing setup, release validation tests, real signature/corruption tests and update/rollback documentation.

This source change does not publish an update-enabled download by itself. Configure signing and run the release workflow. Production old-to-new replacement/relaunch and macOS 11 permission/Keychain behavior still require the device checklist.

## 0.3.3 — 2026-10-02

- Add Delete for the selected review card in the card list and Edit menu, with confirmation. Save deletion before updating the interface, select the adjacent card, renumber the list, and disable unavailable actions after the final deletion. Original media and source transcripts remain available.
- Persist deletion decisions so empty-review exports and transcription retries do not restore deleted passages. Older projects without deletion metadata retain their transcript-only export fallback.
- Draw New Recording and Export Standalone HTML with a solid forest-teal primary background and white text/icons, including inactive-window, pressed and disabled states; retain native button actions and accessibility.
- Cover deletion save/reopen/export/retry behavior, adjacent selection, busy controls and failed-write rollback in core/native regressions.

## 0.3.2 — 2026-10-02

- Let the native capture preset negotiate compatible video/audio encoding instead of forcing a hardware preference, output dimensions, frame compression settings, and 44.1 kHz mono AAC. Keep source screen scaling, 5/10 fps, the selected microphone, and later ASR resampling.
- Preserve synchronous session-start runtime errors before serial-queue cleanup; retain the original failure stage through finalization.
- Show a Chinese recording-error title with selectable nested NSError domains/codes, Copy Diagnostics, and a unique local diagnostic file. No raw userInfo is included.
- Show a retry action after a zero-duration failed recording and disable playback/transcription until a recording is available. Preserve partial files and do not start automatic ASR after failure.
- Add nested-error/latch regression tests and native failure-dialog/empty-state checks.

The screenshot's generic message alone does not establish the device-side root cause. This release addresses format-compatibility risks and confirmed diagnostic gaps. Physical recording on the affected Mac still needs verification; offline audio fixtures do not exercise a physical microphone or screen capture permission.

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
