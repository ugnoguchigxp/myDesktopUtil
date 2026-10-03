import DeskCore
import Foundation
import XCTest

@testable import DeskAgent

final class SnippetStoreTests: XCTestCase {
  private func temporaryDirectory() throws -> URL {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    addTeardownBlock { try FileManager.default.removeItem(at: directory) }
    return directory
  }

  @MainActor func testDeletedDefaultsStayDeletedAfterReloadAndRestart() async throws {
    let directory = try temporaryDirectory()
    let store = SnippetStore(directory: directory)
    store.load()
    XCTAssertNil(store.lastError)
    try store.save([])
    store.load()
    XCTAssertEqual(store.snippets, [])
    let restarted = SnippetStore(directory: directory)
    restarted.load()
    XCTAssertNil(restarted.lastError)
    XCTAssertEqual(restarted.snippets, [])
  }

  @MainActor func testSavesCustomContentShortcutsAndAdditionalItems() async throws {
    let directory = try temporaryDirectory()
    let store = SnippetStore(directory: directory)
    store.load()
    let custom = Snippet(id: "custom", label: "自由な定型文", hotKey: try HotKey.parse("Control+Shift+K"), text: "\n本文\n\n末尾\n", pasteMode: .copy)
    let updated = store.snippets + [custom]
    try store.save(updated)
    let restarted = SnippetStore(directory: directory)
    restarted.load()
    XCTAssertEqual(restarted.snippets, updated)
  }

  @MainActor func testRefusesToOverwriteAnExternalEdit() async throws {
    let directory = try temporaryDirectory()
    let store = SnippetStore(directory: directory)
    store.load()
    let file = directory.appendingPathComponent("snippets.toml")
    let externalData = try Data(contentsOf: file) + Data("\n# External edit\n".utf8)
    try externalData.write(to: file, options: .atomic)
    XCTAssertThrowsError(try store.save(store.snippets))
    XCTAssertEqual(try Data(contentsOf: file), externalData)
  }

  @MainActor func testInvalidDraftDoesNotChangeSavedConfiguration() async throws {
    let directory = try temporaryDirectory()
    let store = SnippetStore(directory: directory)
    store.load()
    let original = store.snippets
    let file = directory.appendingPathComponent("snippets.toml")
    let originalData = try Data(contentsOf: file)
    XCTAssertThrowsError(try store.save(original + [Snippet(id: "blank", label: "Blank", hotKey: nil, text: "")]))
    XCTAssertEqual(store.snippets, original)
    XCTAssertEqual(try Data(contentsOf: file), originalData)
  }

  @MainActor func testMigrationBacksUpOriginalWithoutReplacingExistingContent() async throws {
    let directory = try temporaryDirectory()
    let file = directory.appendingPathComponent("snippets.toml")
    let custom = Snippet(id: "existing", label: "Existing", hotKey: try HotKey.parse("Cmd+Option+3"), text: "My original text")
    let originalData = Data(try SnippetsTOML.serialize([custom]).utf8)
    try originalData.write(to: file)
    let store = SnippetStore(directory: directory)
    store.load()
    XCTAssertNil(store.lastError)
    XCTAssertEqual(store.snippets.count, 6)
    XCTAssertEqual(store.snippets.first, custom)
    let backup = directory.appendingPathComponent("snippets.before-six-slots.toml")
    XCTAssertEqual(try Data(contentsOf: backup), originalData)
    try store.save([custom])
    store.load()
    XCTAssertEqual(store.snippets, [custom])
    XCTAssertEqual(try Data(contentsOf: backup), originalData)
  }
}
