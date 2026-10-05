import XCTest
@testable import NotchCore

final class MeetingLogicTests: XCTestCase {
    func testTranscriptRevisionsAndBoundedContext() {
        var store = TranscriptStore()
        let id = UUID()
        XCTAssertTrue(store.update(id: id, source: "Meeting", text: "What is the plan"))
        XCTAssertFalse(store.update(id: id, source: "Meeting", text: "What is the plan?"))
        XCTAssertTrue(store.update(id: id, source: "Meeting", text: "What is the plan for Friday?"))
        XCTAssertEqual(store.lines.count, 1)
        for _ in 0..<150 {
            store.update(id: UUID(), source: "Meeting", text: String(repeating: "word ", count: 2_000))
        }
        XCTAssertEqual(store.lines.count, 120)
        XCTAssertLessThanOrEqual(store.context.count, 16_000)
    }

    func testAutomaticGateWaitsAndNeverRepeatsConsumedSpeech() {
        let start = Date(timeIntervalSince1970: 1_000)
        var gate = AutoAnswerGate()
        gate.changed(at: start)
        func ready(_ time: Double, mode: AnswerMode = .automatic, busy: Bool = false,
                   listening: Bool = true, speaking: Bool = false) -> Bool {
            gate.ready(at: start.addingTimeInterval(time), delay: 1.8,
                       listening: listening, mode: mode, busy: busy, speaking: speaking)
        }
        XCTAssertFalse(ready(1))
        XCTAssertTrue(ready(2))
        XCTAssertFalse(ready(2, mode: .manual))
        XCTAssertFalse(ready(2, busy: true))
        XCTAssertFalse(ready(2, listening: false))
        XCTAssertFalse(ready(2, speaking: true))
        let requestedRevision = gate.revision
        gate.consume(requestedRevision, at: start.addingTimeInterval(2))
        XCTAssertFalse(ready(20))
        gate.changed(at: start.addingTimeInterval(3))
        // New speech received during a response remains eligible when that response finishes.
        gate.consume(requestedRevision, at: start.addingTimeInterval(4))
        XCTAssertFalse(ready(5))
        XCTAssertTrue(ready(8))
    }

    func testStreamingProtocolAndMalformedData() throws {
        var decoder = EventStreamDecoder()
        XCTAssertNil(try decoder.feed(": keepalive"))
        XCTAssertNil(try decoder.feed("data: {\"choices\":[{\"delta\":{\"content\":\"Hello 🌎\"}}]}"))
        XCTAssertEqual(try decoder.feed("")?.text, "Hello 🌎")
        _ = try decoder.feed("data: {\"choices\":[{\"delta\":{},\"finish_reason\":\"stop\"}]}")
        XCTAssertEqual(try decoder.feed("")?.finishReason, "stop")
        _ = try decoder.feed("data: [DONE]")
        XCTAssertEqual(try decoder.feed(""), StreamEvent(done: true))
        _ = try decoder.feed("data: {\"error\":{\"message\":\"Provider failed\"}}")
        XCTAssertThrowsError(try decoder.feed(""))
        _ = try decoder.feed("data: not-json")
        XCTAssertThrowsError(try decoder.feed(""))
        XCTAssertTrue(OutputMode.both.showsText && OutputMode.both.usesVoice)
        XCTAssertFalse(OutputMode.voice.showsText)
        XCTAssertFalse(OutputMode.text.usesVoice)
    }
}
