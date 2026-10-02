# Recording startup compatibility and diagnostics (v0.3.2)

## Report and finding

After New Recording, the affected Mac displayed only “The operation could not be completed”. The screenshot contains no NSError domain, code, or underlying error. It cannot establish whether the failing component is the microphone, capture session, encoder, destination, or system permission.

The recorder previously supplied a complete custom video dictionary (dimensions, scaling, bitrate, keyframes, frame reordering and hardware preference) plus fixed 44.1 kHz mono AAC audio. These settings are a compatibility risk across supported macOS/hardware combinations, not a proven diagnosis for this report. Also, a failed synchronous `startRunning()` could clean up before its queued runtime-error callback ran, discarding the useful original error. Passing that raw error to `NSAlert(error:)` hid the remaining detail behind a generic message.

## Change

- Use `.high` when supported and `setOutputSettings(nil, for:)` for both output connections. Apple's documented `nil` behavior uses the session preset; an empty dictionary would instead mean passthrough. Screen scaling and 5/10 fps remain set on the source. Bitrate/codec/sample rate/channel count now come from the native preset; exact file size and hardware encoder use are not promised. AudioChunker still performs the local 16 kHz mono conversion required for ASR.
- Give each capture session its own thread-safe first-error latch. Record runtime errors before dispatching cleanup, then surface that original error if `startRunning()` fails.
- Carry the failure stage through start, runtime interruption, and finalization. Display the stage in Chinese, plus bounded nested NSError domains/codes and sanitized messages. Offer Copy Diagnostics and save a unique `capture-error-<UUID>.txt` beside the project. Disk write failure never suppresses the on-screen diagnostic.
- A failed zero-duration attempt shows New Recording again and disables playback/transcription. Preserve existing files; do not retry capture silently or upload failed audio automatically.

## Verification and limits

Core regression tests cover a generic AVFoundation error with a nested OSStatus code, stage preservation during cleanup, bounded diagnostic chains, omission of unrelated userInfo, and first-error retention across threads. The native UI fixture checks the failed-start retry state and selectable/copyable diagnostic dialog. Existing core, native AAC/WAV and WebKit checks remain in CI.

These checks are not a real recording on the affected Mac. Install the new build, make a short disposable recording, verify the microphone meter, stop, and listen locally. Recording completion may start the already-consented automatic ASR upload. If startup still fails, copy the diagnostic text; the new stage/domain/code identifies the next investigation without requiring a private recording or API key.

References: [Apple setOutputSettings](https://developer.apple.com/documentation/avfoundation/avcapturemoviefileoutput/setoutputsettings(_:for:)), [Apple screen scaleFactor](https://developer.apple.com/documentation/avfoundation/avcapturescreeninput/scalefactor).
