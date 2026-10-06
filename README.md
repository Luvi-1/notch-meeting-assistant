# Notch Meeting Assistant

A native macOS meeting assistant that lives in a compact black notch. Hover to expand, read live answers in a temporary preview, and move away to collapse. Includes live transcription, Automatic or Manual answers, and Text / Voice / Both output.

Requires macOS 15 or later and Xcode 16 or later to build. Uses Apple's ScreenCaptureKit and Speech frameworks, native speech synthesis, and an OpenAI API key stored in Keychain. No third-party package dependencies.

## Build and open

```sh
swift test
bash scripts/build-app.sh
open "dist/Notch Meeting Assistant.app"
```

Open `Package.swift` in Xcode to edit. Start with the packaged `.app`, not `swift run`, so macOS can associate recording permissions with the app. The GitHub Actions workflow tests and packages a universal Apple Silicon / Intel app.

## The notch

The app starts compact. Hover or click to open it; moving away collapses it after a short grace period. New answers reveal a small streaming preview, which closes eight seconds after completion. Click Open answer to read the full response. Pin keeps the expanded panel open. Typing and Settings also keep it open. Escape, the collapse button, or clicking another app dismisses an unpinned panel. Dismissing a response is respected when its remaining tokens arrive.

The panel fits the physical camera cutout and expands with native window animation. Displays without a notch use a floating pill. Reduce Motion disables the animated transitions and listening pulse. Listening and Stop remain available in the compact state.

## Set up and use

In Settings, save an OpenAI API key, select the speech language, optionally include your microphone, and choose the meeting app or all system audio. Confirm everyone in the meeting agrees to transcription, then press Start meeting. macOS requests Speech Recognition, Screen & System Audio Recording, and (when selected) Microphone access.

The default answer model is **GPT-6 Astra**, with **Ultrafast** enabled. The app uses `gpt-6-astra` on the Responses API, `service_tier: "ultrafast"`, and low reasoning effort. Ultrafast is a higher-priced API tier; turn it off in Settings to use the standard tier. A ChatGPT subscription does not cover API usage. Model access, API credit, and rate limits depend on your API account. The app reports service errors and does not silently retry on a different model or tier. Existing installations migrate the previous shipped model default while retaining custom model and audio choices. The Use GPT-6 Astra button selects Astra explicitly.

Automatic mode answers new speech after a configurable pause and avoids submitting the same passage twice. Manual mode transcribes continuously and answers only when you press the arrow button (Answer now), Command-Return, the menu's Answer now item, or submit a typed question. Answers stream on screen in Text and Both modes. Voice and Both read completed answers through the Mac's selected output. Stop voice interrupts speech; Stop meeting stops capture and cancels pending answers.

## Recording permission

A message that the user declined capture means macOS has not granted Screen & System Audio Recording access. Use Open Privacy Settings in the error message, enable Notch Meeting Assistant under Privacy & Security → Screen & System Audio Recording, then quit and reopen the app. You can also open this pane from the app's audio settings. The app never changes permission grants automatically.

## Data and limitations

Audio is not saved to disk. Apple Speech may process audio on Apple's servers unless on-device recognition is enabled and supported for the selected language. Recent transcript text and any meeting context you enter are sent to OpenAI to generate answers; API usage is billed to your API account. Requests set `store: false`. Transcripts and answers remain in memory until cleared or the app quits. Settings are local; the API key is in Keychain.

Use headphones for spoken answers. Recognition pauses during speech playback to prevent feedback, so speech occurring during playback is not transcribed. Automatic answers follow pauses in new speech rather than a guarantee that every utterance is a question. Latency and transcription accuracy depend on audio quality, language, the selected model, and the network. There is no hidden-recording or screen-share-evasion feature.

This is an independent implementation visually inspired by [Boring Notch](https://github.com/TheBoredTeam/boring.notch) and compact dynamic-island interactions; no upstream source or assets are copied.

## Verification

Run `swift test` for transcript and automatic-answer checks, hover/preview/dismissal behavior, typing/settings/pin protection, request validation, and byte-framed Responses API streaming. Tests use deterministic state and response fixtures; they do not send paid API requests.

A successful macOS build verifies compilation and packaging. Live meeting audio, permission recovery, actual Astra latency, visual animation, and physical display behavior still require an interactive run on a Mac with an API key.

API references: [Ultrafast mode](https://developers.openai.com/api/docs/guides/ultrafast-mode), [Using GPT-6](https://developers.openai.com/api/docs/guides/latest-model).
