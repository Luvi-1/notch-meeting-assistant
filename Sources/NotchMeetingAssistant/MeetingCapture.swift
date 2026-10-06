import AppKit
import AVFoundation
import CoreMedia
import ScreenCaptureKit
import Speech
import NotchCore

@MainActor
final class MeetingCapture: NSObject, SCStreamOutput, SCStreamDelegate {
    var onSegment: ((SessionSegment) -> Void)?
    var onFailure: ((String) -> Void)?
    var onLevel: ((Double) -> Void)?
    private var stream: SCStream?
    private var microphone: AVAudioEngine?
    private var generation = UUID()
    private var running = false
    private var suppressed = false
    private var channels: [String: any CaptureChannel] = [:]

    static func applications() async throws -> [MeetingApplication] {
        let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
        var seen = Set<String>()
        return content.applications.compactMap { app in
            guard !app.bundleIdentifier.isEmpty, app.bundleIdentifier != Bundle.main.bundleIdentifier,
                  seen.insert(app.bundleIdentifier).inserted else { return nil }
            return MeetingApplication(id: app.bundleIdentifier, name: app.applicationName)
        }.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }
    func start(options: UserSettings, transcription: TranscriptionConfiguration, key: String) async throws {
        guard options.includeMicrophone || options.captureSystemAudio else { throw AssistantError("Enable Microphone or System Audio in listening settings.") }
        let token = UUID(); generation = token
        if transcription.provider == .apple {
            let authorization = await withCheckedContinuation { continuation in
                SFSpeechRecognizer.requestAuthorization { continuation.resume(returning: $0) }
            }
            try check(token)
            guard authorization == .authorized else { throw AssistantError("Allow Speech Recognition for Notch in System Settings → Privacy & Security.") }
        }
        if options.includeMicrophone {
            let granted = await AVCaptureDevice.requestAccess(for: .audio)
            try check(token)
            guard granted else { throw AssistantError("Allow Microphone access for Notch in System Settings → Privacy & Security.") }
        }
        var labels: [String] = []
        if options.includeMicrophone { labels.append("Microphone") }
        if options.captureSystemAudio { labels.append("System audio") }
        for label in labels {
            let emit: (SessionSegment) -> Void = { [weak self] in self?.onSegment?($0) }
            let fail: (String) -> Void = { [weak self] in self?.onFailure?($0) }
            if transcription.provider == .apple {
                let language = transcription.language.isEmpty ? options.locale : transcription.language
                channels[label] = try AppleSpeechChannel(label: label, locale: language, onDeviceOnly: options.onDeviceOnly, onSegment: emit, onFailure: fail)
            } else {
                channels[label] = ChunkSpeechChannel(label: label, configuration: transcription, key: key, threshold: options.silenceThreshold, onSegment: emit, onFailure: fail)
            }
        }
        running = true; suppressed = false
        do {
            if options.captureSystemAudio {
                let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
                try check(token)
                guard let display = content.displays.first(where: { $0.displayID == CGMainDisplayID() }) ?? content.displays.first else { throw AssistantError("No display is available for system audio capture.") }
                let filter: SCContentFilter
                if options.applicationID.isEmpty { filter = SCContentFilter(display: display, excludingApplications: [], exceptingWindows: []) }
                else {
                    guard let app = content.applications.first(where: { $0.bundleIdentifier == options.applicationID }) else { throw AssistantError("The selected audio app is not running. Open it or choose All system audio.") }
                    filter = SCContentFilter(display: display, including: [app], exceptingWindows: [])
                }
                let config = SCStreamConfiguration()
                config.width = 2; config.height = 2; config.minimumFrameInterval = CMTime(value: 1, timescale: 1)
                config.showsCursor = false; config.capturesAudio = true; config.excludesCurrentProcessAudio = true
                config.sampleRate = 48_000; config.channelCount = 1
                let candidate = SCStream(filter: filter, configuration: config, delegate: self)
                try candidate.addStreamOutput(self, type: .audio, sampleHandlerQueue: .main)
                // Screen frames are immediately discarded; only system audio is processed.
                try candidate.addStreamOutput(self, type: .screen, sampleHandlerQueue: .main)
                stream = candidate
                try await candidate.startCapture()
                try check(token)
            }
            if options.includeMicrophone {
                let engine = AVAudioEngine()
                let input = engine.inputNode
                let format = input.outputFormat(forBus: 0)
                guard format.sampleRate > 0, format.channelCount > 0 else { throw AssistantError("No working microphone is available. Check the Mac's sound input.") }
                input.installTap(onBus: 0, bufferSize: 2048, format: format) { [weak self] buffer, _ in
                    guard let copied = AudioBlock.copy(buffer) else { return }
                    Task { @MainActor in
                        guard let self, self.generation == token, self.running else { return }
                        self.append(copied.buffer, label: "Microphone")
                    }
                }
                microphone = engine
                engine.prepare(); try engine.start()
            }
            try check(token)
        } catch { await cancel(); throw error }
    }
    func stop() async {
        running = false
        microphone?.inputNode.removeTap(onBus: 0); microphone?.stop(); microphone = nil
        let old = stream; stream = nil
        if let old { try? await old.stopCapture() }
        // Drain the final cloud chunk before finalizing the saved session.
        for channel in channels.values { await channel.finish() }
        channels.removeAll(); generation = UUID(); suppressed = false
    }
    func cancel() async {
        generation = UUID(); running = false
        microphone?.inputNode.removeTap(onBus: 0); microphone?.stop(); microphone = nil
        channels.values.forEach { $0.cancel() }; channels.removeAll()
        let old = stream; stream = nil
        if let old { try? await old.stopCapture() }
    }
    func setSuppressed(_ value: Bool) {
        suppressed = value
        channels.values.forEach { $0.setSuppressed(value) }
    }
    private func append(_ buffer: AVAudioPCMBuffer, label: String) {
        guard running, !suppressed else { return }
        if let values = buffer.floatChannelData?[0], buffer.frameLength > 0 {
            var energy: Double = 0
            for i in stride(from: 0, to: Int(buffer.frameLength), by: 8) { energy += Double(values[i] * values[i]) }
            onLevel?(min(1, sqrt(energy / Double(max(1, Int(buffer.frameLength) / 8))) * 12))
        }
        channels[label]?.append(buffer)
    }
    private func check(_ token: UUID) throws { guard generation == token, !Task.isCancelled else { throw CancellationError() } }
    nonisolated func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of type: SCStreamOutputType) {
        guard type == .audio, CMSampleBufferDataIsReady(sampleBuffer),
              let description = CMSampleBufferGetFormatDescription(sampleBuffer),
              let asbd = CMAudioFormatDescriptionGetStreamBasicDescription(description),
              let format = AVAudioFormat(streamDescription: asbd) else { return }
        let count = CMSampleBufferGetNumSamples(sampleBuffer)
        guard count > 0, let pcm = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(count)) else { return }
        pcm.frameLength = AVAudioFrameCount(count)
        let status = CMSampleBufferCopyPCMDataIntoAudioBufferList(sampleBuffer, at: 0, frameCount: Int32(count), into: pcm.mutableAudioBufferList)
        guard status == noErr else { return }
        let block = AudioBlock(pcm)
        Task { @MainActor [weak self] in
            guard let self, self.stream === stream, self.running else { return }
            self.append(block.buffer, label: "System audio")
        }
    }
    nonisolated func stream(_ stream: SCStream, didStopWithError error: Error) {
        Task { @MainActor [weak self] in
            guard let self, self.stream === stream, self.running else { return }
            self.onFailure?("System audio stopped: \(error.localizedDescription)")
        }
    }
}

