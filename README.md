# Notch

A native macOS listening companion for lectures, classrooms, conversations, study sessions, interviews, presentations and meetings. Start listening without choosing a session type. The app transcribes in the background, notices questions and useful moments, and turns each session into a source-linked review page.

Requires **macOS 15+ and Xcode 16+**. Built with SwiftUI, AppKit, AVFoundation, ScreenCaptureKit, Speech and NaturalLanguage; no third-party package dependencies.

## Build

```sh
swift test
bash scripts/build-app.sh
open "dist/Notch Meeting Assistant.app"
```

Open `Package.swift` in Xcode to edit. Launch the packaged app so macOS can associate audio permissions with its stable bundle identifier. The existing executable name, package name, bundle identifier and distribution path are retained for upgrades; the display name is now **Notch**.

GitHub Actions tests the core and preference migration, then packages a universal Apple Silicon / Intel app. The workflow artifact contains `Notch-Meeting-Assistant.zip`.

## The experience

**Home** is a compact charcoal command surface with a dominant Start Listening action, recent sessions and a Continue Reviewing entry. Simple top navigation replaces the permanent sidebar. A new installation listens through the microphone; system audio is independently optional. Start Listening begins capture without an agreement checkbox or a Meeting / Lecture / Conversation picker. macOS still handles microphone, Speech and system-audio permissions where required.

Starting hides the main window and leaves a small black indicator by the physical notch. On displays without a camera cutout it becomes a floating pill. A detected question reveals a shallow, horizontally expanded surface with the question, an optional short answer and Answer / Save / Expand controls. Answer stays at the notch; Expand opens the dedicated review window. Other moments are collected silently. Previews expire, explicit dismissal is respected, pinning holds the preview, and Reduce Motion disables animated transitions.

**Question Assistance** has four settings:

- **Off:** no question previews or automatic answers.
- **Detect only:** show detected questions; request an answer explicitly.
- **Detect + suggested answer:** automatically show a brief suggestion.
- **Automatically answer questions:** generate a fuller answer, with optional voice output.

With an enabled AI provider, a semantic classification request confirms questions and requests for explanation. This handles speech such as “Can anyone explain…” and “Wait, how does that work?” without requiring a question mark. An explicit local candidate detector is used when no model is configured or an automatic classification request fails. A failed automatic analysis is not repeatedly retried; a successful provider check or routing change re-enables it.

## Sessions, notes and memory

The full authoritative transcript is saved locally; the compact live buffer does not truncate saved history. Each passage has its original source label and timestamp, with subtle moment categories. Passage actions support asking, explaining, summarizing, copying, bookmarking and creating a note. Recognition corrections update existing passages and remove obsolete machine-extracted moments.

Questions, important statements, exam mentions, assignments, deadlines, definitions, formulas, examples, explanations, decisions, actions and topics feed the review page. The app infers a suitable lecture, meeting or general conversation structure. Stopping immediately saves an extractive local outline, then generates an AI summary when configured. Long sessions are summarized in bounded batches covering all transcript passages. Summary sections retain source IDs and can jump back to the transcript. Failed or invalid AI output leaves the local outline available; Regenerate summary can retry explicitly.

**Search** covers transcripts, summary sections, questions, moments, notes and bookmarks. It uses Apple's on-device sentence embeddings when available, combined with keyword matching. The UI identifies the keyword-only fallback when the language model is unavailable. Queries containing “today” or “this week” scope the session dates.

**Ask your memory** retrieves relevant saved passages before asking the selected analysis model. Answers request numbered citations; the immutable source list below each answer opens the originating session and passage. Changing the separate search query cannot relabel a previous answer's sources. Retrieval is an evidence sample, so the assistant must acknowledge incomplete coverage.

## Transcription providers

| Setting | Behavior |
| --- | --- |
| Auto — Recommended | Preserves Apple Speech as the audio destination. Adding an LLM key does not switch audio to another provider. |
| Apple Speech | Live Apple recognition; optional on-device-only processing where supported for the chosen locale. |
| Groq | Whisper WAV transcription, including `whisper-large-v3` and `whisper-large-v3-turbo`. Fetch available speech models or enter a model ID. |
| OpenAI | Whisper / transcription API models selected independently of the answer model. |
| Local Whisper | A running, user-configured OpenAI-compatible Whisper server on this Mac. Default base URL: `http://127.0.0.1:8080/v1`. This app does not bundle model weights or install a server. |
| Custom | A configurable compatible transcription endpoint, model and separate Keychain credential. |

Cloud Whisper APIs receive short, speech-aware WAV chunks. This is incremental chunk transcription, **not** a claim that Whisper file endpoints provide a native live audio socket. Audio conversion, a bounded queue, silence handling and overlap metadata belong to capture, not the UI. Stop drains the final audio with a bounded deadline; Finish now cancels outstanding work and reports that only received text was saved.

The language can be selected explicitly or detected by the selected Whisper engine. Apple Speech uses its selected locale. Basic Whisper and Apple Speech identify the audio input. Models that supply complete, valid speaker segments also show anonymous voices, for example `Microphone · Voice A · clip 7`. Voices are scoped to each clip; Voice A in another clip is not assumed to be the same person. The app never guesses a professor's or participant's name. Incomplete or invalid speaker metadata falls back to the complete source-labelled transcript, preserving the text.

## AI providers and task routing

Settings → AI Providers supports:

