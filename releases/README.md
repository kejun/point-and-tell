# Download Point & Tell

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
