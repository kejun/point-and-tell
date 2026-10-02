# Qwen Audio 3.0 transcription · v0.3.0

The model identifier was already `qwen-audio-3.0-asr-flash`. This update changes the request mode and the definition of successful transcription, rather than claiming a model-name replacement.

## Request

Follow the [specified model page](https://www.qianwenai.com/models/qwen-audio-3.0-asr-flash):

- POST `https://maas.qianwenaiapi.com/api/v1/services/aigc/multimodal-generation/generation`
- Model `qwen-audio-3.0-asr-flash`; `X-DashScope-SSE: disable`; `Accept: application/json` for every duration. Long audio no longer silently enables SSE.
- Audio-only `input.messages[].content[].input_audio.data`, a 16 kHz mono PCM WAV Base64 data URI; `parameters.format=wav`, `sample_rate=16000`.
- Sequential ~3-minute chunks; after first-run consent, new recordings automatically transcribe when stopped. No text-chat model, video/image upload, or automatic billed retry. [Setup flow](FIRST-RUN.md).

Streaming itself does not imply missing timestamps: the [response protocol](https://help.aliyun.com/en/model-studio/fun-asr-flash-recorded-speech-recognition-http-api) also documents timestamped final SSE sentences. The parser retains compatibility with valid finalized SSE responses if a server returns them, but the application now requests final JSON as shown on the specified model page.

## Completion contract

A live chunk succeeds only if every nonempty sentence has valid start/end timestamps and a nonempty, monotonic, in-range word timeline covering all recognized text (ignoring whitespace only). Missing, partial, unstable, or text-mismatched word timing fails with a safe `incompleteTimestamps` diagnostic. A full transcript accompanied only by the final sentence's times cannot silently become completed cached work.

The original provider milliseconds are converted to seconds and the chunk's recording offset is applied exactly once. These same persisted values drive HTML/Markdown screenshot alignment. No timestamps are estimated from text length or request-arrival time.

## Older projects

The transcription button shows **重新转写 · 补齐时间戳** if completed chunks lack a complete word timeline. The existing upload dialog states how many completed chunks will be resent and that this may incur usage charges. Only after consent are those chunks queued. Fully timed completed chunks are reused.

Old text, card edits and image selections remain intact through cancellation or a failed retry. A successful replacement retains matching sentence identities and reviewed selections. Untouched empty-image cards are rebuilt after local frame extraction. If sentence boundaries change, reviewed cards remain manual cards; the app does not attach another sentence's timestamps to edited text.

## Verification boundary

Automated fixtures verify the exact model/endpoint/headers for 1s, 59s, 60s and 180s inputs, complete JSON timing, rejected text-only/partial replies, no automatic retry, recording-relative persistence and preservation of reviewed cards. Native UI smoke checks the repair button label. No account key or real paid provider request was available during implementation, so actual service acceptance and ASR alignment accuracy are not claimed. If the service supplies only final-sentence timing in JSON, the application reports the incomplete response rather than fabricating the missing timeline.