private final class AudioBlock: @unchecked Sendable {
    let buffer: AVAudioPCMBuffer
    init(_ buffer: AVAudioPCMBuffer) { self.buffer = buffer }
    static func copy(_ source: AVAudioPCMBuffer) -> AudioBlock? {
        guard let destination = AVAudioPCMBuffer(pcmFormat: source.format, frameCapacity: source.frameLength) else { return nil }
        destination.frameLength = source.frameLength
        let input = UnsafeMutableAudioBufferListPointer(source.mutableAudioBufferList)
        let output = UnsafeMutableAudioBufferListPointer(destination.mutableAudioBufferList)
        guard input.count == output.count else { return nil }
        for i in 0..<input.count {
            guard let source = input[i].mData, let target = output[i].mData else { return nil }
            memcpy(target, source, Int(min(input[i].mDataByteSize, output[i].mDataByteSize)))
        }
        return AudioBlock(destination)
    }
}

@MainActor private protocol CaptureChannel: AnyObject {
    func append(_ buffer: AVAudioPCMBuffer)
    func setSuppressed(_ value: Bool)
    func finish() async
    func cancel()
}

@MainActor private final class AppleSpeechChannel: CaptureChannel {
    private let label: String
    private let recognizer: SFSpeechRecognizer
    private let onDeviceOnly: Bool
    private let onSegment: (SessionSegment) -> Void
    private let onFailure: (String) -> Void
    private var request: SFSpeechAudioBufferRecognitionRequest?
    private var task: SFSpeechRecognitionTask?
    private var timer: Timer?
    private var retry: Task<Void, Never>?
    private var segmentID = UUID()
    private var segmentTime = Date()
    private var active = true
    private var suppressed = false
    private var finishing = false
    private var failures = 0
    init(label: String, locale: String, onDeviceOnly: Bool, onSegment: @escaping (SessionSegment) -> Void, onFailure: @escaping (String) -> Void) throws {
        guard let recognizer = SFSpeechRecognizer(locale: Locale(identifier: locale)), recognizer.isAvailable else { throw AssistantError("Apple Speech is unavailable for \(locale). Choose another language or transcription provider.") }
        guard !onDeviceOnly || recognizer.supportsOnDeviceRecognition else { throw AssistantError("On-device Apple Speech is unavailable for \(locale). Choose a supported language or Local Whisper.") }
        self.label = label; self.recognizer = recognizer; self.onDeviceOnly = onDeviceOnly
        self.onSegment = onSegment; self.onFailure = onFailure
        begin()
    }
    func append(_ buffer: AVAudioPCMBuffer) { if active && !suppressed && !finishing { request?.append(buffer) } }
    func setSuppressed(_ value: Bool) {
        guard suppressed != value, active else { return }
        suppressed = value
        if value { request?.endAudio(); task?.cancel(); timer?.invalidate() }
        else { begin() }
    }
    func finish() async {
        finishing = true; timer?.invalidate(); retry?.cancel(); request?.endAudio()
        try? await Task.sleep(nanoseconds: 800_000_000)
        cancel()
    }
    func cancel() {
        active = false; segmentID = UUID(); timer?.invalidate(); timer = nil
        retry?.cancel(); retry = nil; request?.endAudio(); task?.cancel(); request = nil; task = nil
    }
    private func begin() {
        guard active, !suppressed, !finishing else { return }
        timer?.invalidate(); request?.endAudio(); task?.cancel()
        segmentID = UUID(); segmentTime = Date()
        let id = segmentID; let date = segmentTime
        let request = SFSpeechAudioBufferRecognitionRequest()
        request.shouldReportPartialResults = true; request.requiresOnDeviceRecognition = onDeviceOnly
        request.addsPunctuation = true; request.taskHint = .dictation
        self.request = request
        task = recognizer.recognitionTask(with: request) { [weak self] result, error in
            Task { @MainActor in
                guard let self, self.active, self.segmentID == id, !self.suppressed else { return }
                if let result {
                    let text = result.bestTranscription.formattedString
                    if !text.isEmpty { self.failures = 0; self.onSegment(SessionSegment(id: id, time: date, source: self.label, text: text)) }
                    if result.isFinal { if !self.finishing { self.begin() }; return }
                }
                if let error, !self.finishing { self.recover(error) }
            }
        }
        // Short segments keep a lecture readable and remain below Apple's request duration limit.
        let timer = Timer(timeInterval: 20, repeats: false) { [weak self] _ in Task { @MainActor in self?.begin() } }
        self.timer = timer; RunLoop.main.add(timer, forMode: .common)
    }
    private func recover(_ error: Error) {
        let value = error as NSError
        if !(value.domain == "kAFAssistantErrorDomain" && value.code == 1110) { failures += 1 }
        guard failures <= 2 else { cancel(); onFailure("Speech recognition stopped: \(value.localizedDescription)"); return }
        timer?.invalidate(); task?.cancel(); request?.endAudio(); segmentID = UUID()
        retry?.cancel()
        retry = Task { [weak self] in
            do { try await Task.sleep(nanoseconds: 1_000_000_000) } catch { return }
            self?.begin()
        }
    }
}

