import Foundation
import XCTest
@testable import NotchCore

final class NotchUpdateTests: XCTestCase {
    private let start = Date(timeIntervalSince1970: 1_000)

    func testHoverHasExitGraceAndReentryCancelsDismissal() {
        var notch = NotchPresentation()
        XCTAssertEqual(notch.phase, .compact)
        notch.hover(true, at: start)
        XCTAssertEqual(notch.phase, .expanded)
        notch.hover(false, at: start)
        notch.tick(at: start.addingTimeInterval(0.5))
        XCTAssertEqual(notch.phase, .expanded)
        notch.hover(true, at: start.addingTimeInterval(0.6))
        notch.tick(at: start.addingTimeInterval(2))
        XCTAssertEqual(notch.phase, .expanded)
        notch.hover(false, at: start.addingTimeInterval(2))
        notch.tick(at: start.addingTimeInterval(3))
        XCTAssertEqual(notch.phase, .compact)
    }

    func testAnswerPreviewExpiresAndExplicitDismissalSurvivesCompletion() {
        var notch = NotchPresentation()
        notch.beginAnswer()
        notch.reveal(at: start, duration: 8)
        XCTAssertEqual(notch.phase, .preview)
        notch.tick(at: start.addingTimeInterval(7))
        XCTAssertEqual(notch.phase, .preview)
        notch.tick(at: start.addingTimeInterval(9))
        XCTAssertEqual(notch.phase, .compact)
        notch.beginAnswer()
        notch.reveal(at: start)
        notch.dismiss()
        notch.reveal(at: start.addingTimeInterval(1))
        XCTAssertEqual(notch.phase, .compact, "Completion must not undo a user's dismissal")
        notch.beginAnswer()
        notch.reveal(at: start.addingTimeInterval(2))
        XCTAssertEqual(notch.phase, .preview)
    }

    func testPinTypingAndSettingsKeepPanelOpen() {
        var notch = NotchPresentation()
        notch.setPinned(true, at: start)
        notch.hover(false, at: start)
        notch.tick(at: start.addingTimeInterval(30))
        XCTAssertEqual(notch.phase, .expanded)
        notch.setPinned(false, at: start.addingTimeInterval(30))
        notch.tick(at: start.addingTimeInterval(31))
        XCTAssertEqual(notch.phase, .compact)

        notch.setEditing(true, at: start)
        notch.hover(false, at: start)
        notch.reveal(at: start)
        notch.tick(at: start.addingTimeInterval(30))
        XCTAssertEqual(notch.phase, .expanded)
        notch.setEditing(false, at: start.addingTimeInterval(30))
        notch.tick(at: start.addingTimeInterval(31))
        XCTAssertEqual(notch.phase, .compact)

        notch.setSettings(true, at: start)
        notch.hover(false, at: start)
        notch.tick(at: start.addingTimeInterval(30))
        XCTAssertEqual(notch.phase, .expanded)
        notch.setSettings(false, at: start.addingTimeInterval(30))
        notch.tick(at: start.addingTimeInterval(31))
        XCTAssertEqual(notch.phase, .compact)

        notch.hover(true, at: start)
        notch.dismiss()
        notch.hover(true, at: start)
        XCTAssertEqual(notch.phase, .compact, "A stationary pointer must not reopen a dismissed notch")
        notch.hover(false, at: start)
        notch.hover(true, at: start)
        XCTAssertEqual(notch.phase, .expanded)
    }

    func testAstraUsesResponsesUltrafastAndLowReasoning() throws {
        let request = try AnswerClient().makeRequest(key: "sk-test-not-a-real-key", model: AnswerClient.astraModel,
                                                     ultrafast: true, transcript: "What is next?", latest: "What is next?",
                                                     context: "", question: "", automatic: true)
        XCTAssertEqual(request.url?.absoluteString, "https://api.openai.com/v1/responses")
        XCTAssertEqual(request.httpMethod, "POST")
        XCTAssertEqual(request.value(forHTTPHeaderField: "Accept"), "text/event-stream")
        let body = try XCTUnwrap(JSONSerialization.jsonObject(with: XCTUnwrap(request.httpBody)) as? [String: Any])
        XCTAssertEqual(body["model"] as? String, "gpt-6-astra")
        XCTAssertEqual(body["service_tier"] as? String, "ultrafast")
        XCTAssertEqual((body["reasoning"] as? [String: String])?["effort"], "low")
        XCTAssertEqual(body["stream"] as? Bool, true)
        XCTAssertEqual(body["store"] as? Bool, false)
        XCTAssertEqual(body["max_output_tokens"] as? Int, 2_048)
        XCTAssertNotNil(body["instructions"] as? String)
        XCTAssertTrue((body["input"] as? String)?.contains("[NO_ANSWER]") == true)
        XCTAssertNil(body["messages"])
        XCTAssertNil(body["max_completion_tokens"])
        XCTAssertNil(body["temperature"])
    }

    func testOtherModelsAndStandardTierDoNotReceiveUltrafast() throws {
        for (model, ultrafast) in [(AnswerClient.astraModel, false), ("gpt-4.1-mini", true)] {
            let request = try AnswerClient().makeRequest(key: "test-key", model: model, ultrafast: ultrafast,
                                                         transcript: "", latest: "", context: "", question: "Hello", automatic: false)
            let body = try XCTUnwrap(JSONSerialization.jsonObject(with: XCTUnwrap(request.httpBody)) as? [String: Any])
            XCTAssertNil(body["service_tier"])
            if model != AnswerClient.astraModel { XCTAssertNil(body["reasoning"]) }
        }
    }

    func testRequestRejectsInvalidCredentialsAndModelBeforeNetwork() {
        for (key, model) in [("", "gpt-6-astra"), ("bad\r\nheader", "gpt-6-astra"), ("test", "invalid model")] {
            XCTAssertThrowsError(try AnswerClient().makeRequest(key: key, model: model, ultrafast: true,
                                                              transcript: "", latest: "", context: "", question: "Hello", automatic: false))
        }
    }

    func testResponsesStreamRequiresExplicitSuccessfulCompletion() throws {
        let raw = [
            #"event: response.output_text.delta"#,
            #"data: {"type":"response.output_text.delta","delta":"Hello 🌎"}"#,
            "",
            #"data: {"type":"response.refusal.delta","delta":"Refusal text"}"#,
            "",
            #"data: {"type":"response.completed","response":{"status":"completed"}}"#,
            "", ""
        ].joined(separator: "\r\n")
        var decoder = EventStreamDecoder()
        var events: [StreamEvent] = []
        for byte in raw.utf8 {
            if let event = try decoder.feed(byte: byte) { events.append(event) }
        }
        XCTAssertEqual(events, [StreamEvent(text: "Hello 🌎"), StreamEvent(text: "Refusal text"),
                                StreamEvent(done: true, finishReason: "stop")])
        for failure in [
            #"{"type":"response.incomplete","response":{"status":"incomplete"}}"#,
            #"{"type":"response.failed","response":{"error":{"message":"Failed"}}}"#,
            #"{"type":"error","message":"Service unavailable"}"#,
            #"{"type":"response.completed","response":{"status":"incomplete"}}"#
        ] {
            var failed = EventStreamDecoder()
            _ = try failed.feed("data: " + failure)
            XCTAssertThrowsError(try failed.feed(""))
        }
    }
}
