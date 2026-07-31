import CryptoKit
import DeskCore
import EventKit
import Foundation

enum OutlookIntegrationError: LocalizedError, Equatable {
  case permissionDenied
  case noExchangeCalendars
  case invalidEvent

  var errorDescription: String? {
    switch self {
    case .permissionDenied:
      "カレンダーの読み取り権限がありません"
    case .noExchangeCalendars:
      "macOSにExchangeカレンダーが設定されていません"
    case .invalidEvent:
      "Outlookの予定データを解析できません"
    }
  }
}

@MainActor
final class OutlookCalendarClient {
  private let eventStore: EKEventStore

  init(eventStore: EKEventStore = EKEventStore()) {
    self.eventStore = eventStore
  }

  func fetchEvents(now: Date = Date()) async throws -> [OutlookEvent] {
    try await ensureFullAccess()

    let calendars = eventStore.calendars(for: .event).filter {
      $0.source.sourceType == .exchange
    }
    guard !calendars.isEmpty else {
      throw OutlookIntegrationError.noExchangeCalendars
    }

    let windowStart = now.addingTimeInterval(-60 * 60)
    let windowEnd = now.addingTimeInterval(14 * 24 * 60 * 60)
    let predicate = eventStore.predicateForEvents(
      withStart: windowStart,
      end: windowEnd,
      calendars: calendars
    )
    let calendarEvents = eventStore.events(matching: predicate)
    let events = try calendarEvents.map { event in
      try OutlookEventMapper.makeEvent(
        providerID: event.calendarItemIdentifier,
        title: event.title ?? "",
        startAt: event.startDate,
        isCancelled: event.status == .canceled,
        isAllDay: event.isAllDay,
        response: Self.response(for: event)
      )
    }
    return OutlookEventSelection.boundedAlarmCandidates(events)
  }

  private func ensureFullAccess() async throws {
    let status = EKEventStore.authorizationStatus(for: .event)
    if #available(macOS 14.0, *) {
      switch status {
      case .fullAccess:
        return
      case .notDetermined:
        guard try await eventStore.requestFullAccessToEvents() else {
          throw OutlookIntegrationError.permissionDenied
        }
      case .restricted, .denied, .writeOnly:
        throw OutlookIntegrationError.permissionDenied
      case .authorized:
        return
      @unknown default:
        throw OutlookIntegrationError.permissionDenied
      }
    } else {
      switch status {
      case .authorized:
        return
      case .notDetermined:
        guard try await requestLegacyAccess() else {
          throw OutlookIntegrationError.permissionDenied
        }
      case .restricted, .denied:
        throw OutlookIntegrationError.permissionDenied
      default:
        throw OutlookIntegrationError.permissionDenied
      }
    }
  }

  @available(macOS, introduced: 10.8, deprecated: 14.0)
  private func requestLegacyAccess() async throws -> Bool {
    try await withCheckedThrowingContinuation { continuation in
      eventStore.requestAccess(to: .event) { granted, error in
        if let error {
          continuation.resume(throwing: error)
        } else {
          continuation.resume(returning: granted)
        }
      }
    }
  }

  private static func response(for event: EKEvent) -> OutlookResponse {
    if event.organizer?.isCurrentUser == true {
      return .organizer
    }
    guard
      let participant = event.attendees?.first(where: \.isCurrentUser)
    else {
      return .none
    }
    switch participant.participantStatus {
    case .accepted:
      return .accepted
    case .declined:
      return .declined
    case .tentative:
      return .tentativelyAccepted
    case .pending:
      return .notResponded
    default:
      return .none
    }
  }
}

enum OutlookEventMapper {
  static func makeEvent(
    providerID: String,
    title: String,
    startAt: Date,
    isCancelled: Bool,
    isAllDay: Bool,
    response: OutlookResponse
  ) throws -> OutlookEvent {
    guard !providerID.isEmpty,
      startAt >= Date.distantPast,
      startAt <= Date.distantFuture
    else {
      throw OutlookIntegrationError.invalidEvent
    }

    let timestamp = String(Int(startAt.timeIntervalSince1970))
    let rawIdentifier = "outlook:\(providerID)#\(timestamp)"
    let identifier: String
    if ProviderIdentifierPolicy.isAllowed(rawIdentifier) {
      identifier = rawIdentifier
    } else {
      let digest = SHA256.hash(data: Data(providerID.utf8))
      let hexDigest = digest.map { String(format: "%02x", $0) }.joined()
      identifier = "outlook-h:\(hexDigest)#\(timestamp)"
    }
    guard ProviderIdentifierPolicy.isAllowed(identifier) else {
      throw OutlookIntegrationError.invalidEvent
    }
    let characterBoundedTitle = String(
      title.prefix(DeskLimits.maxMessagePreviewCharacters)
    )
    return OutlookEvent(
      id: identifier,
      title: TextBounds.utf8Prefix(
        characterBoundedTitle,
        maxBytes: DeskLimits.maxMessagePreviewBytes
      ),
      startAt: startAt,
      isCancelled: isCancelled,
      isAllDay: isAllDay,
      response: response
    )
  }
}

enum OutlookEventSelection {
  static func boundedAlarmCandidates(
    _ events: [OutlookEvent]
  ) -> [OutlookEvent] {
    Array(
      events
        .filter(\.isAlarmEligible)
        .sorted {
          let leftStart = $0.startAt ?? .distantFuture
          let rightStart = $1.startAt ?? .distantFuture
          if leftStart == rightStart {
            return $0.id < $1.id
          }
          return leftStart < rightStart
        }
        .prefix(DeskLimits.maxCalendarEvents)
    )
  }
}
