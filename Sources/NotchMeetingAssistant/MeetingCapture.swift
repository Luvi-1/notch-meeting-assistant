import AppKit
import AVFoundation
import CoreMedia
import ScreenCaptureKit
import Speech
import NotchCore

@MainActor
final class MeetingCapture: NSObject, SCStreamOutput, SCStreamDelegate {
    var onText: ((UUID, String, String) -> Void)?
    var onFailure: ((String) -> Void)?
    private var stream: SCStream?
    private var generation = UUID()
    private var running = false
    private var suppressed = false
    private var options = UserSettings()
    private var channels: [String: SpeechChannel] = [:]

    static func applications() async throws -> [MeetingApplication] {
        let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
        var seen = Set<String>()
        return content.applications.compactMap { app in
            guard !app.bundleIdentifier.isEmpty,
                  app.bundleIdentifier != Bundle.main.bundleIdentifier,
                  seen.insert(app.bundleIdentifier).inserted else { return nil }
            return MeetingApplication(id: app.bundleIdentifier, name: app.applicationName)
        }.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    func start(options: UserSettings) async throws {
        let token = UUID()
        generation = token
        self.options = options
        let authorization = await withCheckedContinuation { continuation in
            SFSpeechRecognizer.requestAuthorization { continuation.resume(returning: $0) }
        }
        try check(token)
        guard authorization == .authorized else {
            throw AssistantError("Allow Speech Recognition for this app in System Settings → Privacy & Security.")
        }
        if options.includeMicrophone {
            let granted = await AVCaptureDevice.requestAccess(for: .audio)
            try check(token)
            guard granted else {
                throw AssistantError("Allow Microphone access, or turn off Include my microphone in Settings.")
            }
        }
        let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
        try check(token)
        guard let display = content.displays.first(where: { $0.displayID == CGMainDisplayID() }) ?? content.displays.first else {
            throw AssistantError("No display is available for meeting audio capture.")
        }
        let filter: SCContentFilter
        if options.applicationID.isEmpty {
            filter = SCContentFilter(display: display, excludingApplications: [], exceptingWindows: [])
        } else {
            guard let app = content.applications.first(where: { $0.bundleIdentifier == options.applicationID }) else {
                throw AssistantError("The selected meeting app is not running. Open it or choose another audio source.")
            }
            filter = SCContentFilter(display: display, including: [app], exceptingWindows: [])
        }
        let config = SCStreamConfiguration()
        config.width = 2
        config.height = 2
        config.minimumFrameInterval = CMTime(value: 1, timescale: 1)
        config.showsCursor = false
        config.capturesAudio = true
        config.excludesCurrentProcessAudio = true
        config.sampleRate = 48_000
        config.channelCount = 1
        config.captureMicrophone = options.includeMicrophone
        let candidate = SCStream(filter: filter, configuration: config, delegate: self)
        try candidate.addStreamOutput(self, type: .audio, sampleHandlerQueue: .main)
        // Screen frames are discarded; the app only processes audio buffers.
        try candidate.addStreamOutput(self, type: .screen, sampleHandlerQueue: .main)
        if options.includeMicrophone {
            try candidate.addStreamOutput(self, type: .microphone, sampleHandlerQueue: .main)
        }
        stream = candidate
        running = true
        suppressed = false
        do {
            try restartRecognition()
            try await candidate.startCapture()
            try check(token)
        } catch {
            // A Stop during a permission prompt must also stop any late-starting stream.
            running = false
            channels.values.forEach { $0.stop() }
            channels.removeAll()
            try? await candidate.stopCapture()
            if stream === candidate { stream = nil }
            throw error
        }
    }

    func stop() async {
        generation = UUID()
        running = false
        suppressed = false
        channels.values.forEach { $0.stop() }
        channels.removeAll()
        let old = stream
        stream = nil
        if let old { try? await old.stopCapture() }
    }

    func setSuppressed(_ value: Bool) throws {
        guard running, value != suppressed else { return }
        suppressed = value
        if value {
            channels.values.forEach { $0.stop() }
        } else {
            try restartRecognition()
        }
    }

    func restartRecognition() throws {
        channels.values.forEach { $0.stop() }
        channels.removeAll()
        guard running, !suppressed else { return }
        for label in options.includeMicrophone ? ["Meeting", "You"] : ["Meeting"] {
            let channel = SpeechChannel(label: label)
            channel.onText = { [weak self] id, label, text in self?.onText?(id, label, text) }
            channel.onFailure = { [weak self] message in self?.onFailure?(message) }
            channels[label] = channel
            try channel.start(locale: options.locale, onDeviceOnly: options.onDeviceOnly)
        }
    }

    private func check(_ token: UUID) throws {
        guard generation == token, !Task.isCancelled else { throw CancellationError() }
    }

    nonisolated func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer,
                            of type: SCStreamOutputType) {
        guard type == .audio || type == .microphone, CMSampleBufferDataIsReady(sampleBuffer) else { return }
        Task { @MainActor [weak self] in
            guard let self, self.stream === stream, self.running, !self.suppressed else { return }
            self.channels[type == .microphone ? "You" : "Meeting"]?.append(sampleBuffer)
        }
    }

