# Verification

## Automated

`swift test` covers ASR schema, WAV guards/chunking, JSON/SSE finalization, cancellation, missing timing, exact offset addition, frame priority/multiple frames, persistence recovery, path traversal/symlinks, malformed files, Unicode/HTML escaping and self-contained exports. Network calls use stubs; no API key or billed request is required.

`ARCH=x86_64 scripts/build-app.sh` builds a release `.app`, ad-hoc signs it, checks the signature and Mach-O minimum OS/architecture, then packages a ZIP. GitHub Actions uses macos-15-intel. Additional native smoke checks decode a streamed 181-second PCM fixture into 180s + 1s chunks, verify safe retry, and render a deterministic AppKit review-window PNG without accessing the screen, microphone, or network. A successful build on macOS 15 is not a runtime test on macOS 11.

## Required device checks (not claimed tested)

Use a non-sensitive disposable project on the target Intel macOS 11.7.11, 8 GB Mac:

- Fresh permission denial, grant, quit/reopen; unavailable mic; revoked permission
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
