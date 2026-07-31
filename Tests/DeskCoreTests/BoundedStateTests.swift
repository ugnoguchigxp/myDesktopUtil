import XCTest

@testable import DeskCore

final class BoundedStateTests: XCTestCase {
  func testBoundedIdentifierSetEvictsOldest() {
    var values = BoundedIdentifierSet(capacity: 2)
    XCTAssertTrue(values.insert("one"))
    XCTAssertTrue(values.insert("two"))
    XCTAssertTrue(values.insert("three"))
    XCTAssertFalse(values.contains("one"))
    XCTAssertEqual(values.allValues, ["two", "three"])
  }

  func testDuplicateIdentifierIsIgnored() {
    var values = BoundedIdentifierSet(capacity: 2)
    XCTAssertTrue(values.insert("one"))
    XCTAssertFalse(values.insert("one"))
    XCTAssertEqual(values.count, 1)
  }

  func testExistingIdentifierSetKeepsNewestUniqueValues() {
    let values = BoundedIdentifierSet(
      capacity: 2,
      existing: ["old", "new", "new"]
    )
    XCTAssertEqual(values.allValues, ["old", "new"])
  }

  func testUTF8PrefixNeverSplitsAScalarOrExceedsByteLimit() {
    XCTAssertEqual(TextBounds.utf8Prefix("a\u{0301}", maxBytes: 2), "a")
    XCTAssertEqual(TextBounds.utf8Prefix("😀x", maxBytes: 4), "😀")
    XCTAssertEqual(TextBounds.utf8Prefix("😀x", maxBytes: 3), "")
    XCTAssertEqual(TextBounds.utf8Prefix("abc", maxBytes: 0), "")
  }

  func testIdentifierCanBeRemoved() {
    var values = BoundedIdentifierSet(capacity: 2, existing: ["one", "two"])
    XCTAssertTrue(values.remove("one"))
    XCTAssertFalse(values.remove("missing"))
    XCTAssertEqual(values.allValues, ["two"])
  }

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

  func testStateStoreRoundTripPreservesDatesAndLimits() throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(
      UUID().uuidString,
      isDirectory: true
    )
    defer { try? FileManager.default.removeItem(at: directory) }
    let store = JSONStateStore(fileURL: directory.appendingPathComponent("state.json"))
    let date = Date(timeIntervalSince1970: 2_000_000_000)
    let state = PersistedState(
      graphDeltaLink: "https://graph.microsoft.com/delta",
      graphWindowStart: date,
      graphWindowEnd: date.addingTimeInterval(3_600),
      calendarEvents: [
        OutlookEvent(id: "event", title: "Meeting", startAt: date)
      ],
      recentSlackEventIDs: (0...600).map { "event-\($0)" }
    )

    try store.save(state)
    let loaded = try store.loadExistingFile()

