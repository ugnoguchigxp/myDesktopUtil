import Foundation

public struct AlarmScheduleBook: Sendable {
  private var eventsByID: [String: OutlookEvent]
  private var notifiedKeys: BoundedIdentifierSet

  public init(notifiedKeys: [String] = []) {
    eventsByID = [:]
    self.notifiedKeys = BoundedIdentifierSet(
      capacity: DeskLimits.maxNotifiedEventIDs,
      existing: notifiedKeys
    )
  }

  public var eventCount: Int {
    eventsByID.count
  }

  public var persistedNotifiedKeys: [String] {
    notifiedKeys.allValues
  }

  public mutating func apply(_ event: OutlookEvent) {
    guard event.isAlarmEligible else {
      eventsByID.removeValue(forKey: event.id)
      return
    }
    guard eventsByID[event.id] != nil || eventsByID.count < DeskLimits.maxCalendarEvents else {
      return
    }
    eventsByID[event.id] = event
  }

  public mutating func remove(eventID: String) {
    eventsByID.removeValue(forKey: eventID)
  }

  public mutating func retryNotification(key: String) {
    notifiedKeys.remove(key)
  }

  public mutating func applySnapshot(_ events: [OutlookEvent]) {
    eventsByID.removeAll(keepingCapacity: true)
    for event in events where event.isAlarmEligible {
      guard
        eventsByID[event.id] != nil
          || eventsByID.count < DeskLimits.maxCalendarEvents
      else {
        continue
      }
      eventsByID[event.id] = event
    }
  }

  public func nextDeadline(after now: Date) -> Date? {
    eventsByID.values.compactMap { event in
      guard let startAt = event.startAt,
        let key = event.notificationKey,
        !notifiedKeys.contains(key)
      else {
        return nil
      }
      let deadline = startAt.addingTimeInterval(-120)
      return deadline > now ? deadline : nil
    }.min()
  }

  public mutating func dueAlerts(at now: Date, afterWake: Bool = false) -> [Alert] {
    var alerts: [Alert] = []
    let sortedEvents = eventsByID.values.sorted {
      ($0.startAt ?? .distantFuture) < ($1.startAt ?? .distantFuture)
    }

    for event in sortedEvents {
      guard let startAt = event.startAt,
        let key = event.notificationKey,
        !notifiedKeys.contains(key)
      else {
        continue
      }
      let lowerBound = startAt.addingTimeInterval(afterWake ? -150 : -120)
      guard now >= lowerBound, now <= startAt else {
        continue
      }

      notifiedKeys.insert(key)
      alerts.append(
        Alert(
          id: key,
          source: .calendar,
          title: event.title.isEmpty ? "Outlookの予定" : event.title,
          body: Self.timeFormatter.string(from: startAt) + " から開始します",
          startsAt: startAt
        )
      )
    }
    return alerts
  }

  public mutating func prune(before date: Date) {
    eventsByID = eventsByID.filter { _, event in
      guard let startAt = event.startAt else {
        return false
      }
      return startAt >= date
    }
  }

  private static let timeFormatter: DateFormatter = {
    let formatter = DateFormatter()
    formatter.locale = Locale(identifier: "ja_JP")
    formatter.dateFormat = "HH:mm"
    return formatter
  }()
}
