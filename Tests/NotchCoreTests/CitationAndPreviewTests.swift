import XCTest
@testable import NotchCore

final class CitationAndPreviewTests: XCTestCase {
    func testMemoryCitationIDsMustReferToRetrievedEvidence() throws {
        XCTAssertNoThrow(try EvidenceCitations.validate("Homework is due Friday [session-segment-0].", allowed: ["session-segment-0"]))
        XCTAssertThrowsError(try EvidenceCitations.validate("It is due Monday [made-up-source].", allowed: ["session-segment-0"]))
        XCTAssertThrowsError(try EvidenceCitations.validate("A claim with no source.", allowed: ["session-segment-0"]))
    }
    func testPreviewButtonsDoNotDisappearWhenPointerEnters() {
        let start = Date(timeIntervalSince1970: 100)
        var state = NotchPresentation()
        state.beginAnswer(); state.reveal(at: start)
        state.hover(true, at: start.addingTimeInterval(1))
        XCTAssertEqual(state.phase, .preview)
        state.tick(at: start.addingTimeInterval(30)); XCTAssertEqual(state.phase, .preview)
        state.hover(false, at: start.addingTimeInterval(31))
        state.tick(at: start.addingTimeInterval(32)); XCTAssertEqual(state.phase, .compact)
    }
}
