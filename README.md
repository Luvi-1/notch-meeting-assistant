# Notch

A native macOS listening companion for lectures, classrooms, conversations, meetings, interviews, study and presentations. Start Listening without choosing a context. A compact notch shows listening activity; detected questions briefly widen it horizontally. A separate native window holds Home, Sessions, Notes, Search and Settings.

## Build

Requires macOS 15+, Xcode 16+ and Swift 5.9 or newer. No third-party package dependencies.

```sh
swift test
bash scripts/build-app.sh
open "dist/Notch Meeting Assistant.app"
```

The bundle identifier remains `com.luvi.notchmeetingassistant`, preserving the previous app's Keychain identity and settings migration. Version 0.2.0 is packaged as a universal Apple Silicon / Intel development app, ad-hoc signed, not notarized. Use the packaged app so macOS associates permissions with the bundle.

## Listening and the notch

Open Notch from its menu bar item. Confirm permission from the people being transcribed, then Start Listening. New installations default to microphone input, so a classroom does not require Screen & System Audio Recording permission. Enable system audio in Settings → Listening for apps. The two inputs are distinct and can both be enabled.

The small bar shows real audio activity, elapsed time and Stop. A detected question widens the notch into a low horizontal preview with Answer, Save and Expand controls. Hovering a preview holds its size so its buttons do not move away from the pointer. Expand opens the session window. Preview expiration, explicit dismissal, display geometry and Reduce Motion are respected. Automatic assistance never activates another app's window.

Question Assistance has Off, Detect only, Detect + suggested answer, and Automatically answer questions. Classification is performed by the Quick Commands model on changed speech after a pause, with bounded frequency during continuous speech. Meaning, rather than a question mark alone, is evaluated. Questions must quote a known transcript passage and return a confidence score. Other moments (exam mentions, assignments, definitions, examples, formulas, deadlines, actions and decisions) are tagged silently. Suggested answers remain text-only; Automatic follows Text / Voice / Both. Manual questions are always available.

## Providers and task models

Settings → AI Providers supports OpenAI Responses, native Anthropic Messages, native Gemini streaming, OpenRouter, Groq LLMs, OpenCode Zen, and a custom endpoint. Catalogs are loaded from the selected provider, with an exact model-ID field for custom servers and newly available models. Saving a key does not claim the connection is verified; testing the catalog marks that connection check. Actual model access is established by an inference request.

OpenCode Zen is a real gateway integration, not an invocation of the OpenCode CLI. Its model families use Responses, Messages, Gemini or Chat Completions endpoints; explicit format selection is available. Non-text System One models are rejected. Custom remote endpoints require HTTPS; unencrypted HTTP is restricted to exact loopback hosts. Redirects are rejected, keeping credentials and session text at the configured endpoint.

Each task can independently select a provider and model: Live Question Answering, Session Summary, Deep Analysis, Quick Commands and Ask Your Memory. Auto selects among providers with a saved key and chosen model (or an explicitly configured local server). It never automatically retries a failing provider through another service. Existing OpenAI model and Astra Ultrafast preferences migrate. Ultrafast is an optional, higher-priced Astra API tier; API billing is separate from ChatGPT.

Keys live in macOS Keychain under separate provider accounts. Saved keys are not loaded into editable fields or preferences, and replacement fields are cleared after saving.

## Transcription

- Auto uses Groq when its key is configured; otherwise Apple Speech.
- Groq supports Whisper Large V3 and Large V3 Turbo, with model discovery.
- OpenAI supports Whisper and compatible transcription models, including supported diarization output.
- Local Whisper connects to a **running whisper.cpp server on this Mac**, with a model already loaded. Set its loopback base URL, normally `http://127.0.0.1:8080`; Notch calls `/inference`. No model binary is bundled, silently downloaded, or represented as already installed.
- Custom transcription accepts an OpenAI-compatible `/audio/transcriptions` endpoint and a separate Keychain key.

Whisper file APIs are implemented using ordered audio chunks, not a native realtime WebSocket. Audio is resampled to 16 kHz mono WAV in memory. The configurable chunk duration, a short quiet-boundary allowance, and a bounded queue control latency and memory. Quiet chunks are skipped using a configurable threshold; provider silence metadata is respected. Stop drains final queued audio before closing the session. Backpressure or provider failures stop capture with an explicit gap warning rather than silently pretending that all audio was transcribed.

Automatic language detection omits the language parameter for cloud Whisper and uses `auto` for local Whisper. Apple Speech requires a selected locale and cannot be presented as automatically detecting languages. On-device-only mode restricts transcription to supported Apple Speech or Local Whisper; it does not prevent text from being sent to the configured AI provider.

Audio sources are labeled **Microphone** and **System audio**, not invented identities such as Professor or You. If a diarization model returns speaker IDs, they are labeled as clip-scoped. The app does not claim that Speaker A in one chunk is the same person in another. Users can label an individual passage.

## Sessions, notes and memory

Full transcripts are retained rather than a last-120-segment window. Partial recognition replaces a passage while preserving its bookmarks and notes. Sessions are atomically saved in `~/Library/Application Support/Notch/Sessions`, with owner-only file permissions. Interrupted sessions are recovered on launch; malformed files are preserved and reported, not deleted or overwritten. These files are local JSON, not independently encrypted by the app.

Passages support Ask, Explain, Summarize, Bookmark, Copy, Create a note and manual speaker labels. Sessions can be renamed, exported as Markdown or explicitly deleted. Summary generation processes all transcript chunks for long sessions, then produces a lecture, meeting or other appropriate structure with source references. The original transcript is always shown separately. Generated study questions are labeled as suggestions.

Question context prioritizes recent speech, relevant older passages, important concepts and matching notes within a bounded context budget. Search combines local Apple Natural Language sentence embeddings (when available for the language) with exact-word matching; the app identifies the fallback when embeddings are unavailable. Search covers transcripts, questions, answers, summaries, notes, bookmarks and classified assignments/actions. Ask Your Memory retrieves a bounded set of matching excerpts, asks the assigned model for a grounded answer, and exposes clickable session/time references. Retrieval is not an exhaustive audit of every statement, and the model is instructed to acknowledge missing evidence.

## Practical limits

A successful build and deterministic tests verify code paths, request contracts, persistence and packaging. They do **not** establish live microphone accuracy, cloud-provider account access, diarization quality, semantic classification quality, physical-notch animation appearance or response latency on a user's Mac. These need an interactive run with the actual devices and credentials.

Cloud API calls use the configured account and may incur charges. Groq has a minimum billed audio duration per request; short chunks can therefore cost more than their duration suggests. Transcription pauses while the app speaks to avoid responding to its own voice, so speech during playback is not transcribed. No stealth-recording, screen-sharing evasion, permissions bypass, or hidden capture mode is included.

## Primary API references

- [OpenAI Ultrafast](https://developers.openai.com/api/docs/guides/ultrafast-mode)
- [OpenAI speech transcription](https://developers.openai.com/api/docs/guides/speech-to-text)
- [Groq speech-to-text](https://console.groq.com/docs/speech-to-text)
- [Anthropic streaming](https://platform.claude.com/docs/en/build-with-claude/streaming)
- [Gemini generation](https://ai.google.dev/api/generate-content)
- [OpenRouter API](https://openrouter.ai/docs/api-reference/overview)
- [OpenCode Zen](https://opencode.ai/docs/zen/)
- [whisper.cpp server](https://github.com/ggml-org/whisper.cpp/tree/master/examples/server)
