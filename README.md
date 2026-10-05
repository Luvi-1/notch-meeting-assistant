# Notch Meeting Assistant

A native macOS meeting assistant in an expandable black notch panel. Live transcript, streamed answers, Automatic or Manual triggering, and Text / Voice / Both output.

Requires macOS 15 or later and Xcode 16 or later. Uses Apple's ScreenCaptureKit and Speech frameworks, native speech synthesis, and an OpenAI API key stored in Keychain. The model can be changed in Settings.

## Build and open

```sh
swift test
bash scripts/build-app.sh
open "dist/Notch Meeting Assistant.app"
```

Open `Package.swift` in Xcode to edit. Start with the packaged `.app`, not `swift run`, so macOS can associate recording permissions with the app.

## Use

Open the notch panel or its menu bar item. In Settings, save an API key, select the speech language, optionally enable your microphone, and choose the meeting app or all system audio. Confirm everyone in the meeting agrees to transcription, then press Start. macOS requests Speech Recognition, Screen & System Audio Recording, and (when selected) Microphone access.

Automatic mode answers new speech after a configurable pause and avoids submitting the same passage twice. Manual mode transcribes continuously and answers only when you press Answer now or submit a typed question. Answers stream on screen in Text and Both modes. Voice and Both read the completed answer through the Mac's selected audio output. Stop voice interrupts speech; Stop stops capture and cancels pending answers. The collapsed notch keeps listening status and a stop control visible.

## Data and limitations

Audio is not saved to disk. Apple Speech may process audio on Apple's servers unless on-device recognition is enabled and supported for the selected language. Recent transcript text and any meeting context you enter are sent to OpenAI to generate answers; API usage is billed to your API account. Transcripts and answers are kept in memory until cleared or the app quits. Settings are local; the API key is in Keychain.

Use headphones for spoken answers. Recognition is paused during speech playback to prevent feedback, so speech occurring during playback is not transcribed. Automatic answers follow pauses in new speech rather than a guarantee that every utterance is a question. Latency and transcription accuracy depend on audio quality, language, the selected model, and the network. There is no hidden-recording or screen-share-evasion feature.

This is an independent implementation visually inspired by [Boring Notch](https://github.com/TheBoredTeam/boring.notch); no upstream source or assets are copied.

## Verification

The repository includes focused logic tests and a macOS build workflow. A successful build verifies compilation and packaging, not live meeting audio, permissions, response quality, or behavior on a physical Mac. Those require an interactive run with an API key.
