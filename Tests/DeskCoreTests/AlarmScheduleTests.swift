import XCTest

@testable import DeskCore

final class AlarmScheduleTests: XCTestCase {
  private let start = Date(timeIntervalSince1970: 2_000_000_000)

  func testAlarmFiresTwoMinutesBeforeStart() {
    var schedule = AlarmScheduleBook()
    schedule.apply(OutlookEvent(id: "event", title: "Meeting", startAt: start))

    XCTAssertTrue(
      schedule.dueAlerts(at: start.addingTimeInterval(-121)).isEmpty
    )
    XCTAssertEqual(
      schedule.dueAlerts(at: start.addingTimeInterval(-120)).count,
      1
    )
  }

  func testUpdatedEventReplacesOldSchedule() {
    var schedule = AlarmScheduleBook()
    schedule.apply(OutlookEvent(id: "event", title: "Old", startAt: start))
    let updatedStart = start.addingTimeInterval(600)
    schedule.apply(OutlookEvent(id: "event", title: "New", startAt: updatedStart))

    XCTAssertTrue(
      schedule.dueAlerts(at: start.addingTimeInterval(-120)).isEmpty
    )
    XCTAssertEqual(
      schedule.dueAlerts(at: updatedStart.addingTimeInterval(-120)).first?.title,
      "New"
    )
  }

  func testIneligibleEventsAreExcluded() {
    var schedule = AlarmScheduleBook()
    schedule.apply(
      OutlookEvent(id: "cancelled", title: "", startAt: start, isCancelled: true)
    )
    schedule.apply(
      OutlookEvent(id: "all-day", title: "", startAt: start, isAllDay: true)
    )
    schedule.apply(
      OutlookEvent(id: "declined", title: "", startAt: start, response: .declined)
    )
    XCTAssertEqual(schedule.eventCount, 0)
  }

  func testCancellationRemovesPreviouslyScheduledEvent() {
    var schedule = AlarmScheduleBook()
    schedule.apply(OutlookEvent(id: "event", title: "Meeting", startAt: start))
    schedule.apply(
      OutlookEvent(
        id: "event",
        title: "Meeting",
        startAt: start,
        isCancelled: true
      )
    )
    XCTAssertEqual(schedule.eventCount, 0)
  }

  func testWakeGraceStartsAtTwoAndHalfMinutes() {
    var schedule = AlarmScheduleBook()
    schedule.apply(OutlookEvent(id: "event", title: "Meeting", startAt: start))
    XCTAssertTrue(
      schedule.dueAlerts(
        at: start.addingTimeInterval(-151),
        afterWake: true
      ).isEmpty
    )
    XCTAssertEqual(
      schedule.dueAlerts(
        at: start.addingTimeInterval(-150),
        afterWake: true
      ).count,
      1
    )
  }

  func testSameEventIsNotNotifiedTwice() {
    var schedule = AlarmScheduleBook()
    schedule.apply(OutlookEvent(id: "event", title: "Meeting", startAt: start))
    XCTAssertEqual(
      schedule.dueAlerts(at: start.addingTimeInterval(-120)).count,
      1
    )
    XCTAssertTrue(
      schedule.dueAlerts(at: start.addingTimeInterval(-60)).isEmpty
    )
  }

  func testNotificationCanBeRetriedAfterQueueOverflow() {
    var schedule = AlarmScheduleBook()
    schedule.apply(OutlookEvent(id: "event", title: "Meeting", startAt: start))
    let firstAlert = schedule.dueAlerts(at: start.addingTimeInterval(-120)).first

    schedule.retryNotification(key: firstAlert?.id ?? "")

    XCTAssertEqual(
      schedule.dueAlerts(at: start.addingTimeInterval(-60)).first?.id,
      firstAlert?.id
    )
  }

  func testSnapshotWithDuplicateIDsUsesLatestEventWithoutCrashing() {
    var schedule = AlarmScheduleBook()
    schedule.applySnapshot([
      OutlookEvent(id: "event", title: "Old", startAt: start),
      OutlookEvent(id: "event", title: "New", startAt: start),
    ])

    XCTAssertEqual(schedule.eventCount, 1)
    XCTAssertEqual(
      schedule.dueAlerts(at: start.addingTimeInterval(-120)).first?.title,
      "New"
    )
  }
}