| Provider | API integration |
| --- | --- |
| OpenAI | Responses API, including the existing explicit Astra / Ultrafast option. |
| Anthropic | Native Messages API and streaming text events. |
| Google Gemini | Native `generateContent` / `streamGenerateContent`, API-key header and model discovery. |
| OpenRouter | Compatible chat plus model discovery and its authenticated key check. |
| Groq | Compatible LLM chat, separately from Groq Whisper transcription. |
| OpenCode Zen | Configurable gateway protocol: Responses, Messages, chat or native Gemini as required by the chosen model. |
| Custom | Base URL, model, API protocol and optional local-server credential. |

Model IDs shown initially are suggestions, not a fixed catalogue. Fetch models or enter the ID available to your account. OpenCode models use different wire protocols; select the matching protocol if model metadata does not identify it. A successful catalogue/endpoint check does not guarantee generation access, credit or model availability.

### Groq connection setup and recovery

Groq uses the base URL `https://api.groq.com/openai/v1`. Language models use `POST /chat/completions`, speech models use `POST /audio/transcriptions`, and model discovery uses `GET /models`, all relative to that base. The default language model is `llama-3.3-70b-versatile`; the default transcription model is `whisper-large-v3-turbo`.

Settings separates **AI providers → Groq** from **Transcription → Groq Whisper**. Built-in connections use their provider defaults; custom servers have separate configuration. Changing the speech provider resets its provider-specific URL and model while retaining language preferences. Existing recognizable OpenAI/Groq leftovers migrate automatically. Common pasted Groq root and full-operation URLs are normalized so paths cannot be duplicated. Unknown hosts and unsafe URLs fail before credentials are sent.

If an older saved configuration still fails, use **Restore defaults** in Groq's provider settings and **Restore provider defaults** in Transcription, then fetch the relevant models. Check any explicit Groq overrides in **Task models** as well. A 404 now identifies whether model discovery, language generation, or transcription failed. A model-list connection check sends no completion model, so a failure there is distinct from selecting an unavailable generation model.

Assign separate providers and models to **question detection**, **live question answering**, **session summaries**, **deep analysis** and **quick commands**. Auto chooses among enabled, configured providers with task-specific preferences and their selected models. Explicit assignments fail clearly when unavailable; the app does not silently send a failed request to a different provider.

Credentials are stored in **macOS Keychain** and are never loaded into the editable key fields. Saved provider settings and session JSON contain no API keys. Groq/OpenAI transcription uses the corresponding provider credential; custom transcription has a separate Keychain entry. Network sessions are ephemeral, credentials cannot follow redirects, and nonlocal endpoints require HTTPS. Local Whisper is restricted to loopback.

## Data and permissions

Audio stays in bounded memory buffers and is not saved as a recording. Apple Speech may process audio on Apple's servers unless on-device-only recognition is selected and supported. A selected cloud transcription provider receives audio chunks; AI tasks receive bounded relevant transcript context. OpenAI Responses requests set `store: false`. Provider billing, data handling and access still follow your API account.

Sessions, summaries, notes and bookmarks are saved atomically under `~/Library/Application Support/NotchListeningAssistant/Sessions`, with user-only file permissions. These are ordinary local files, not an additional encrypted vault. App settings remain in UserDefaults and credentials remain in Keychain. The previous OpenAI Keychain account and existing audio/model preferences migrate in place.

Microphone-only use does not request system-audio capture. Selecting System audio requires Screen & System Audio Recording access. A denied capture has a recovery link to System Settings. The listening indicator remains visible while capture is active. Spoken answers temporarily suppress recognition to avoid feedback, so speech during playback is not transcribed; text is the default output.

## Verification and practical limits

Tests use deterministic fixtures and temporary session folders. They cover provider request formats and SSE completion, credential/endpoint validation, Groq routing and saved-settings repairs, speech chunk boundaries and finalization, anonymous speaker segments and metadata fallback, unpunctuated questions, partial revisions, multiple questions per segment, stale moments, source validation, unsupported dates, bounded contexts, full-session persistence, calendar search and preference migration. No test sends a paid generation request.

CI also renders the actual SwiftUI Home, transcript, review, notes, memory, provider settings and notch views into the **Notch-Design-Previews** artifact. These use fictional in-memory fixtures through a debug-only initializer that skips Keychain, stored sessions, timers, capture and network access. To reproduce on a development Mac, run `NOTCH_PREVIEW_DIRECTORY="$PWD/dist/Previews" swift test --filter DesignPreviewTests`. See [design notes](docs/DESIGN.md) for the reference study and visual decisions.

Compilation and packaging do not verify real microphone acoustics, third-party model access, physical-notch positioning, or animation quality on a user's display. Those require an interactive macOS run. Real-time accuracy depends on the audio source, language, selected provider and network. Semantic classification and source citations reduce avoidable mistakes but cannot establish that every generated explanation is correct. The app cannot see a classroom board or infer an unspecified diagram from audio alone.

## Architecture and official references

See [architecture](docs/ARCHITECTURE.md) for the capture → transcription → intelligence → review pipeline and extension points.

- [Apple audio conversion](https://developer.apple.com/documentation/avfaudio/avaudioconverter)
- [Apple sentence embeddings](https://developer.apple.com/documentation/naturallanguage/nlembedding)
- [Groq speech-to-text](https://console.groq.com/docs/speech-to-text)
- [OpenAI speech-to-text](https://developers.openai.com/api/docs/guides/speech-to-text)
- [OpenAI Ultrafast](https://developers.openai.com/api/docs/guides/ultrafast-mode)
- [Anthropic Messages](https://platform.claude.com/docs/en/api/messages/create)
- [Gemini content generation](https://ai.google.dev/gemini-api/docs/generate-content)
- [Gemini models](https://ai.google.dev/api/models)
- [OpenRouter](https://openrouter.ai/docs/quickstart)
- [OpenCode Zen](https://opencode.ai/docs/zen/)
