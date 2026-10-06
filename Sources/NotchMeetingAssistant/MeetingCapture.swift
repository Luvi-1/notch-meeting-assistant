import AppKit
import AVFoundation
import CoreMedia
import ScreenCaptureKit
import Speech
import NotchCore

/// Audio acquisition is independent of the selected transcription engine.
@MainActor
final class MeetingCapture: NSObject, SCStreamOutput, SCStreamDelegate {
    var onText: ((UUID, String, String) -> Void)?
    var onFailure: ((String) -> Void)?
    private var stream: SCStream?
    private var microphone: AVAudioEngine?
    private var generation = UUID()
    private var running = false
    private var suppressed = false
    private var options = UserSettings()
    private var transcription = TranscriptionConfiguration()
    private var transcriptionKey = ""
    private var speechChannels: [String: SpeechChannel] = [:]
    private var cloudChannels: [String: CloudTranscriptionChannel] = [:]
    private var stoppingTask: Task<Void, Never>?
    private var usesApple: Bool { transcription.provider == .apple || transcription.provider == .auto }

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

    func start(options: UserSettings, transcription: TranscriptionConfiguration, key: String) async throws {
        guard !running, stoppingTask == nil else { throw AssistantError("Finish the current listening session before starting another.") }
        guard options.includeMicrophone || options.captureSystemAudio else {
            throw AssistantError("Choose Microphone or System audio in Listening settings.")
        }
        let token = UUID()
        generation = token
        self.options = options
        self.transcription = transcription
        self.transcriptionKey = key
        if usesApple {
            let authorization = await withCheckedContinuation { continuation in
                SFSpeechRecognizer.requestAuthorization { continuation.resume(returning: $0) }
            }
            try check(token)
            guard authorization == .authorized else {
                throw AssistantError("Allow Speech Recognition for Notch in System Settings → Privacy & Security.")
            }
        }
        if options.includeMicrophone {
            let granted = await AVCaptureDevice.requestAccess(for: .audio)
            try check(token)
            guard granted else {
                throw AssistantError("Allow Microphone access in System Settings → Privacy & Security.")
            }
        }
        running = true
        suppressed = false
        do {
            try restartRecognition()
            if options.includeMicrophone { try startMicrophone(token: token) }
            if options.captureSystemAudio { try await startSystemAudio(token: token) }
            try check(token)
        } catch {
            await stop(flush: false)
            throw error
        }
    }

    private func startMicrophone(token: UUID) throws {
        let engine = AVAudioEngine()
        let input = engine.inputNode
        let format = input.outputFormat(forBus: 0)
        guard format.sampleRate > 0, format.channelCount > 0 else {
            throw AssistantError("No microphone is available. Check your audio input in System Settings.")
        }
        input.installTap(onBus: 0, bufferSize: 2_048, format: format) { [weak self] buffer, _ in
            // The engine owns its tap buffer. Copy before handing it to the main actor.
            guard let copy = Self.copy(buffer) else { return }
            Task { @MainActor [weak self] in
                guard let self, self.generation == token, self.running, !self.suppressed else { return }
                self.append(copy, source: "Microphone")
            }
        }
        microphone = engine
        engine.prepare()
        try engine.start()
    }

