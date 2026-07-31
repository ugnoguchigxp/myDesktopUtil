import XCTest

@testable import DeskCore

final class SnippetsTests: XCTestCase {
  func testParsesSample() throws {
    let snippets = try SnippetsTOML.parse(SnippetsTOML.sample())
    XCTAssertEqual(snippets.count, 2)
    XCTAssertEqual(snippets[0].id, "codex-review")
    XCTAssertEqual(snippets[0].hotKey?.description, "Cmd+Option+1")
    XCTAssertTrue(snippets[0].text.contains("型安全性"))
  }

  func testRejectsDuplicateID() {
    let source = """
      [[snippets]]
      id = "same"
      label = "One"
      text = "one"

      [[snippets]]
      id = "same"
      label = "Two"
      text = "two"
      """
    XCTAssertThrowsError(try SnippetsTOML.parse(source)) { error in
      XCTAssertEqual(error as? SnippetError, .duplicateID("same"))
    }
  }

  func testRejectsDuplicateHotKey() {
    let source = """
      [[snippets]]
      id = "one"
      label = "One"
      hotkey = "Cmd+Option+1"
      text = "one"

      [[snippets]]
      id = "two"
      label = "Two"
      hotkey = "command+alt+1"
      text = "two"
      """
    XCTAssertThrowsError(try SnippetsTOML.parse(source)) { error in
      XCTAssertEqual(error as? SnippetError, .duplicateHotKey("Cmd+Option+1"))
    }
  }

  func testRejectsInvalidHotKey() {
    XCTAssertThrowsError(try HotKey.parse("Cmd+Option+NotAKey"))
  }

  func testRejectsEmptyText() {
    let source = """
      [[snippets]]
      id = "empty"
      label = "Empty"
      text = "   "
      """
    XCTAssertThrowsError(try SnippetsTOML.parse(source)) { error in
      XCTAssertEqual(error as? SnippetError, .emptyText("empty"))
    }
  }

  func testRejectsWhitespaceOnlyLabel() {
    let source = """
      [[snippets]]
      id = "empty-label"
      label = "   "
      text = "text"
      """
    XCTAssertThrowsError(try SnippetsTOML.parse(source)) { error in
      XCTAssertEqual(
        error as? SnippetError,
        .missingField(index: 0, field: "label")
      )
    }
  }

  func testRejectsExtremelyLargeSnippet() {
    let source = """
      [[snippets]]
      id = "large"
      label = "Large"
      text = "\(String(repeating: "x", count: DeskLimits.maxSnippetBytes + 1))"
      """
    XCTAssertThrowsError(try SnippetsTOML.parse(source)) { error in
      XCTAssertEqual(error as? SnippetError, .snippetTooLarge("large"))
    }
  }

  func testRejectsExtremelyLongLabel() {
    let source = """
      [[snippets]]
      id = "long-label"
      label = "\(String(repeating: "x", count: DeskLimits.maxSnippetLabelCharacters + 1))"
      text = "text"
      """
    XCTAssertThrowsError(try SnippetsTOML.parse(source)) { error in
      XCTAssertEqual(error as? SnippetError, .labelTooLarge("long-label"))
    }
  }

  func testRejectsLabelThatIsSmallInCharactersButLargeInBytes() {
    let combiningLabel = "a" + String(repeating: "\u{0301}", count: 600)
    let source = """
      [[snippets]]
      id = "large-byte-label"
      label = "\(combiningLabel)"
      text = "text"
      """

    XCTAssertThrowsError(try SnippetsTOML.parse(source)) { error in
      XCTAssertEqual(error as? SnippetError, .labelTooLarge("large-byte-label"))
    }
  }
}