    nonisolated func stream(_ stream: SCStream, didStopWithError error: Error) {
        Task { @MainActor [weak self] in
            guard let self, self.stream === stream, self.running else { return }
            self.onFailure?("Audio capture stopped: \(error.localizedDescription)")
        }
    }
}

@MainActor
private final class SpeechChannel {
    var onText: ((UUID, String, String) -> Void)?
    var onFailure: ((String) -> Void)?
    private let label: String
    private var recognizer: SFSpeechRecognizer?
    private var request: SFSpeechAudioBufferRecognitionRequest?
    private var task: SFSpeechRecognitionTask?
    private var rotation: Timer?
    private var retry: Task<Void, Never>?
    private var segment = UUID()
    private var active = false
    private var onDeviceOnly = false
    private var failures = 0

    init(label: String) { self.label = label }

    func start(locale: String, onDeviceOnly: Bool) throws {
        guard let recognizer = SFSpeechRecognizer(locale: Locale(identifier: locale)), recognizer.isAvailable else {
            throw AssistantError("Speech recognition is unavailable for \(locale). Check the language and network in Settings.")
        }
        guard !onDeviceOnly || recognizer.supportsOnDeviceRecognition else {
            throw AssistantError("On-device transcription is unavailable for \(locale). Choose another language or allow Apple speech processing.")
        }
        self.recognizer = recognizer
        self.onDeviceOnly = onDeviceOnly
        failures = 0
        active = true
        beginSegment()
    }

    func append(_ buffer: CMSampleBuffer) {
        guard active else { return }
        request?.appendAudioSampleBuffer(buffer)
    }

    func stop() {
        active = false
        segment = UUID()
        rotation?.invalidate()
        rotation = nil
        retry?.cancel()
        retry = nil
        request?.endAudio()
        task?.cancel()
        task = nil
        request = nil
    }

    private func beginSegment() {
        guard active, let recognizer else { return }
        segment = UUID()
        let id = segment
        rotation?.invalidate()
        request?.endAudio()
        task?.cancel()
        let request = SFSpeechAudioBufferRecognitionRequest()
        request.shouldReportPartialResults = true
        request.requiresOnDeviceRecognition = onDeviceOnly
        request.addsPunctuation = true
        request.taskHint = .dictation
        self.request = request
        task = recognizer.recognitionTask(with: request) { [weak self] result, error in
            Task { @MainActor in
                guard let self, self.active, self.segment == id else { return }
                if let result {
                    let text = result.bestTranscription.formattedString
                    if !text.isEmpty {
                        self.failures = 0
                        self.onText?(id, self.label, text)
                    }
                    if result.isFinal { self.beginSegment(); return }
                }
                if let error { self.recover(error, segment: id) }
            }
        }
        // Rotate before Apple's per-request duration limit, preserving prior transcript segments.
        let timer = Timer(timeInterval: 45, repeats: false) { [weak self] _ in
            Task { @MainActor in self?.beginSegment() }
        }
        rotation = timer
        RunLoop.main.add(timer, forMode: .common)
    }

    private func recover(_ error: Error, segment id: UUID) {
        rotation?.invalidate()
        let error = error as NSError
        let noSpeech = error.domain == "kAFAssistantErrorDomain" && error.code == 1110
        if !noSpeech { failures += 1 }
        guard failures <= 2 else {
            stop()
            onFailure?("Speech recognition stopped: \(error.localizedDescription). Check access or your network and start again.")
            return
        }
        request?.endAudio()
        task?.cancel()
        request = nil
        task = nil
        // Invalidate callbacks from the failed task before waiting for a bounded retry.
        segment = UUID()
        let retryID = segment
        retry?.cancel()
        retry = Task { [weak self] in
            do { try await Task.sleep(nanoseconds: 1_000_000_000) } catch { return }
            guard let self, self.active, self.segment == retryID else { return }
            self.beginSegment()
        }
    }
}
