import Foundation

public struct TranscriptionAudioChunk: Equatable, Sendable {
    public let data: Data
    /// Duration at the beginning of this chunk that was also present in the preceding emitted chunk.
    public let overlappingPrefixDuration: Double
    public var hasOverlappingAudio: Bool { overlappingPrefixDuration > 0 }
    public init(data: Data, overlappingPrefixDuration: Double = 0) {
        self.data = data
        self.overlappingPrefixDuration = max(0, overlappingPrefixDuration)
    }
}

/// Bounded, speech-aware PCM chunking for file-based Whisper APIs. This is not a live STT socket.
public struct AudioChunker {
    public let sampleRate: Int
    private let maximumSamples: Int
    private var samples: [Int16] = []
    private var hasSpeech = false
    private var silentSamples = 0
    private var overlappingPrefixSamples = 0
    public var hasUnflushedSpeech: Bool { hasSpeech }

    public init(sampleRate: Int = 16_000, maximumSeconds: Double = 4) {
        self.sampleRate = max(8_000, min(48_000, sampleRate))
        let seconds = maximumSeconds.isFinite ? max(1, min(10, maximumSeconds)) : 4
        self.maximumSamples = Int(Double(self.sampleRate) * seconds)
    }

    public mutating func append(_ input: [Float]) -> [Data] {
        appendChunks(input).map(\.data)
    }

    public mutating func appendChunks(_ input: [Float]) -> [TranscriptionAudioChunk] {
        guard !input.isEmpty else { return [] }
        var chunks: [TranscriptionAudioChunk] = []
        // Process small frames so a large callback cannot bypass the memory or duration bound.
        let frameSize = max(1, sampleRate / 50)
        var start = 0
        while start < input.count {
            let remainingCapacity = max(1, maximumSamples - samples.count)
            let end = min(input.count, start + min(frameSize, remainingCapacity))
            let frame = input[start..<end]
            start = end
            let clean = frame.map { $0.isFinite ? max(-1, min(1, $0)) : 0 }
            let energy = clean.reduce(Float(0)) { $0 + $1 * $1 } / Float(clean.count)
            let speech = energy > 0.000025
            if speech { hasSpeech = true; silentSamples = 0 }
            else { silentSamples += clean.count }
            samples.append(contentsOf: clean.map { Int16($0 * 32_767) })
            if !hasSpeech {
                let keep = sampleRate / 4
                if samples.count > keep {
                    let removed = samples.count - keep
                    samples.removeFirst(removed)
                    overlappingPrefixSamples = max(0, overlappingPrefixSamples - removed)
                }
            } else if samples.count >= maximumSamples {
                if let chunk = flush(keepOverlap: true) { chunks.append(chunk) }
            } else if silentSamples >= sampleRate * 3 / 5, samples.count >= sampleRate {
                if let chunk = flush(keepOverlap: false) { chunks.append(chunk) }
            }
        }
        return chunks
    }

    public mutating func finish() -> Data? { finishChunk()?.data }
    public mutating func finishChunk() -> TranscriptionAudioChunk? { flush(keepOverlap: false) }

    private mutating func flush(keepOverlap: Bool) -> TranscriptionAudioChunk? {
        guard hasSpeech, !samples.isEmpty else {
            samples.removeAll(keepingCapacity: true)
            hasSpeech = false
            silentSamples = 0
            overlappingPrefixSamples = 0
            return nil
        }
        // Keep a brief spoken tail such as "yes". Pad only actual speech to the provider's 10 ms minimum.
        var outputSamples = samples
        let minimumSamples = max(1, sampleRate / 100)
        if outputSamples.count < minimumSamples {
            outputSamples.append(contentsOf: repeatElement(Int16(0), count: minimumSamples - outputSamples.count))
        }
        let chunk = TranscriptionAudioChunk(data: Self.wav(samples: outputSamples, sampleRate: sampleRate),
                                            overlappingPrefixDuration: Double(overlappingPrefixSamples) / Double(sampleRate))
        samples = keepOverlap ? Array(samples.suffix(sampleRate / 4)) : []
        overlappingPrefixSamples = samples.count
        hasSpeech = false
        silentSamples = 0
        return chunk
    }

    public static func wav(samples: [Int16], sampleRate: Int) -> Data {
        var data = Data()
        func append<T: FixedWidthInteger>(_ value: T) {
            var littleEndian = value.littleEndian
            Swift.withUnsafeBytes(of: &littleEndian) { data.append(contentsOf: $0) }
        }
        let byteCount = UInt32(samples.count * 2)
        data.append(Data("RIFF".utf8)); append(UInt32(36) + byteCount)
        data.append(Data("WAVEfmt ".utf8)); append(UInt32(16))
        append(UInt16(1)); append(UInt16(1)); append(UInt32(sampleRate))
        append(UInt32(sampleRate * 2)); append(UInt16(2)); append(UInt16(16))
        data.append(Data("data".utf8)); append(byteCount)
        for sample in samples { append(sample) }
        return data
    }
}

public enum TranscriptOverlap {
    /// Audio metadata must establish overlap. Text repetition alone is not evidence of duplicate audio.
    public static func removingRepeatedPrefix(_ text: String, previous: String,
                                              overlappingAudio: Bool = false, maximumWords: Int = 4) -> String {
        guard overlappingAudio else { return text }
        let incoming = text.split(whereSeparator: { $0.isWhitespace }).map(String.init)
        let prior = previous.split(whereSeparator: { $0.isWhitespace }).map(String.init)
        // 250 ms cannot justify removing a long sentence; preserve an entirely repeated short utterance too.
        let limit = min(max(0, min(6, maximumWords)), min(incoming.count - 1, prior.count))
        guard limit >= 2 else { return text }
        for count in stride(from: limit, through: 2, by: -1) {
            let lhs = incoming.prefix(count).map(TranscriptStore.normalized)
            let rhs = prior.suffix(count).map(TranscriptStore.normalized)
            if lhs.allSatisfy({ !$0.isEmpty }), lhs == rhs {
                return incoming.dropFirst(count).joined(separator: " ")
            }
        }
        return text
    }
}
