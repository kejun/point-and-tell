# First-run setup and automatic transcription · v0.3.0

Before the workspace is visible, the app checks screen-recording permission, microphone permission, display/microphone availability, configured API key, and acknowledgment of automatic audio upload. The setup window explains each requirement and provides OS permission/settings buttons. Workspace actions and shortcuts stay disabled until every prerequisite is satisfied. Only the two permissions required for this recorder are requested.

The API key is a local Keychain generic-password item, read/written on a background queue. A failed or locked Keychain blocks completion with an error; there is no plaintext fallback. Only setup/consent booleans are stored in UserDefaults. The key can be saved before permission-related relaunches. Its syntax is checked locally; service authorization/quota cannot be guaranteed without a real request.

After setup consent, each newly started recording arms exactly one automatic transcription attempt. Successful movie finalization is followed by local audio-track/decode/level checks. Usable non-quiet audio proceeds directly to extraction and Qwen transcription, without another upload modal. Existing manual transcription and billed retry operations retain explicit consent. No automatic request is triggered simply by opening an older project or by a duplicate callback.

Missing audio, low signal, revoked prerequisites, cancellation, network errors or incomplete ASR timestamps preserve the recording/project and do not auto-retry. A quiet chunk discovered later in a long recording pauses before uploading that chunk and requests local review. Already completed chunk results remain available.

Permission and hardware checks run on returning to the app and immediately before recording. A revoked permission returns to setup before another recording; capture is still guarded by the recording engine. macOS may require an application restart for screen permission. Settings are available through the app menu (⌘,) and sidebar.

Tests cover each missing prerequisite, credential format, one automatic attempt per recording, quiet/failed/unready audio, cancellation and stale callbacks. The native setup smoke fixture injects permission/key-store results to verify blocked/ready states, failed credential saves, a single completion and visible controls, without modifying real permissions, keys or consent. Real macOS permission dialogs and Keychain access prompts still require device verification.