    private func startSystemAudio(token: UUID) async throws {
        let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
        try check(token)
        guard let display = content.displays.first(where: { $0.displayID == CGMainDisplayID() }) ?? content.displays.first else {
            throw AssistantError("No display is available for system audio capture.")
        }
        let filter: SCContentFilter
        if options.applicationID.isEmpty {
            filter = SCContentFilter(display: display, excludingApplications: [], exceptingWindows: [])
        } else {
            guard let app = content.applications.first(where: { $0.bundleIdentifier == options.applicationID }) else {
                throw AssistantError("The selected audio app is not running. Open it or choose All system audio.")
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
        let candidate = SCStream(filter: filter, configuration: config, delegate: self)
        try candidate.addStreamOutput(self, type: .audio, sampleHandlerQueue: .main)
        try candidate.addStreamOutput(self, type: .screen, sampleHandlerQueue: .main)
        stream = candidate
        try await candidate.startCapture()
        do { try check(token) }
        catch { try? await candidate.stopCapture(); throw error }
    }

    /// Final audio chunks finish before the session is committed, avoiding a lost final sentence.
    func stop(flush: Bool = true) async {
        if let stoppingTask {
            if !flush { cancelPendingTranscription() }
            await stoppingTask.value
            return
        }
        generation = UUID()
        running = false
        suppressed = false
        microphone?.inputNode.removeTap(onBus: 0)
        microphone?.stop()
        microphone = nil
        let old = stream
        stream = nil
        let speech = Array(speechChannels.values)
        let cloud = Array(cloudChannels.values)
        // One deadline covers all sources, including requests already waiting in the queue.
        let deadline = Date().addingTimeInterval(25)
        if !flush {
            speech.forEach { $0.stop() }
            cloud.forEach { $0.cancel() }
        }
        let task = Task { @MainActor [weak self] in
            if let old { try? await old.stopCapture() }
            if flush {
                // Flush all sources immediately; their upload workers can make progress together.
                cloud.forEach { $0.flush() }
                for channel in speech { await channel.finish(deadline: deadline) }
                for channel in cloud { await channel.finish(deadline: deadline) }
            }
            guard let self else { return }
            self.speechChannels.removeAll()
            self.cloudChannels.removeAll()
            self.transcriptionKey = ""
            self.stoppingTask = nil
        }
        stoppingTask = task
        await task.value
    }

    /// Cancels finishing work without discarding transcript text that has already arrived.
    func cancelPendingTranscription() {
        guard stoppingTask != nil else { return }
        let pending = speechChannels.values.contains { $0.hasPendingWork }
            || cloudChannels.values.contains { $0.hasPendingWork }
        speechChannels.values.forEach { $0.stop() }
        cloudChannels.values.forEach { $0.cancel() }
        if pending {
            onFailure?("Final transcription was cancelled. The session keeps text received so far; some final audio has not been transcribed.")
        }
    }

    func setSuppressed(_ value: Bool) throws {
        guard running, value != suppressed else { return }
        suppressed = value
        if value {
            speechChannels.values.forEach { $0.stop() }
            // Queue already-captured speech, but never append the app's spoken answer.
            cloudChannels.values.forEach { $0.flush() }
        } else if usesApple { try restartRecognition() }
    }

    func restartRecognition() throws {
        speechChannels.values.forEach { $0.stop() }
        speechChannels.removeAll()
        guard running, !suppressed else { return }
        let sources = (options.includeMicrophone ? ["Microphone"] : []) + (options.captureSystemAudio ? ["System audio"] : [])
        if usesApple {
            for source in sources {
                let channel = SpeechChannel(label: source)
                channel.onText = { [weak self] id, label, text in self?.onText?(id, label, text) }
                channel.onFailure = { [weak self] message in self?.onFailure?(message) }
                speechChannels[source] = channel
                try channel.start(locale: options.locale, onDeviceOnly: options.onDeviceOnly)
            }
        } else if cloudChannels.isEmpty {
            for source in sources {
                let channel = CloudTranscriptionChannel(source: source, configuration: transcription, key: transcriptionKey)
                channel.onText = { [weak self] id, label, text in self?.onText?(id, label, text) }
                channel.onFailure = { [weak self] message in self?.onFailure?(message) }
                cloudChannels[source] = channel
            }
        }
    }

    private func append(_ buffer: AVAudioPCMBuffer, source: String) {
        if usesApple { speechChannels[source]?.append(buffer) }
        else { cloudChannels[source]?.append(buffer) }
    }

    private func check(_ token: UUID) throws {
        guard generation == token, !Task.isCancelled else { throw CancellationError() }
    }

    nonisolated func stream(_ stream: SCStream, didOutputSampleBuffer buffer: CMSampleBuffer, of type: SCStreamOutputType) {
        guard type == .audio, CMSampleBufferDataIsReady(buffer), let copy = Self.copy(buffer) else { return }
        Task { @MainActor [weak self] in
            guard let self, self.stream === stream, self.running, !self.suppressed else { return }
            self.append(copy, source: "System audio")
        }
    }

    nonisolated func stream(_ stream: SCStream, didStopWithError error: Error) {
        Task { @MainActor [weak self] in
            guard let self, self.stream === stream, self.running else { return }
            self.onFailure?("Audio capture stopped: \(error.localizedDescription)")
        }
    }

    nonisolated private static func copy(_ buffer: AVAudioPCMBuffer) -> AVAudioPCMBuffer? {
        guard let copy = AVAudioPCMBuffer(pcmFormat: buffer.format, frameCapacity: buffer.frameLength) else { return nil }
        copy.frameLength = buffer.frameLength
        for (source, destination) in zip(UnsafeMutableAudioBufferListPointer(UnsafeMutablePointer(mutating: buffer.audioBufferList)), UnsafeMutableAudioBufferListPointer(copy.mutableAudioBufferList)) {
            guard let from = source.mData, let to = destination.mData else { continue }
            memcpy(to, from, min(Int(source.mDataByteSize), Int(destination.mDataByteSize)))
        }
        return copy
    }

    nonisolated private static func copy(_ sample: CMSampleBuffer) -> AVAudioPCMBuffer? {
        guard let description = CMSampleBufferGetFormatDescription(sample) else { return nil }
        let format = AVAudioFormat(cmAudioFormatDescription: description)
        let frames = AVAudioFrameCount(CMSampleBufferGetNumSamples(sample))
        guard frames > 0, let copy = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames) else { return nil }
        copy.frameLength = frames
        var size = 0
        var block: CMBlockBuffer?
        let sizing = CMSampleBufferGetAudioBufferListWithRetainedBlockBuffer(sample, bufferListSizeNeededOut: &size, bufferListOut: nil, bufferListSize: 0, blockBufferAllocator: nil, blockBufferMemoryAllocator: nil, flags: 0, blockBufferOut: nil)
        guard sizing == noErr, size >= MemoryLayout<AudioBufferList>.size else { return nil }
        let raw = UnsafeMutableRawPointer.allocate(byteCount: size, alignment: MemoryLayout<AudioBufferList>.alignment)
        defer { raw.deallocate() }
        let list = raw.bindMemory(to: AudioBufferList.self, capacity: 1)
        let status = CMSampleBufferGetAudioBufferListWithRetainedBlockBuffer(sample, bufferListSizeNeededOut: nil, bufferListOut: list, bufferListSize: size, blockBufferAllocator: nil, blockBufferMemoryAllocator: nil, flags: 0, blockBufferOut: &block)
        guard status == noErr else { return nil }
        withExtendedLifetime(block) {
            for (source, destination) in zip(UnsafeMutableAudioBufferListPointer(list), UnsafeMutableAudioBufferListPointer(copy.mutableAudioBufferList)) {
                guard let from = source.mData, let to = destination.mData else { continue }
                memcpy(to, from, min(Int(source.mDataByteSize), Int(destination.mDataByteSize)))
            }
        }
        return copy
    }
}

@MainActor
private final class CloudTranscriptionChannel {
    var onText: ((UUID, String, String) -> Void)?
    var onFailure: ((String) -> Void)?
    private let source: String
    private let provider: HTTPTranscriptionProvider
    private var chunker = AudioChunker()
    private var converter: AVAudioConverter?
    private var inputFormat: AVAudioFormat?
    private let outputFormat = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 16_000, channels: 1, interleaved: false)!
    private var queue: [(UUID, TranscriptionAudioChunk)] = []
    private var worker: Task<Void, Never>?
    private var active = true
    private var previousText = ""
    var hasPendingWork: Bool { worker != nil || !queue.isEmpty || chunker.hasUnflushedSpeech }