@MainActor private final class ChunkSpeechChannel: CaptureChannel {
    private struct AudioChunk { let samples: [Int16]; let time: Date }
    private let label: String
    private let configuration: TranscriptionConfiguration
    private let key: String
    private let threshold: Double
    private let onSegment: (SessionSegment) -> Void
    private let onFailure: (String) -> Void
    private var samples: [Int16] = []
    private var startTime: Date?
    private var queue: [AudioChunk] = []
    private var worker: Task<Void, Never>?
    private var active = true
    private var suppressed = false
    private var converter: AVAudioConverter?
    private let targetFormat = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 16_000, channels: 1, interleaved: false)!
    init(label: String, configuration: TranscriptionConfiguration, key: String, threshold: Double,
         onSegment: @escaping (SessionSegment) -> Void, onFailure: @escaping (String) -> Void) {
        self.label = label; self.configuration = configuration; self.key = key; self.threshold = threshold
        self.onSegment = onSegment; self.onFailure = onFailure
    }
    func append(_ buffer: AVAudioPCMBuffer) {
        guard active, !suppressed else { return }
        if converter?.inputFormat != buffer.format { converter = AVAudioConverter(from: buffer.format, to: targetFormat) }
        guard let converter else { fail("Could not convert the selected audio input."); return }
        let capacity = AVAudioFrameCount(ceil(Double(buffer.frameLength) * 16_000 / buffer.format.sampleRate) + 128)
        guard let output = AVAudioPCMBuffer(pcmFormat: targetFormat, frameCapacity: capacity) else { fail("Could not allocate an audio buffer."); return }
        var used = false; var error: NSError?
        let status = converter.convert(to: output, error: &error) { _, inputStatus in
            if used { inputStatus.pointee = .noDataNow; return nil }
            used = true; inputStatus.pointee = .haveData; return buffer
        }
        guard status != .error, error == nil, let values = output.floatChannelData?[0] else { fail("Audio conversion failed."); return }
        if startTime == nil { startTime = Date() }
        for i in 0..<Int(output.frameLength) {
            let value = values[i].isFinite ? max(-1, min(1, values[i])) : 0
            samples.append(Int16(value * 32767))
        }
        let wanted = Int(configuration.chunkSeconds * 16_000)
        if samples.count >= wanted {
            let tail = samples.suffix(4000)
            let quiet = tail.allSatisfy { abs(Double($0) / 32768) < max(0.002, threshold * 2) }
            if quiet || samples.count >= wanted + 32_000 { flush() }
        }
    }
    func setSuppressed(_ value: Bool) {
        if value && !suppressed { flush() }
        suppressed = value
        if !value { startTime = nil }
    }
    func finish() async {
        flush(); active = false
        await worker?.value
    }
    func cancel() { active = false; worker?.cancel(); worker = nil; queue.removeAll(); samples.removeAll(); converter = nil }
    private func flush() {
        guard !samples.isEmpty else { return }
        let chunk = AudioChunk(samples: samples, time: startTime ?? Date())
        samples.removeAll(keepingCapacity: true); startTime = nil
        let rms = sqrt(chunk.samples.reduce(0.0) { $0 + pow(Double($1) / 32768, 2) } / Double(chunk.samples.count))
        guard chunk.samples.count >= 160, rms >= threshold else { return }
        guard queue.count < 4 else { fail("Transcription cannot keep up with the input. Listening stopped; some pending audio could not be transcribed. Try a faster provider or a longer chunk size."); return }
        queue.append(chunk)
        guard worker == nil else { return }
        worker = Task { [weak self] in
            guard let self else { return }
            defer { self.worker = nil }
            do {
                while !self.queue.isEmpty {
                    try Task.checkCancellation()
                    let chunk = self.queue.removeFirst()
                    let result = try await WhisperTranscriptionProvider().transcribe(wav: PCMEncoding.wav(samples: chunk.samples), configuration: self.configuration, key: self.key)
                    try Task.checkCancellation()
                    for span in result.spans {
                        let timestamp = chunk.time.addingTimeInterval(min(span.start, Double(chunk.samples.count) / 16_000))
                        // Diarization IDs are clip-scoped; never pretend Speaker A is the same person in another clip.
                        let speaker = span.speaker.map { "Speaker \($0) · \(chunk.time.formatted(date: .omitted, time: .standard))" }
                        self.onSegment(SessionSegment(time: timestamp, source: self.label, text: span.text, speaker: speaker))
                    }
                }
            } catch is CancellationError { return }
            catch { self.fail(error.localizedDescription + " Some pending audio may be missing from the transcript.") }
        }
    }
    private func fail(_ message: String) { active = false; queue.removeAll(); samples.removeAll(); onFailure(message) }
}
