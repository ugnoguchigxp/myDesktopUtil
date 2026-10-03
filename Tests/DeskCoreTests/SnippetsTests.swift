import XCTest

@testable import DeskCore

final class SnippetsTests: XCTestCase {
  func testParsesSample() throws {
    let snippets = try SnippetsTOML.parse(SnippetsTOML.sample())
    XCTAssertEqual(snippets.count, 6)
    XCTAssertEqual(snippets[0].id, "codex-review")
    XCTAssertEqual(snippets[0].hotKey?.description, "Cmd+Option+1")
    XCTAssertTrue(snippets[0].text.contains("型安全性"))
    XCTAssertEqual(snippets.compactMap { $0.hotKey?.description }, (1...6).map { "Cmd+Option+\($0)" })
  }

  func testMigrationPreservesCustomContentAndAddsOnlyMissingShortcuts() throws {
    let source = """
      # Keep this comment too
      [[snippets]]
      id = "custom-three"
      label = "自分の定型文"
      hotkey = "Cmd+Option+3"
      text = "変更しない本文"
      """
    let expanded = try SnippetsTOML.addingMissingDefaults(to: source)
    XCTAssertTrue(expanded.hasPrefix(source))
    let snippets = try SnippetsTOML.parse(expanded)
    XCTAssertEqual(snippets.count, 6)
    XCTAssertEqual(snippets[0].text, "変更しない本文")
    XCTAssertEqual(snippets.filter { $0.hotKey?.key == "3" }.count, 1)
    XCTAssertEqual(try SnippetsTOML.addingMissingDefaults(to: expanded), expanded)
  }

  func testMigrationKeepsIntentionallyChangedDefaultShortcut() throws {
    let snippet = Snippet(id: "codex-review", label: "Custom", hotKey: nil, text: "custom")
    let source = try SnippetsTOML.serialize([snippet])
    let snippets = try SnippetsTOML.parse(SnippetsTOML.addingMissingDefaults(to: source))
    XCTAssertEqual(snippets.first, snippet)
    XCTAssertFalse(snippets.contains { $0.hotKey?.key == "1" })
  }

  func testSupportsMoreThan256Snippets() throws {
    let snippets = (0..<1_000).map {
      Snippet(id: "custom-\($0)", label: "Custom", hotKey: nil, text: "text")
    }
    let source = try SnippetsTOML.serialize(snippets)
    XCTAssertEqual(try SnippetsTOML.parse(source), snippets)
    XCTAssertEqual(try SnippetsTOML.parse(SnippetsTOML.addingMissingDefaults(to: source)).count, 1_006)
  }

  func testSupportsCustomShortcutsBeyondNumberKeys() throws {
    for key in ["A", "F12", "SPACE", "PAGEUP", "DELETE", "/", "-", "="] {
      let hotKey = try HotKey.parse("Control+Shift+\(key)")
      XCTAssertEqual(hotKey.modifiers, [.control, .shift])
      XCTAssertEqual(hotKey.key, key)
    }
  }

  func testAllowsSavingAnEmptyList() throws {
    XCTAssertEqual(try SnippetsTOML.parse(SnippetsTOML.serialize([])), [])
  }

  func testSerializationPreservesWhitespaceQuotesAndModes() throws {
    let text = "\n\n本文\n\n\n\"\"\" literal \\n\t\r\n"
    let snippets = [
      Snippet(id: "paste", label: "引用\"名", hotKey: try HotKey.parse("Cmd+Option+6"), text: text),
      Snippet(id: "copy", label: "Copy", hotKey: nil, text: "copy me", pasteMode: .copy),
    ]
    XCTAssertEqual(try SnippetsTOML.parse(SnippetsTOML.serialize(snippets)), snippets)
  }

  func testLegacyConfigurationDefaultsToPaste() throws {
    let source = """
      [[snippets]]
      id = "legacy"
      label = "Legacy"
      text = "text"
      """
    XCTAssertEqual(try SnippetsTOML.parse(source).first?.pasteMode, .paste)
  }

  func testRejectsUnknownPasteMode() {
    let source = """
      [[snippets]]
      id = "invalid"
      label = "Invalid"
      mode = "unknown"
      text = "text"
      """
    XCTAssertThrowsError(try SnippetsTOML.parse(source)) { error in
      XCTAssertEqual(error as? SnippetError, .invalidPasteMode("unknown"))
    }
  }

  func testRejectsShortcutReservedForMenu() {
    let source = """
      [[snippets]]
      id = "reserved"
      label = "Reserved"
      hotkey = "command+alt+p"
      text = "text"
      """
    XCTAssertThrowsError(try SnippetsTOML.parse(source)) { error in
      XCTAssertEqual(error as? SnippetError, .reservedHotKey("Cmd+Option+P"))
    }
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
