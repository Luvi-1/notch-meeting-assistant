# Listening companion architecture

## Boundaries

`MeetingCapture` owns the microphone, optional system-audio stream and suppression during voice output. Microphone-only capture uses AVAudioEngine without a ScreenCaptureKit permission request. Capture feeds either Apple Speech channels or a speech-aware PCM/WAV queue. `TranscriptionProvider` exposes transcription, ordered chunk processing, model discovery and key validation; HTTP adapters live in `NotchCore`.

`MeetingModel` coordinates the session lifecycle on the main actor. Capture callbacks are guarded by a session token. Stop retains that token until final transcription is received, then commits the completed session. Full transcript text is written to `ListeningSession`; `TranscriptStore` remains a bounded convenience buffer. Debounced atomic autosaves protect the authoritative record throughout a session.

`SessionIntelligence` classifies sources, extracts moments and validates generated structures. Source UUIDs and copied excerpts tie machine-extracted moments to current transcript text. Recognizer corrections remove stale moments; prefix revisions preserve identity, while distinct questions in one recognition segment remain distinct. A successful semantic classification drives the question preview; local detection is the explicit fallback. Duplicate/cooldown guards and response IDs prevent repeated or stale answer updates.

`SessionContextSelector` composes recent passages, relevant older passages, topics and relevant notes within a fixed character budget. Live questions and passage commands use this context. Summaries process source-labeled batches and merge compatible sections. A transcript version check prevents an older summary from replacing changed source material. A source-validating parser checks IDs and explicit dates; it cannot prove every generated paraphrase.

`MemoryStore` persists one versioned JSON envelope per session using atomic writes. It searches full transcripts, moments, summaries, notes and bookmarks. NaturalLanguage sentence embeddings are optional local capabilities; embedding access is serialized and cached. Keyword fallback is explicit. Search executes off the main actor, returns stable source links and supports date scopes. Ask-memory keeps its own immutable retrieval snapshot so ongoing search does not alter numbered citations.

`LLMProvider` exposes completion, streaming, models and credential validation. `LLMService` adapts OpenAI Responses, compatible chat, native Anthropic and native Gemini. `ProviderConfiguration` contains nonsecret settings; `APIKeyStore` is the macOS-only Keychain boundary. `ModelSelection` maps each `AITask` to a selected model or Auto. Provider failures never silently reroute transcript data.

`NotchPresentation` controls compact/preview/expanded state, pinning, hover and dismissal timers. `AppDelegate` owns camera-safe window geometry and a separate standard review window. Every noncompact notch state is shallow; large content, settings and editing belong to `CompanionWindow`.

## Adding a provider

Implement `LLMProvider` or `TranscriptionProvider` outside SwiftUI. Add its nonsecret defaults and model catalogue handling, associate a distinct Keychain account, and wire it into task/capture resolution. Use capability-accurate APIs: file chunking is not a native streaming socket; input channels are not named human speakers. Provide fixture tests for request serialization, auth headers, completion boundaries, unsupported capabilities and error redaction.

## Concurrency and validation

UI/session coordination uses the main actor. Network requests suspend rather than blocking it. Search uses a background task and a serialized embedding cache. Source snapshots, session IDs and response IDs protect against stale completion. Audio queues are bounded; stop completion is bounded and reports canceled/pending work explicitly.

The GitHub workflow compiles/tests on macOS 15 and packages both supported CPU architectures. Provider fixtures make no live paid API requests. Interactive checks still needed on a Mac: first-run permissions, microphone and app audio, source switching, actual account/model access, physical notch/external monitor behavior, Reduce Motion, voice suppression, and stop during an in-flight transcription.