    XCTAssertEqual(loaded.graphWindowStart, date)
    XCTAssertEqual(loaded.graphDeltaLink, "https://graph.microsoft.com/delta")
    XCTAssertEqual(loaded.calendarEvents.first?.id, "event")
    XCTAssertEqual(loaded.recentSlackEventIDs.count, DeskLimits.maxRecentSlackEventIDs)
    XCTAssertEqual(loaded.recentSlackEventIDs.last, "event-600")
  }

  func testPersistedStateDeduplicatesCalendarEventsWithoutCrashing() {
    let date = Date(timeIntervalSince1970: 2_000_000_000)
    let state = PersistedState(
      calendarEvents: [
        OutlookEvent(id: "event", title: "Old", startAt: date),
        OutlookEvent(id: "event", title: "New", startAt: date),
      ]
    )

    XCTAssertEqual(state.calendarEvents.count, 1)
    XCTAssertEqual(state.calendarEvents.first?.title, "New")
  }

  func testPersistedStateBoundsProviderStrings() {
    let oversizedID = String(
      repeating: "x",
      count: DeskLimits.maxProviderIdentifierBytes + 1
    )
    let oversizedTitle = "a" + String(repeating: "\u{0301}", count: 2_000)
    let state = PersistedState(
      graphDeltaLink: String(
        repeating: "x",
        count: DeskLimits.maxProviderURLBytes + 1
      ),
      calendarEvents: [
        OutlookEvent(id: oversizedID, title: "Dropped", startAt: Date()),
        OutlookEvent(id: "kept", title: oversizedTitle, startAt: Date()),
      ],
      recentSlackEventIDs: [oversizedID]
    )

    XCTAssertNil(state.graphDeltaLink)
    XCTAssertEqual(state.calendarEvents.map(\.id), ["kept"])
    XCTAssertLessThanOrEqual(
      state.calendarEvents[0].title.utf8.count,
      DeskLimits.maxMessagePreviewBytes
    )
    XCTAssertTrue(state.recentSlackEventIDs.isEmpty)
  }

  func testPersistedStateDeduplicatesAndDropsEmptyIdentifiers() {
    let state = PersistedState(
      calendarEvents: [
        OutlookEvent(id: "bad\nid", title: "Dropped", startAt: Date())
      ],
      recentSlackEventIDs: ["", "old", "bad\nid", "new", "new"],
      notifiedEventIDs: ["", "first", "bad\tid", "second", "second"]
    )

    XCTAssertTrue(state.calendarEvents.isEmpty)
    XCTAssertEqual(state.recentSlackEventIDs, ["old", "new"])
    XCTAssertEqual(state.notifiedEventIDs, ["first", "second"])
  }

  func testPersistedStateDropsUntrustedOrIncompleteGraphDeltaState() {
    let now = Date()
    let untrusted = PersistedState(
      graphDeltaLink: "https://example.com/steal",
      graphWindowStart: now,
      graphWindowEnd: now.addingTimeInterval(3_600)
    )
    let incomplete = PersistedState(
      graphDeltaLink: "https://graph.microsoft.com/delta",
      graphWindowStart: now
    )

    XCTAssertNil(untrusted.graphDeltaLink)
    XCTAssertNil(untrusted.graphWindowStart)
    XCTAssertNil(untrusted.graphWindowEnd)
    XCTAssertNil(incomplete.graphDeltaLink)
    XCTAssertNil(incomplete.graphWindowStart)
    XCTAssertNil(incomplete.graphWindowEnd)
  }

  func testStateStoreDoesNotWriteAFileItCannotLoad() throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(
      UUID().uuidString,
      isDirectory: true
    )
    defer { try? FileManager.default.removeItem(at: directory) }
    let stateURL = directory.appendingPathComponent("state.json")
    let store = JSONStateStore(fileURL: stateURL)
    let escapedTitle = String(repeating: "\0", count: DeskLimits.maxMessagePreviewCharacters)
    let state = PersistedState(
      calendarEvents: (0..<DeskLimits.maxCalendarEvents).map { index in
        OutlookEvent(
          id: String(repeating: "\\", count: 500) + String(index),
          title: escapedTitle,
          startAt: Date()
        )
      },
      recentSlackEventIDs: (0..<DeskLimits.maxRecentSlackEventIDs).map { index in
        String(repeating: "\\", count: 500) + String(index)
      },
      notifiedEventIDs: (0..<DeskLimits.maxNotifiedEventIDs).map { index in
        String(repeating: "\\", count: 500) + String(index)
      }
    )

    XCTAssertThrowsError(try store.save(state)) { error in
      XCTAssertEqual(error as? ProviderParseError, .payloadTooLarge)
    }
    XCTAssertFalse(FileManager.default.fileExists(atPath: stateURL.path))
  }

  func testCorruptStateIsBackedUpAndIgnored() throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(
      UUID().uuidString,
      isDirectory: true
    )
    defer { try? FileManager.default.removeItem(at: directory) }
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    let stateURL = directory.appendingPathComponent("state.json")
    try Data("not-json".utf8).write(to: stateURL)

    let loaded = JSONStateStore(fileURL: stateURL).load()
    let files = try FileManager.default.contentsOfDirectory(
      at: directory,
      includingPropertiesForKeys: nil
    )

    XCTAssertEqual(loaded, PersistedState())
    XCTAssertFalse(FileManager.default.fileExists(atPath: stateURL.path))
    XCTAssertTrue(files.contains { $0.lastPathComponent.contains(".corrupt-") })
  }

  func testAlertJSONRoundTrip() throws {
    let alert = Alert(
      id: "event",
      source: .calendar,
      title: "Meeting",
      body: "Starts soon",
      startsAt: Date(timeIntervalSince1970: 2_000_000_000)
    )
    let decoded = try JSONDecoder().decode(
      Alert.self,
      from: JSONEncoder().encode(alert)
    )
    XCTAssertEqual(decoded, alert)
  }
}
