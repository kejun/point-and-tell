# Review cards and pen input · v0.3.1

## One grouping rule for the workspace and exports

Previously FrameMatcher produced one ReviewCard per provider sentence. A provider sentence can span a whole short recording. Only the HTML/Markdown renderer subsequently split that card by word timestamps and selected screenshots, so the editor could show one large card while the export showed several correct passages.

ReviewCardGrouping now materializes those same TranscriptAlignment moments before the cards reach the editor. Each card carries the original word-time boundaries, text (including whitespace), transcript reference and screenshot selection. HTML and Markdown use the same grouping operation. Exact excerpts remain recognized as word-timed passages even when their assigned screenshot falls just outside the narrower spoken-word interval; they are not rematched or collapsed during export. Equal-time screenshots remain together; screenshot-only moments keep no invented speech time.

New successful/partial transcription and opening an older project apply this idempotent grouping. The first card keeps its existing identifier, and subsequent cards receive distinct IDs. Reopening does not upload audio or redo transcription. Manually edited text or timing, missing word timing, and missing screenshot references are preserved for review rather than silently rewritten or dropped. No project schema migration is required.

## Pen interaction

The old drawing surface was a regular borderless NSWindow, which cannot become key by default. The app had moved to a nonactivating recording HUD, while the drawing canvas did not explicitly accept first clicks or take first-responder status. This left drawing input unreliable after switching to other apps.

Pen mode now uses a separate key-capable, nonactivating NSPanel, with explicit mouse input, first-click acceptance and a canvas first responder. The recording HUD remains non-key and above both the drawing surface and pen controls. Enter saves; Escape cancels. Save/cancel still complete at most once. A disconnected recording display produces an explicit error instead of silently making a bookmark when Pen was requested.

## Verification

Core regression fixtures compare editor cards with export moments, exact millisecond offsets, text/whitespace preservation, selected images, repeated opens, manual edits, missing timing/images, and equal-time/screenshot-only groups. The exported HTML/Markdown/JSON fixture checks two actual cards rather than two internal sections of one card.

Native smoke verification dispatches mouse-down/drag/up through the drawing window, clicks Undo/Clear/Save, checks the saved PNG contains a red stroke, routes Escape through the responder chain, and verifies the recording HUD stays visible. A native workspace fixture verifies each generated card has the expected editor text and image. WebKit checks one passage per card at desktop and narrow widths. These automated tests use synthetic images and do not capture a private desktop; physical-device full-screen/Spaces behavior still requires a device check.
