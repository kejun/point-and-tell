# Download Point & Tell

## v0.2.1 · Timestamp-aligned exports · Universal · macOS 11.0+

[Download v0.2.1](v0.2.1/Point-and-Tell-v0.2.1-macOS-universal.zip?raw=true)

Groups speech with the corresponding selected screenshots in HTML and Markdown using retained word timestamps. Shows actual speech/frame times to three decimal places, preserves manual edits, and explicitly labels missing word timing. Both export actions are directly visible above the workspace.

- Archive: 2,306,948 bytes; Intel x86_64 + Apple Silicon arm64
- [Exact source commit](https://github.com/kejun/point-and-tell/commit/a6d994d6bc7c315d8bfc84313761a93749593639) · [native build/test run](https://github.com/kejun/point-and-tell/actions/runs/37000170176)
- 115 core tests on each architecture; native audio/UI checks and desktop/390px WebKit export rendering
- [SHA-256](v0.2.1/Point-and-Tell-v0.2.1-macOS-universal.zip.sha256) · [build manifest](v0.2.1/build.json) · [alignment rules and limitations](../docs/EXPORT-ALIGNMENT.md)
- Ad-hoc signed, not Apple-notarized. Actual macOS 11 device behavior and paid ASR accuracy remain unverified.

Old projects with no stored word timestamps retain whole-sentence/manual grouping. This update does not silently re-upload their audio or invent missing timing.

## v0.2.0 · Native workspace & app icon · Universal · macOS 11.0+

[Download v0.2.0](v0.2.0/Point-and-Tell-v0.2.0-macOS-universal.zip?raw=true)

A redesigned AppKit workspace with recording/transcription sidebar, numbered feedback cards, automatic text-save feedback, timing validation, screenshot assignment and a focused export menu. Includes the selected forest-teal app icon and light/dark appearances.

- Archive: 2,222,988 bytes; Intel x86_64 + Apple Silicon arm64
- Source commit: [4e552fe](https://github.com/kejun/point-and-tell/commit/4e552fe0844983a02a2600bf8f8abf72cdd857f8)
- [Native build/test run](https://github.com/kejun/point-and-tell/actions/runs/36968091570)
- [SHA-256](v0.2.0/Point-and-Tell-v0.2.0-macOS-universal.zip.sha256) · [exact source/build manifest](v0.2.0/build.json) · [UI screenshots](../docs/UI-DESIGN.md)
- Ad-hoc signed, not Apple-notarized. Both slices target macOS 11.0.

Native automated core, audio and UI checks cover the build. Actual macOS 11 permissions, physical microphone input and a billed ASR request still need device verification. Older releases below remain available for rollback.

## v0.1.1 · Audio diagnostics · Universal · macOS 11.0+

[Download v0.1.1](v0.1.1/Point-and-Tell-v0.1.1-macOS-universal.zip?raw=true)

Adds microphone selection and live levels, local playback, audio-track/decode checks, explicit low-signal upload confirmation, and safe staged ASR errors.

- Archive: 924,015 bytes; Intel x86_64 + Apple Silicon arm64
- Source commit: [32110e3cdc4b9aa01f729e8d8bda649e47e2327b](https://github.com/kejun/point-and-tell/commit/32110e3cdc4b9aa01f729e8d8bda649e47e2327b)
- [Source build/test run](https://github.com/kejun/point-and-tell/actions/runs/36964548382): 107 tests passed on each native architecture; nonzero AAC MOV/WAV, actual delayed signal timing, silence/missing/corrupt input, safe retry, local playback readiness and UI rendering passed
- [SHA-256 checksum](v0.1.1/Point-and-Tell-v0.1.1-macOS-universal.zip.sha256) and [source/build manifest](v0.1.1/build.json)
- Ad-hoc signed, not Apple-notarized. Both slices target macOS 11.0

First check: explicitly select the built-in microphone, record ten seconds of non-sensitive speech, confirm the live level responds, then Stop and use **本地试听录屏**. No API key is needed for this check. Missing audio blocks transcription; very low level is advisory and needs explicit confirmation to upload.

This release does not establish the cause of the original Big Sur no-audio report. Actual macOS 11 microphone/permission behavior, audible output and billed provider integration still need device verification.

## v0.1.0 · Universal · macOS 11.0+

[Download the app ZIP](v0.1.0/Point-and-Tell-v0.1.0-macOS-universal.zip?raw=true)

One application supports both Intel (x86_64) and Apple Silicon (arm64).

- Archive: 746,283 bytes
- Source commit: [`415b65b3a1fa9084852f1ff9dc898f780a1867a4`](https://github.com/kejun/point-and-tell/commit/415b65b3a1fa9084852f1ff9dc898f780a1867a4)
- [Build/test run](https://github.com/kejun/point-and-tell/actions/runs/36952515792): 72 tests passed on each native architecture, native PCM extraction/retry and review-window rendering passed
- Both Mach-O slices declare minimum macOS 11.0; ad-hoc code signature verified in CI
- [SHA-256 checksum](v0.1.0/Point-and-Tell-v0.1.0-macOS-universal.zip.sha256) and [build manifest](v0.1.0/build.json)

This is a preview and is not Apple-notarized. Extract the ZIP, move Point & Tell.app to Applications, and use Finder → right-click → Open on macOS 11 if prompted. Do not disable system security.

Real macOS 11 permission/recording behavior, actual provider ASR requests, and the 10-minute old-Mac performance check still require device testing. No API key or recording is included.

Each published version directory is immutable. Keep an older ZIP if you need rollback. See [versioning](../docs/VERSIONING.md). No Git tag or GitHub Release is implied by this versioned directory.