    init(source: String, configuration: TranscriptionConfiguration, key: String) {
        self.source = source
        self.provider = HTTPTranscriptionProvider(configuration: configuration, key: key)
    }

    func append(_ input: AVAudioPCMBuffer) {
        guard active else { return }
        guard input.frameLength > 0, input.format.sampleRate.isFinite, input.format.sampleRate > 0 else { return }
        if inputFormat != input.format {
            drainConverter()
            guard active else { return }
            converter = AVAudioConverter(from: input.format, to: outputFormat)
            inputFormat = input.format
        }
        guard let converter else { fail("The audio input could not be converted for transcription."); return }
        let capacity = AVAudioFrameCount(ceil(Double(input.frameLength) * 16_000 / input.format.sampleRate)) + 64
        guard let output = AVAudioPCMBuffer(pcmFormat: outputFormat, frameCapacity: capacity) else {
            fail("Audio conversion could not allocate its output. The transcript may be incomplete.")
            return
        }
        var conversionError: NSError?
        var supplied = false
        let result = converter.convert(to: output, error: &conversionError) { _, status in
            if supplied { status.pointee = .noDataNow; return nil }
            supplied = true
            status.pointee = .haveData
            return input
        }
        guard result != .error, conversionError == nil else { fail("The audio input format changed. Restart listening."); return }
        appendConverted(output)
    }

