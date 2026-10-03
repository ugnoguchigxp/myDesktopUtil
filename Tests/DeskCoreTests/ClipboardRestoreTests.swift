import DeskCore
import XCTest

final class ClipboardRestoreTests: XCTestCase {
  func testClipboardRestoreRequiresOwnershipAndMarker() {
    XCTAssertEqual(
      ClipboardRestoreDecision.decide(
        expectedChangeCount: 10,
        currentChangeCount: 10,
        markerMatches: true
      ),
      .restore
    )
    XCTAssertEqual(
      ClipboardRestoreDecision.decide(
        expectedChangeCount: 10,
        currentChangeCount: 11,
        markerMatches: true
      ),
      .leaveCurrentContents
    )
    XCTAssertEqual(
      ClipboardRestoreDecision.decide(
        expectedChangeCount: 10,
        currentChangeCount: 10,
        markerMatches: false
      ),
      .leaveCurrentContents
    )
  }
}
