import AppKit
import DeskCore
import XCTest

@testable import DeskAgent

final class PasteSettingsWindowTests: XCTestCase {
  @MainActor private func button(in view: NSView, title: String) -> NSButton? {
    if let button = view as? NSButton, button.title == title { return button }
    for child in view.subviews {
      if let result = button(in: child, title: title) { return result }
    }
    return nil
  }

  @MainActor func testSavePersistsAndClosesRegularWindow() async throws {
    _ = NSApplication.shared
    let snippets = try SnippetsTOML.parse(SnippetsTOML.sample())
    var saved: [Snippet]?
    var closed = false
    let controller = PasteSettingsController(snippets: snippets) { saved = $0 }
    controller.onClose = { closed = true }
    let content = try XCTUnwrap(controller.window?.contentView)
    try XCTUnwrap(button(in: content, title: "保存")).performClick(nil)
    XCTAssertEqual(saved, snippets)
    XCTAssertTrue(closed)
    XCTAssertNil(NSApp.modalWindow)
  }

  @MainActor func testCancelClosesWithoutSaving() async throws {
    _ = NSApplication.shared
    var saved = false
    var closed = false
    let controller = PasteSettingsController(snippets: []) { _ in saved = true }
    controller.onClose = { closed = true }
    let content = try XCTUnwrap(controller.window?.contentView)
    try XCTUnwrap(button(in: content, title: "キャンセル")).performClick(nil)
    XCTAssertFalse(saved)
    XCTAssertTrue(closed)
    XCTAssertNil(NSApp.modalWindow)
  }

  @MainActor func testSaveFailureKeepsEditorOpenForCorrection() async throws {
    _ = NSApplication.shared
    var closed = false
    var attempted = false
    let controller = PasteSettingsController(snippets: []) { _ in
      attempted = true
      throw SnippetStore.SaveError.changedOnDisk
    }
    controller.onClose = { closed = true }
    let content = try XCTUnwrap(controller.window?.contentView)
    try XCTUnwrap(button(in: content, title: "保存")).performClick(nil)
    XCTAssertTrue(attempted)
    XCTAssertFalse(closed)
    XCTAssertNil(NSApp.modalWindow)
  }
}