    func flush() {
        guard active else { return }
        drainConverter()
        guard active else { return }
        if let tail = chunker.finishChunk() { enqueue(tail) }
    }

    func finish(deadline: Date) async {
        guard active else { return }
        flush()
        while active, worker != nil {
            if Task.isCancelled {
                cancelWithNotice("Final transcription was cancelled")
                return
            }
            if Date() >= deadline {
                cancelWithNotice("The transcription provider did not finish within 25 seconds")
                return
            }
            do { try await Task.sleep(nanoseconds: 50_000_000) }
            catch { cancelWithNotice("Final transcription was cancelled"); return }
        }
        active = false
        converter = nil
        inputFormat = nil
    }

    func cancel() {
        active = false
        worker?.cancel()
        worker = nil
        queue.removeAll()
        chunker = AudioChunker()
        converter = nil
        inputFormat = nil
    }

    private func appendConverted(_ output: AVAudioPCMBuffer) {
        guard active, let samples = output.floatChannelData?[0], output.frameLength > 0 else { return }
        for chunk in chunker.appendChunks(Array(UnsafeBufferPointer(start: samples, count: Int(output.frameLength)))) {
            enqueue(chunk)
        }
    }

    private func drainConverter() {
        guard let converter else { return }
        defer { self.converter = nil; inputFormat = nil }
        // noDataNow preserves conversion latency; endOfStream releases the final resampled frames.
        for _ in 0..<16 {
            guard active, let output = AVAudioPCMBuffer(pcmFormat: outputFormat, frameCapacity: 2_048) else { return }
            var error: NSError?
            let status = converter.convert(to: output, error: &error) { _, inputStatus in
                inputStatus.pointee = .endOfStream
                return nil
            }
            guard status != .error, error == nil else {
                fail("The last audio could not be converted. The session keeps the transcript received so far.")
                return
            }
            appendConverted(output)
            if status == .endOfStream || output.frameLength == 0 { return }
        }
        fail("Audio conversion did not finish. The session keeps the transcript received so far.")
    }

    private func cancelWithNotice(_ reason: String) {
        let pending = hasPendingWork
        cancel()
        if pending { onFailure?("\(reason). The session keeps text received so far; some final audio has not been transcribed.") }
    }

    private func enqueue(_ chunk: TranscriptionAudioChunk) {
        guard active else { return }
        guard queue.count < 12 else {
            fail("Transcription cannot keep up with the audio. The session keeps text received so far; queued audio has not been transcribed.")
            return
        }
        queue.append((UUID(), chunk))
        guard worker == nil else { return }
        worker = Task { [weak self] in
            guard let self else { return }
            defer { self.worker = nil }
            do {
                while !self.queue.isEmpty, self.active, !Task.isCancelled {
                    let (id, chunk) = self.queue.removeFirst()
                    let result = try await self.provider.transcribe(wavData: chunk.data)
                    try Task.checkCancellation()
                    guard self.active else { return }
                    let text = TranscriptOverlap.removingRepeatedPrefix(result.text, previous: self.previousText,
                                                                        overlappingAudio: chunk.hasOverlappingAudio,
                                                                        maximumWords: 4)
                    self.previousText = result.text
                    if !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { self.onText?(id, self.source, text) }
                }
            } catch {
                if !(error is CancellationError) { self.fail(error.localizedDescription) }
            }
        }
    }

    private func fail(_ message: String) {
        guard active else { return }
        cancel()
        onFailure?(message)
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
    private var rotationGrace: Task<Void, Never>?
    private var retry: Task<Void, Never>?
    private var segment = UUID()
    private var active = false
    private var finishing = false
    private var finalReceived = false
    private var rotating = false
    private var currentHasAudio = false
    private var bufferedAudio: [AVAudioPCMBuffer] = []
    private var bufferedDuration: Double = 0
    private var onDeviceOnly = false
    private var failures = 0
    var hasPendingWork: Bool { active && ((currentHasAudio && !finalReceived) || !bufferedAudio.isEmpty) }

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
        finishing = false
        beginSegment()
    }

