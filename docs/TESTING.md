# Verification

Pause/resume (#12) adds 50-cycle core and native fake-output checks, transition timeout/Stop/delegate races, paused HUD and drawing checks, final video decode validation, and an opt-in native 10+30+8-second capture probe. See [PAUSE-RECORDING.md](PAUSE-RECORDING.md) for checks and remaining Big Sur/device/performance acceptance. An unavailable probe is unverified, not passed.

## Automated

`swift test` covers ASR schema, WAV guards/chunking, JSON/SSE finalization, cancellation, missing timing, exact offset addition, frame priority/multiple frames, persistence recovery, path traversal/symlinks, malformed files, Unicode/HTML escaping and self-contained exports. Network calls use stubs; no API key or billed request is required.

`ARCH=universal scripts/build-app.sh` builds a release `.app`, ad-hoc signs it, checks the signature and both Mach-O slices’ minimum OS/architectures, then packages a ZIP. GitHub Actions uses macos-15-intel (x86_64) and macos-15 (arm64), compiling both slices and running tests natively on each architecture. Additional native smoke checks create real AAC-in-MOV sine fixtures through AVAssetWriter at 44.1 and 48 kHz, both short and crossing 180 seconds. They check 16 kHz mono PCM WAV format, nonzero RMS/peak and tone preservation, durations and contiguous movie-relative offsets, delayed audio, silent audio, video-only/corrupt files, and non-destructive retry. The production inspector must accept both MOV and extracted WAV; silence is advisory while missing/empty/undecodable tracks fail. Pure capture tests cover bounded meters and the rule that a saved partial file cannot hide an error. A deterministic AppKit review-window PNG is rendered without accessing the screen, microphone, or network. A successful build on macOS 15 is not a runtime test on macOS 11.

## Required device checks (not claimed tested)

Use a non-sensitive disposable project on the target Intel macOS 11.7.11, 8 GB Mac:

- Fresh permission denial, grant, quit/reopen; unavailable mic; revoked permission
- Choose built-in mic explicitly, choose system default, then change the system input before starting: verify the displayed recording device is the one actually used
- Speak during a 10-second disposable recording: meter responds; Stop completes local decode check; local player audibly reproduces speech
- Mute/lower input volume: low-level warning appears without claiming speech detection; no low-level audio uploads unless explicitly continued
- Unplug the explicitly chosen mic before start and during capture; never silently substitute a different device; preserve the partial movie and show the recording failure
- Reopen a v0.1.0 silent/video-only project; no readable audio must block ASR, and every saved retry WAV is checked before upload
- Cancel the low-level warning/upload dialog; retry; close/reopen the playback window; start a new recording after playback (playback must stop)
- Try a safe rejected API request only with user-approved key/billing scope: confirm stage/status/code/request ID are useful and no raw provider response/key is persisted
- Start once, double-click start, stop once, double-click stop, new recording, reopen old project
- Single Retina screen, external screen, differing scaling; pointer ring and pen position align with target pixels
- Say a visible stopwatch number while bookmarking at 5 fps and 10 fps. Compare stored anchor time, extracted frame and spoken text; inspect initial mic offset
- Draw/undo/clear/cancel/save; voice continues; pen screenshot has no controls; normal interaction resumes
- Sleep/unplug display/mic, near-full disk, forced quit; retain original files, reopen project, no overwrite
- Cancel during local extraction and during ASR. Completed chunks retained, retry does not resend completed chunks
- Real provider short (<1 min JSON) and >1 min SSE calls with explicit user-controlled billing/key consent; confirm full text, timestamp units, endpoint/model/workspace compatibility
- Long utterance has multiple frames; bookmarks/pen frames win; untimed results remain clearly manual
- Edit manual cards before ASR, retry failed ASR, verify edits remain; select multiple frames and remove them
- Open HTML fully offline; no remote requests; dangerous text such as `<script>` renders as text. Open separate PNG bundle with target model input path

## 10-minute performance benchmark

Record a normal scrolling/clicking workflow with voice at 5 fps, then repeat at 10 fps if desired. Use Activity Monitor to record process CPU, memory and energy at start, 2, 5 and 10 minutes; note dropped frames, responsiveness, thermals and output size. Confirm memory remains bounded rather than growing with duration. Inspect audio/video sync and MOV recoverability. Measure actual encoder behavior with supported platform tools before claiming hardware acceleration. CI does not establish a performance budget.

## Evidence labels

Report separately: authored tests, tests executed/passed, macOS compiler result, package/signature verification, real device runtime, provider integration. Never describe unrun checks as passed.


## v0.2.0 native workspace

- Verify the chosen green app icon in Finder, Dock, About and the workspace sidebar after replacing an older copy.
- At 980×680 content size and in dark appearance, inspect labels, list selection, editor scrolling and recording-toolbar bounds.
- Type into one card, change its timing, switch cards, reopen the project and export: verify text and valid times persist. Invalid times must keep focus on the draft until corrected.
- Select a card without images: its preview must be empty. Choosing a project screenshot only previews it; Add/Replace must explicitly change the exported attachment.
- During transcription, ensure the cancel action is visible and conflicting new/open/edit/export actions are disabled. After cancellation, valid actions return.


## v0.3.0 workflow and frontmost recording toolbar

- Fresh launch: the workspace and its menu shortcuts must remain unavailable until screen recording, microphone, connected devices, API key and automatic-upload consent are ready. Test denied permissions, permission-related relaunch and locked Keychain; failed saves must not admit the user.
- Relaunch: reuse the saved key through Keychain, recheck current permissions/devices, and return to setup when a requirement is revoked. No remote request merely from launch or opening an old project.
- Record and stop: valid speech automatically transcribes once; quiet/invalid audio pauses; cancel or failed requests do not automatically retry. Test a long recording with a quiet later chunk.
- While recording, switch apps with ⌘Tab, click other windows, change Spaces, enter another app's full-screen Space, and use multiple displays. The HUD remains frontmost and draggable, does not take typing focus, and Stop still works.
- Mark and enter pen mode: HUD must not blink or disappear; saved bookmark/pen PNGs must exclude controls. Stop during drawing must save the annotation and finalize exactly once. On stop/failure the HUD must disappear and not return after a Space change.
- Native automated smoke tests exercise setup with injected permissions/key storage and verify panel policy, rendering and cleanup. They cannot prove real OS TCC, Keychain prompts or cross-application full-screen behavior; use physical macOS 11 and current macOS devices for those checks.


## v0.3.1 card grouping and pen regression

- Record several spoken passages with screenshots. After automatic transcription, compare each card's text/time/image with the independent HTML and Markdown exports; do not accept one combined editor card with multiple exported passages.
- Reopen an unedited v0.3.0 project: regroup from stored word times with no API request. Repeat the open, edit one split card, then reopen/export: no duplicate cards, lost whitespace or overwritten edits.
- From another foreground application, click Pen once and draw immediately. Verify visible strokes, Undo, Clear, Enter/Save, Escape/Cancel and Stop during annotation. The recording HUD must stay above both pen windows and remain clickable.
- Disconnect the chosen display while recording: requesting Pen must explain the missing display and must not silently create a normal bookmark.


## Screenshot-first cards (#10)

Follow [SCREENSHOT-CARDS.md](SCREENSHOT-CARDS.md) for the source/clock trace and device limits. The screenshot core suite and SCREENSHOT_CARD_UI_OK native fixture cover card creation before ASR, real timestamp granularity, stable IDs, deletion/edit persistence, no automatic frame extraction, and atomic manual extraction/save failure. Device speech/screenshot alignment remains a separate check.


## Complete transcript partition (v0.5.1)

- Three screenshots plus three sentence-only ranges that cross screenshot midpoints must produce three nonempty editable cards. Same-time images, overlapping pen sessions, missing times and speech farther than 12 seconds must retain all text.
- Verify exact source span coverage, including punctuation, whitespace and composed Unicode: every source character appears once in original order. No synthetic word timestamps; sentence-only excerpts retain their original enclosing interval.
- Reopen a v0.5.0 project with untouched ambiguous cards: regenerate locally from saved transcription without uploading audio. Edited cards and deliberate deletions remain unchanged.
- Use the first/last sentence movement buttons under the text field. Both cards save together; busy state, empty source, first/last boundaries and failed writes must leave unavailable operations disabled or unchanged. Reopen and export the edited result.
- The native smoke fixture prints TRANSCRIPT_PARTITION_UI_OK after checking complete drafts, adjacent moves, busy controls and failed-save protection. It uses local fixtures without ASR calls.
- The separate Intel capture-pause probe is unchanged; its existing failure does not become a passing segmentation test or a verified capture path.
