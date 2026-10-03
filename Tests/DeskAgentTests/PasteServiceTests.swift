import AppKit
import DeskCore
import XCTest

@testable import DeskAgent

final class PasteServiceTests: XCTestCase {
  @MainActor func testCopyStoresExactPlainTextWithoutSendingPaste() async throws {
    let board = NSPasteboard.withUniqueName()
    defer { board.releaseGlobally() }
    let oldType = NSPasteboard.PasteboardType("com.local.deskagent.previous-data")
    board.setData(Data([1, 2, 3]), forType: oldType)
    let service = PasteService(pasteboard: board)
    let text = "\n本文\n\n空行と引用\"\n"
    try service.copy(text: text)
    XCTAssertEqual(board.string(forType: .string), text)
    XCTAssertTrue(board.types?.contains(.string) == true)
    XCTAssertNil(board.data(forType: oldType))
    XCTAssertFalse(board.types?.contains(.rtf) == true)
  }

  @MainActor func testCopyKeepsOriginalClipboardWhenItCannotBePreserved() async throws {
    let board = NSPasteboard.withUniqueName()
    defer { board.releaseGlobally() }
    let type = NSPasteboard.PasteboardType("com.local.deskagent.test-data")
    let original = Data(repeating: 1, count: DeskLimits.maxClipboardSnapshotBytes + 1)
    board.setData(original, forType: type)
    let changeCount = board.changeCount
    let service = PasteService(pasteboard: board)
    XCTAssertThrowsError(try service.copy(text: "new"))
    XCTAssertEqual(board.changeCount, changeCount)
    XCTAssertEqual(board.data(forType: type), original)
  }
}