    func append(_ buffer: AVAudioPCMBuffer) {
        guard active else { return }
        if rotating {
            // New audio belongs to the next segment while the old task produces its final result.
            bufferedDuration += Double(buffer.frameLength) / max(1, buffer.format.sampleRate)
            guard bufferedDuration <= 6 else {
                fail("Apple Speech could not finish its previous segment. The session keeps text received so far; some audio has not been transcribed.")
                return
            }
            bufferedAudio.append(buffer)
        } else if !finishing {
            currentHasAudio = true
            request?.append(buffer)
        }
    }

    func finish(deadline: Date) async {
        guard active else { return }
        let rotationDeadline = min(deadline, Date().addingTimeInterval(6))
        rotation?.invalidate()
        // If a rotation is already closing, first let its buffered successor receive the remaining audio.
        while active, rotating {
            if Date() >= rotationDeadline || Task.isCancelled {
                fail("Apple Speech did not finish the last segment. The session keeps text received so far; final words may be missing.")
                return
            }
            do { try await Task.sleep(nanoseconds: 50_000_000) }
            catch { stop(); return }
        }
        guard active else { return }
        let finalDeadline = min(deadline, Date().addingTimeInterval(6))
        finishing = true
        rotation?.invalidate()
        request?.endAudio()
        while active, currentHasAudio, !finalReceived {
            if Date() >= finalDeadline || Task.isCancelled {
                fail("Apple Speech did not finish the last words. The session keeps the transcript received so far; final words may be missing.")
                return
            }
            do { try await Task.sleep(nanoseconds: 50_000_000) }
            catch { stop(); return }
        }
        stop()
    }

    func stop() {
        active = false
        segment = UUID()
        rotation?.invalidate()
        rotation = nil
        rotationGrace?.cancel()
        rotationGrace = nil
        retry?.cancel()
        retry = nil
        request?.endAudio()
        task?.cancel()
        task = nil
        request = nil
        rotating = false
        currentHasAudio = false
        bufferedAudio.removeAll()
        bufferedDuration = 0
    }

    private func beginSegment() {
        guard active, !finishing, let recognizer else { return }
        let pending = bufferedAudio
        bufferedAudio.removeAll(keepingCapacity: true)
        bufferedDuration = 0
        rotating = false
        currentHasAudio = false
        finalReceived = false
        segment = UUID()
        let id = segment
        rotation?.invalidate()
        rotationGrace?.cancel()
        rotationGrace = nil
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
                    if result.isFinal {
                        self.finalReceived = true
                        if !self.finishing { self.beginSegment() }
                        return
                    }
                }
                if let error {
                    let failure = error as NSError
                    let noSpeech = failure.domain == "kAFAssistantErrorDomain" && failure.code == 1110
                    if self.finishing {
                        self.finalReceived = true
                        if self.currentHasAudio && !noSpeech {
                            self.onFailure?("Apple Speech could not finalize the last words. The session keeps the transcript received so far.")
                        }
                    } else if self.rotating && noSpeech {
                        self.finalReceived = true
                        self.beginSegment()
                    }
                    else { self.recover(error, segment: id) }
                }
            }
        }
        for buffer in pending {
            currentHasAudio = true
            request.append(buffer)
        }
        // Close gracefully before the request limit; new audio is buffered until the final callback.
        let timer = Timer(timeInterval: 45, repeats: false) { [weak self] _ in
            Task { @MainActor in self?.rotateSegment() }
        }
        rotation = timer
        RunLoop.main.add(timer, forMode: .common)
    }

    private func rotateSegment() {
        guard active, !finishing, !rotating else { return }
        rotating = true
        rotation?.invalidate()
        let id = segment
        request?.endAudio()
        rotationGrace?.cancel()
        rotationGrace = Task { @MainActor [weak self] in
            do { try await Task.sleep(nanoseconds: 5_000_000_000) } catch { return }
            guard let self, self.active, self.rotating, self.segment == id else { return }
            self.fail("Apple Speech did not finalize a segment. The session keeps text received so far; some audio has not been transcribed. Restart listening when recognition is available.")
        }
    }

    private func recover(_ error: Error, segment id: UUID) {
        rotation?.invalidate()
        rotationGrace?.cancel()
        rotationGrace = nil
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
        rotating = true
        currentHasAudio = false
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

    private func fail(_ message: String) {
        guard active else { return }
        stop()
        onFailure?(message)
    }
}
