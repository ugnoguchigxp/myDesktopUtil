import AppKit
import Carbon
import DeskCore
import XCTest

@testable import DeskAgent

final class ShortcutRecorderTests: XCTestCase {
  @MainActor private func event(keyCode: Int, flags: NSEvent.ModifierFlags = []) throws -> NSEvent {
    try XCTUnwrap(NSEvent.keyEvent(
      with: .keyDown, location: .zero, modifierFlags: flags, timestamp: 0,
      windowNumber: 0, context: nil, characters: "", charactersIgnoringModifiers: "",
      isARepeat: false, keyCode: UInt16(keyCode)
    ))
  }

  @MainActor func testRecordsPressedKeyAndModifierCombination() async throws {
    let recorder = ShortcutRecorderButton()
    var recordedModifiers: Set<HotKeyModifier> = []
    recorder.onRecord = { _, modifiers in recordedModifiers = modifiers }
    recorder.keyDown(with: try event(keyCode: kVK_ANSI_K, flags: [.command, .option, .shift, .control]))
    XCTAssertEqual(recorder.key, "K")
    XCTAssertEqual(recordedModifiers, [.command, .option, .shift, .control])
  }

  @MainActor func testSingleKeyCanBeCombinedWithCheckboxModifiers() async throws {
    let recorder = ShortcutRecorderButton()
    var recordedModifiers: Set<HotKeyModifier> = [.shift]
    recorder.onRecord = { _, modifiers in recordedModifiers = modifiers }
    recorder.keyDown(with: try event(keyCode: kVK_ANSI_7))
    XCTAssertEqual(recorder.key, "7")
    XCTAssertEqual(recordedModifiers, [])
  }

  @MainActor func testDeleteClearsShortcutAndModifiedDeleteCanBeRecorded() async throws {
    let recorder = ShortcutRecorderButton()
    recorder.key = "K"
    recorder.keyDown(with: try event(keyCode: kVK_Delete))
    XCTAssertNil(recorder.key)
    recorder.keyDown(with: try event(keyCode: kVK_Delete, flags: .command))
    XCTAssertEqual(recorder.key, "DELETE")
  }

  @MainActor func testCapturesSpaceFunctionAndPunctuationKeys() async throws {
    let recorder = ShortcutRecorderButton()
    for (code, name) in [(kVK_Space, "SPACE"), (kVK_F12, "F12"), (kVK_ANSI_Equal, "="), (kVK_ANSI_Slash, "/")] {
      recorder.keyDown(with: try event(keyCode: code, flags: .control))
      XCTAssertEqual(recorder.key, name)
      XCTAssertNoThrow(try HotKey.parse("Control+\(name)"))
    }
  }
}
