import XCTest
@testable import NotchCore

final class AudioChunkingTests: XCTestCase {
    func testSilenceIsNotUploadedAndStopFlushesSpeech() {
        var chunker = AudioChunker()
        XCTAssertTrue(chunker.append(Array(repeating: 0, count: 160_000)).isEmpty)
        XCTAssertNil(chunker.finish())
        XCTAssertTrue(chunker.append(Array(repeating: 0.2, count: 8_000)).isEmpty)
        let final = chunker.finish()
        XCTAssertNotNil(final)
        XCTAssertEqual(String(data: final!.prefix(4), encoding: .utf8), "RIFF")
        XCTAssertNil(chunker.finish(), "Stopping twice must not upload duplicate audio")
    }

    func testChunksHaveBoundedWAVSizeAndRecoverAfterSilence() {
        var chunker = AudioChunker(maximumSeconds: 2)
        let chunks = chunker.append(Array(repeating: 0.1, count: 100_000))
        XCTAssertGreaterThan(chunks.count, 2)
        for chunk in chunks { XCTAssertLessThanOrEqual(chunk.count, 64_044) }
        _ = chunker.append(Array(repeating: 0, count: 16_000))
        XCTAssertNil(chunker.finish())
        _ = chunker.append(Array(repeating: Float.nan, count: 8_000))
        XCTAssertNil(chunker.finish())
    }

    func testBoundaryDeduplicationPreservesNewWords() {
        XCTAssertEqual(TranscriptOverlap.removingRepeatedPrefix("supply and demand. Why does it shift?", previous: "Let's discuss supply and demand", overlappingAudio: true), "Why does it shift?")
        XCTAssertEqual(TranscriptOverlap.removingRepeatedPrefix("Yes this changes", previous: "Yes"), "Yes this changes")
        XCTAssertEqual(TranscriptOverlap.removingRepeatedPrefix("Different words", previous: "A prior sentence"), "Different words")
    }

    func testOverlapMetadataFollowsActualEmittedAudio() {
        var chunker = AudioChunker(maximumSeconds: 1)
        let first = chunker.appendChunks(Array(repeating: 0.1, count: 16_000))
        XCTAssertEqual(first.count, 1)
        XCTAssertFalse(first[0].hasOverlappingAudio)
        let second = chunker.appendChunks(Array(repeating: 0.1, count: 12_000))
        XCTAssertEqual(second.count, 1)
        XCTAssertEqual(second[0].overlappingPrefixDuration, 0.25)
        XCTAssertNil(chunker.finishChunk(), "An overlap-only remainder must never upload the same speech again.")

        _ = chunker.appendChunks(Array(repeating: 0.1, count: 16_000))
        XCTAssertTrue(chunker.appendChunks(Array(repeating: 0, count: 16_000)).isEmpty)
        _ = chunker.appendChunks(Array(repeating: 0.1, count: 3_200))
        let resumed = chunker.finishChunk()
        XCTAssertNotNil(resumed)
        XCTAssertFalse(resumed!.hasOverlappingAudio, "The retained overlap was discarded during the pause.")
    }

    func testSilenceDelimitedUtterancesHaveNoOverlap() {
        var chunker = AudioChunker()
        _ = chunker.appendChunks(Array(repeating: 0.1, count: 8_000))
        let first = chunker.appendChunks(Array(repeating: 0, count: 16_000))
        XCTAssertEqual(first.count, 1)
        XCTAssertFalse(first[0].hasOverlappingAudio)
        _ = chunker.appendChunks(Array(repeating: 0.1, count: 8_000))
        XCTAssertFalse(chunker.finishChunk()!.hasOverlappingAudio)
    }

    func testStopKeepsBriefSpeechButNeverUploadsSilence() {
        var brief = AudioChunker()
        _ = brief.append(Array(repeating: 0.2, count: 1_920)) // 120 ms, below the previous discarded-tail threshold.
        XCTAssertTrue(brief.hasUnflushedSpeech)
        XCTAssertEqual(brief.finish()?.count, 44 + 1_920 * 2)
        XCTAssertFalse(brief.hasUnflushedSpeech)
        XCTAssertNil(brief.finish())

        var tiny = AudioChunker()
        _ = tiny.append([0.2])
        XCTAssertEqual(tiny.finish()?.count, 44 + 160 * 2, "A spoken tail can be padded to 10 ms without dropping it.")
        _ = tiny.append([0, .nan, .infinity])
        XCTAssertNil(tiny.finish())
    }

    func testActualRepetitionsAreNotDeletedWithoutAudioEvidence() {
        let text = "Remember this formula. Remember this formula."
        XCTAssertEqual(TranscriptOverlap.removingRepeatedPrefix(text, previous: "Remember this formula."), text)
        XCTAssertEqual(TranscriptOverlap.removingRepeatedPrefix("supply and demand", previous: "supply and demand", overlappingAudio: true), "supply and demand")
        let sentence = "This is a complete repeated sentence. Here is the next thought."
        XCTAssertEqual(TranscriptOverlap.removingRepeatedPrefix(sentence, previous: "This is a complete repeated sentence.", overlappingAudio: true), sentence,
                       "A quarter-second boundary cannot justify deleting a long sentence.")
    }

    func testNonFiniteDurationUsesSafeDefault() {
        var chunker = AudioChunker(maximumSeconds: .nan)
        let chunks = chunker.append(Array(repeating: 0.1, count: 64_000))
        XCTAssertEqual(chunks.count, 1)
        XCTAssertEqual(chunks[0].count, 128_044)
    }
}
