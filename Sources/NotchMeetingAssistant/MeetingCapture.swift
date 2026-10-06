import AppKit
import AVFoundation
import CoreMedia
import ScreenCaptureKit
import Speech
import NotchCore

@MainActor
final class MeetingCapture: NSObject, SCStreamOutput, SCStreamDelegate {
    var onText: ((UUID, String, String) -> Void)?
    var onSegment: ((UUID, String, String, Date) -> Void)?
    var onFailure: ((String) -> Void)?
    var onLevel: ((Double) -> Void)?
    private var stream: SCStream?
    private var microphone: AVAudioEngine?
    private var generation = UUID()
    private var running = false
    private var draining = false
    private var suppressed = false
    private var options = UserSettings()
    private var channels: [String: AudioChannel] = [:]

    static func applications() async throws -> [MeetingApplication] {
        let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
        var seen = Set<String>()
        return content.applications.compactMap { app in
            guard !app.bundleIdentifier.isEmpty, app.bundleIdentifier != Bundle.main.bundleIdentifier,
                  seen.insert(app.bundleIdentifier).inserted else { return nil }
            return MeetingApplication(id: app.bundleIdentifier, name: app.applicationName)
        }.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }
    func start(options: UserSettings) async throws {
        let token = UUID(); generation = token; self.options = options
        if options.transcription.resolvedKind == .apple {
            let permission = await withCheckedContinuation { continuation in
                SFSpeechRecognizer.requestAuthorization { continuation.resume(returning: $0) }
            }
            try check(token)
            guard permission == .authorized else { throw AssistantError("Allow Speech Recognition in System Settings → Privacy & Security.") }
        } else {
            let config = options.transcription
            _ = try config.endpoint()
            if config.resolvedKind != .localWhisper, config.resolvedKind != .custom,
               try APIKeyStore.load(config.kind.keyID).isEmpty { throw AssistantError("Add the transcription provider's API key in Settings.") }
        }
        if options.audioSource.usesMicrophone {
            let granted = await AVCaptureDevice.requestAccess(for: .audio)
            try check(token)
            guard granted else { throw AssistantError("Allow Microphone access in System Settings → Privacy & Security.") }
        }
        do {
            // Room listening never enumerates displays or requests Screen Recording access.
            if options.audioSource.usesSystem {
                let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
                try check(token)
                guard let display = content.displays.first(where: { $0.displayID == CGMainDisplayID() }) ?? content.displays.first else {
                    throw AssistantError("No display is available for system audio.")
                }
                let filter: SCContentFilter
                if options.applicationID.isEmpty { filter = SCContentFilter(display: display, excludingApplications: [], exceptingWindows: []) }
                else {
                    guard let app = content.applications.first(where: { $0.bundleIdentifier == options.applicationID }) else {
                        throw AssistantError("The selected audio app is not running.")
                    }
                    filter = SCContentFilter(display: display, including: [app], exceptingWindows: [])
                }
                let config = SCStreamConfiguration()
                config.width = 2; config.height = 2; config.minimumFrameInterval = CMTime(value: 1, timescale: 1)
                config.showsCursor = false; config.capturesAudio = true; config.excludesCurrentProcessAudio = true
                config.sampleRate = 48_000; config.channelCount = 1
                let candidate = SCStream(filter: filter, configuration: config, delegate: self)
                try candidate.addStreamOutput(self, type: .audio, sampleHandlerQueue: .main)
                try candidate.addStreamOutput(self, type: .screen, sampleHandlerQueue: .main)
                stream = candidate
            }
            running = true; suppressed = false
            try restartRecognition()
            if options.audioSource.usesMicrophone {
                let engine = AVAudioEngine()
                let node = engine.inputNode
                let format = node.outputFormat(forBus: 0)
                guard format.sampleRate > 0, format.channelCount > 0 else { throw AssistantError("The microphone has no usable audio format.") }
                node.installTap(onBus: 0, bufferSize: 2048, format: format) { [weak self] buffer, _ in
                    // AVAudioEngine reuses its buffers after the tap returns; transfer an owned copy.
                    guard let copy = Self.copy(buffer) else { return }
                    Task { @MainActor in
                        guard let self, self.generation == token, self.running, !self.suppressed else { return }
                        self.append(copy, source: "Room")
                    }
                }
                microphone = engine
                engine.prepare(); try engine.start()
            }
            if let stream { try await stream.startCapture() }
            try check(token)
        } catch {
            await stop(flush: false)
            throw error
        }
    }
    func stop(flush: Bool = true) async {
        generation = UUID(); running = false; draining = flush
        microphone?.inputNode.removeTap(onBus: 0); microphone?.stop(); microphone = nil
        let old = stream; stream = nil
        if let old { try? await old.stopCapture() }
        let oldChannels = channels
        if flush { for channel in oldChannels.values { await channel.finish() } }
        oldChannels.values.forEach { $0.stop() }
        channels.removeAll(); draining = false; suppressed = false; onLevel?(0)
    }
    func setSuppressed(_ value: Bool) throws {
        guard running, suppressed != value else { return }
        suppressed = value
        if value { channels.values.forEach { $0.pause() }; onLevel?(0) }
    }
    func restartRecognition() throws {
        channels.values.forEach { $0.stop() }; channels.removeAll()
        guard running else { return }
        var sources: [String] = []
        if options.audioSource.usesMicrophone { sources.append("Room") }
        if options.audioSource.usesSystem { sources.append("Device") }
        for source in sources {
            let channel: AudioChannel
            if options.transcription.resolvedKind == .apple {
                let apple = AppleSpeechChannel(source: source)
                try apple.start(locale: options.transcription.automaticLanguage ? options.locale : options.transcription.language,
                                onDeviceOnly: options.onDeviceOnly)
                channel = apple
            } else {
                let keyID = options.transcription.kind.keyID
                let key = keyID.isEmpty ? "" : try APIKeyStore.load(keyID)
                channel = WhisperSpeechChannel(source: source, configuration: options.transcription, key: key)
            }
            channel.onText = { [weak self] id, source, text, time in
                guard let self, self.running || self.draining else { return }
                self.onText?(id, source, text); self.onSegment?(id, source, text, time)
            }
            channel.onFailure = { [weak self] message in self?.onFailure?(message) }
            channels[source] = channel
        }
    }
    private func append(_ buffer: AVAudioPCMBuffer, source: String) {
        if let samples = buffer.floatChannelData?[0], buffer.frameLength > 0 {
            var sum: Float = 0
            for index in stride(from: 0, to: Int(buffer.frameLength), by: 8) { sum += samples[index] * samples[index] }
            let rms = sqrt(sum / Float(max(1, Int(buffer.frameLength) / 8)))
            onLevel?(min(1, Double(rms) * 12))
        }
        do { try channels[source]?.append(buffer) }
        catch { onFailure?(error.localizedDescription) }
    }
    private func check(_ token: UUID) throws {
        guard generation == token, !Task.isCancelled else { throw CancellationError() }
    }
    nonisolated private static func copy(_ buffer: AVAudioPCMBuffer) -> AVAudioPCMBuffer? {
        guard let copy = AVAudioPCMBuffer(pcmFormat: buffer.format, frameCapacity: buffer.frameLength) else { return nil }
        copy.frameLength = buffer.frameLength
        let input = UnsafeMutableAudioBufferListPointer(UnsafeMutablePointer(mutating: buffer.audioBufferList))
        let output = UnsafeMutableAudioBufferListPointer(copy.mutableAudioBufferList)
        for (source, target) in zip(input, output) {
            guard let src = source.mData, let dst = target.mData else { return nil }
            memcpy(dst, src, min(Int(source.mDataByteSize), Int(target.mDataByteSize)))
        }
        return copy
    }
    nonisolated func stream(_ stream: SCStream, didOutputSampleBuffer sample: CMSampleBuffer, of type: SCStreamOutputType) {
        guard type == .audio, CMSampleBufferDataIsReady(sample) else { return }
        Task { @MainActor [weak self] in
            guard let self, self.stream === stream, self.running, !self.suppressed,
                  let description = CMSampleBufferGetFormatDescription(sample),
                  let format = AVAudioFormat(cmAudioFormatDescription: description),
                  let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(CMSampleBufferGetNumSamples(sample))) else { return }
            buffer.frameLength = buffer.frameCapacity
            let result = CMSampleBufferCopyPCMDataIntoAudioBufferList(sample, at: 0, frameCount: Int32(buffer.frameLength), into: buffer.mutableAudioBufferList)
            guard result == noErr else { self.onFailure?("Could not decode captured system audio (\(result))."); return }
            self.append(buffer, source: "Device")
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
private protocol AudioChannel: AnyObject {
    var onText: ((UUID, String, String, Date) -> Void)? { get set }
    var onFailure: ((String) -> Void)? { get set }
    func append(_ buffer: AVAudioPCMBuffer) throws
    func pause()
    func finish() async
    func stop()
}

@MainActor
private final class AppleSpeechChannel: AudioChannel {
    var onText: ((UUID, String, String, Date) -> Void)?
    var onFailure: ((String) -> Void)?
    private let source: String
    private var recognizer: SFSpeechRecognizer?
    private var request: SFSpeechAudioBufferRecognitionRequest?
    private var task: SFSpeechRecognitionTask?
    private var rotation: Timer?
    private var retry: Task<Void, Never>?
    private var segment = UUID()
    private var active = false
    private var finishing = false
    private var finalized = false
    private var onDeviceOnly = false
    private var failures = 0
    init(source: String) { self.source = source }
    func start(locale: String, onDeviceOnly: Bool) throws {
        guard let recognizer = SFSpeechRecognizer(locale: Locale(identifier: locale)), recognizer.isAvailable else {
            throw AssistantError("Apple Speech is unavailable for \(locale). Choose a language or another transcription provider.")
        }
        guard !onDeviceOnly || recognizer.supportsOnDeviceRecognition else { throw AssistantError("On-device speech is unavailable for this language.") }
        self.recognizer = recognizer; self.onDeviceOnly = onDeviceOnly
        active = true; beginSegment()
    }
    func append(_ buffer: AVAudioPCMBuffer) throws { if active && !finishing { request?.append(buffer) } }
    func pause() {}
    func finish() async {
        finishing = true; rotation?.invalidate(); request?.endAudio()
        for _ in 0..<20 {
            if finalized || !active { break }
            try? await Task.sleep(nanoseconds: 100_000_000)
        }
        stop()
    }
    func stop() {
        active = false; segment = UUID(); rotation?.invalidate(); retry?.cancel()
        request?.endAudio(); task?.cancel(); request = nil; task = nil
    }
    private func beginSegment() {
        guard active, !finishing, let recognizer else { return }
        segment = UUID(); let id = segment; let time = Date()
        finalized = false; rotation?.invalidate(); request?.endAudio(); task?.cancel()
        let request = SFSpeechAudioBufferRecognitionRequest()
        request.shouldReportPartialResults = true; request.requiresOnDeviceRecognition = onDeviceOnly
        request.addsPunctuation = true; request.taskHint = .dictation; self.request = request
        task = recognizer.recognitionTask(with: request) { [weak self] result, error in
            Task { @MainActor in
                guard let self, self.active, self.segment == id else { return }
                if let result {
                    let text = result.bestTranscription.formattedString
                    if !text.isEmpty { self.failures = 0; self.onText?(id, self.source, text, time) }
                    if result.isFinal { self.finalized = true; if !self.finishing { self.beginSegment() }; return }
                }
                if let error, !self.finishing { self.recover(error) }
            }
        }
        let timer = Timer(timeInterval: 35, repeats: false) { [weak self] _ in Task { @MainActor in self?.beginSegment() } }
        rotation = timer; RunLoop.main.add(timer, forMode: .common)
    }
    private func recover(_ error: Error) {
        rotation?.invalidate()
        let error = error as NSError
        if !(error.domain == "kAFAssistantErrorDomain" && error.code == 1110) { failures += 1 }
        guard failures <= 2 else { stop(); onFailure?("Speech recognition stopped. Check access or your network and start again."); return }
        request?.endAudio(); task?.cancel(); request = nil; task = nil
        segment = UUID(); let token = segment; retry?.cancel()
        retry = Task { [weak self] in
            do { try await Task.sleep(nanoseconds: 1_000_000_000) } catch { return }
            guard let self, self.active, self.segment == token else { return }; self.beginSegment()
        }
    }
}

@MainActor
private final class WhisperSpeechChannel: AudioChannel {
    var onText: ((UUID, String, String, Date) -> Void)?
    var onFailure: ((String) -> Void)?
    private struct Chunk { let samples: [Float]; let time: Date; let number: Int }
    private let source: String
    private let provider: WhisperProvider
    private let chunkFrames: Int
    private let format = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 16_000, channels: 1, interleaved: false)!
    private var converter: AVAudioConverter?
    private var samples: [Float] = []
    private var quietFrames = 0
    private var freshFrames = 0
    private var chunkStart = Date()
    private var queue: [Chunk] = []
    private var worker: Task<Void, Never>?
    private var active = true
    private var failed = false
    private var number = 0
    private var previous = ""
    init(source: String, configuration: TranscriptionConfiguration, key: String) {
        self.source = source; provider = WhisperProvider(configuration: configuration, key: key)
        chunkFrames = Int(min(12, max(3, configuration.chunkSeconds)) * 16_000)
    }
    func append(_ buffer: AVAudioPCMBuffer) throws {
        guard active, !failed else { return }
        if converter == nil || converter?.inputFormat != buffer.format { converter = AVAudioConverter(from: buffer.format, to: format) }
        guard let converter else { throw AssistantError("Could not convert the microphone audio format.") }
        let capacity = AVAudioFrameCount(ceil(Double(buffer.frameLength) * 16_000 / buffer.format.sampleRate) + 64)
        guard let converted = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: capacity) else { throw AssistantError("Could not allocate an audio buffer.") }
        var supplied = false
        var error: NSError?
        converter.convert(to: converted, error: &error) { _, status in
            if supplied { status.pointee = .noDataNow; return nil }
            supplied = true; status.pointee = .haveData; return buffer
        }
        if let error { throw error }
        guard let channel = converted.floatChannelData?[0], converted.frameLength > 0 else { return }
        let count = Int(converted.frameLength)
        if samples.isEmpty { chunkStart = Date().addingTimeInterval(-Double(count) / 16_000) }
        let incoming = Array(UnsafeBufferPointer(start: channel, count: count))
        samples.append(contentsOf: incoming); freshFrames += count
        let energy = incoming.reduce(Float(0)) { $0 + $1 * $1 } / Float(count)
        quietFrames = energy < 0.00002 ? quietFrames + count : 0
        if samples.count >= chunkFrames || (freshFrames >= 16_000 && quietFrames >= 9_600) { flush(final: false) }
    }
    func pause() { flush(final: true) }
    func finish() async { active = false; flush(final: true); await worker?.value }
    func stop() { active = false; worker?.cancel(); worker = nil; samples.removeAll(); queue.removeAll() }
    private func flush(final: Bool) {
        guard !failed, freshFrames > 0, !samples.isEmpty else { return }
        // Do not bill/upload chunks containing only silence.
        let energy = samples.reduce(Float(0)) { $0 + $1 * $1 } / Float(samples.count)
        if energy >= 0.00001 {
            guard queue.count < 8 else {
                failed = true
                onFailure?("Transcription could not keep up. Listening stopped; audio after the last transcript may be missing.")
                return
            }
            number += 1; queue.append(Chunk(samples: samples, time: chunkStart, number: number))
        }
        let overlap = final ? 0 : min(5_600, samples.count)
        chunkStart = chunkStart.addingTimeInterval(Double(samples.count - overlap) / 16_000)
        samples = Array(samples.suffix(overlap)); freshFrames = 0; quietFrames = 0
        if worker == nil && !queue.isEmpty { worker = Task { [weak self] in await self?.drain() } }
    }
    private func drain() async {
        defer { worker = nil }
        while !queue.isEmpty, !Task.isCancelled, !failed {
            let chunk = queue.removeFirst()
            do {
                let result = try await provider.transcribe(wav: PCMChunk.wav(samples: chunk.samples), context: previous)
                try Task.checkCancellation()
                if result.parts.contains(where: { $0.speaker != nil }) {
                    for part in result.parts where !part.text.isEmpty {
                        // Diarization identities are scoped to each uploaded clip, never guessed across clips.
                        let label = part.speaker.map { "\(source) · Speaker \($0) (clip \(chunk.number))" } ?? source
                        onText?(UUID(), label, part.text, chunk.time.addingTimeInterval(part.start))
                    }
                } else {
                    let clean = PCMChunk.removingOverlap(previous: previous, next: result.text)
                    if !clean.isEmpty { onText?(UUID(), source, clean, chunk.time) }
                }
                previous = result.text
            } catch {
                if Task.isCancelled { return }
                failed = true
                onFailure?("Transcription stopped: \(error.localizedDescription) Audio after the last transcript may be missing.")
            }
        }
    }
}
