import DeskCore
import Foundation
import XCTest

@testable import DeskAgent

final class OutlookIntegrationTests: XCTestCase {
  func testMapperCreatesStableOccurrenceIdentifier() throws {
    let startAt = Date(timeIntervalSince1970: 2_000_000_000)

    let event = try OutlookEventMapper.makeEvent(
      providerID: "calendar-item",
      title: "Weekly Meeting",
      startAt: startAt,
      isCancelled: false,
      isAllDay: false,
      response: .accepted
    )

    XCTAssertEqual(event.id, "outlook:calendar-item#2000000000")
    XCTAssertEqual(event.title, "Weekly Meeting")
    XCTAssertEqual(event.startAt, startAt)
    XCTAssertFalse(event.isAllDay)
    XCTAssertEqual(event.response, .accepted)
  }

  func testMapperPreservesDeclinedAndAllDayFlagsForFiltering() throws {
    let event = try OutlookEventMapper.makeEvent(
      providerID: "declined",
      title: "Declined",
      startAt: Date(timeIntervalSince1970: 2_000_000_000),
      isCancelled: false,
      isAllDay: true,
      response: .declined
    )

    XCTAssertTrue(event.isAllDay)
    XCTAssertEqual(event.response, .declined)
    XCTAssertFalse(event.isAlarmEligible)
  }

  func testMapperPreservesCancellationForFiltering() throws {
    let event = try OutlookEventMapper.makeEvent(
      providerID: "cancelled",
      title: "Cancelled",
      startAt: Date(timeIntervalSince1970: 2_000_000_000),
      isCancelled: true,
      isAllDay: false,
      response: .accepted
    )

    XCTAssertTrue(event.isCancelled)
    XCTAssertFalse(event.isAlarmEligible)
  }

  func testMapperHashesProviderIdentifierThatCannotBePersistedDirectly() throws {
    let event = try OutlookEventMapper.makeEvent(
      providerID: "bad\nidentifier",
      title: "Valid",
      startAt: Date(timeIntervalSince1970: 2_000_000_000),
      isCancelled: false,
      isAllDay: false,
      response: .none
    )

    XCTAssertTrue(event.id.hasPrefix("outlook-h:"))
    XCTAssertFalse(event.id.contains("\n"))
    XCTAssertTrue(ProviderIdentifierPolicy.isAllowed(event.id))
  }

  func testMapperRejectsMissingIdentifierAndInvalidDate() {
    XCTAssertThrowsError(
      try OutlookEventMapper.makeEvent(
        providerID: "",
        title: "Invalid",
        startAt: Date(timeIntervalSince1970: 2_000_000_000),
        isCancelled: false,
        isAllDay: false,
        response: .none
      )
    ) {
      XCTAssertEqual($0 as? OutlookIntegrationError, .invalidEvent)
    }

    XCTAssertThrowsError(
      try OutlookEventMapper.makeEvent(
        providerID: "event",
        title: "Invalid",
        startAt: Date(timeIntervalSince1970: .infinity),
        isCancelled: false,
        isAllDay: false,
        response: .none
      )
    ) {
      XCTAssertEqual($0 as? OutlookIntegrationError, .invalidEvent)
    }
  }

  func testMapperBoundsLongTitles() throws {
    let event = try OutlookEventMapper.makeEvent(
      providerID: "long-title",
      title: "a" + String(repeating: "\u{0301}", count: 2_000),
      startAt: Date(timeIntervalSince1970: 2_000_000_000),
      isCancelled: false,
      isAllDay: false,
      response: .none
    )

    XCTAssertLessThanOrEqual(
      event.title.utf8.count,
      DeskLimits.maxMessagePreviewBytes
    )
  }

  func testSelectionKeepsEarliestEligibleEventsWithinLimit() {
    let startAt = Date(timeIntervalSince1970: 2_000_000_000)
    var events = (0...DeskLimits.maxCalendarEvents).map { index in
      OutlookEvent(
        id: "event-\(index)",
        title: "Meeting",
        startAt: startAt.addingTimeInterval(TimeInterval(index)),
        response: .accepted
      )
    }
    events.insert(
      OutlookEvent(
        id: "declined",
        title: "Declined",
        startAt: startAt.addingTimeInterval(-1),
        response: .declined
      ),
      at: 0
    )

    let selected = OutlookEventSelection.boundedAlarmCandidates(events)

    XCTAssertEqual(selected.count, DeskLimits.maxCalendarEvents)
    XCTAssertEqual(selected.first?.id, "event-0")
    XCTAssertEqual(
      selected.last?.id,
      "event-\(DeskLimits.maxCalendarEvents - 1)"
    )
    XCTAssertFalse(selected.contains { $0.id == "declined" })
  }

  func testLegacyGraphPollIntervalMigratesToOutlookInterval() throws {
    let data = Data(
      """
      {
        "graphPollSeconds": 240,
        "microsoft": {
          "clientID": "ignored",
          "tenantID": "ignored"
        },
        "slack": {
          "selfUserID": "U_SELF"
        }
      }
      """.utf8
    )

    let configuration = try JSONDecoder().decode(
      ConnectionConfiguration.self,
      from: data
    )
    XCTAssertEqual(configuration.outlookPollSeconds, 240)
    XCTAssertEqual(configuration.slack?.selfUserID, "U_SELF")
  }
}
