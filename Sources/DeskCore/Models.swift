import Foundation

public enum DeskLimits {
  public static let maxSnippets = 256
  public static let maxSnippetBytes = 64 * 1_024
  public static let maxSnippetLabelCharacters = 128
  public static let maxSnippetLabelBytes = 512
  public static let maxTotalSnippetBytes = 2 * 1_024 * 1_024
  public static let maxClipboardSnapshotBytes = 4 * 1_024 * 1_024
  public static let maxClipboardItems = 128
  public static let maxClipboardRepresentations = 512
  public static let maxIncomingEventBytes = 512 * 1_024
  public static let maxAlertQueue = 8
  public static let maxRecentSlackEventIDs = 512
  public static let maxNotifiedEventIDs = 1_024
  public static let maxMessagePreviewCharacters = 256
  public static let maxMessagePreviewBytes = 1_024
  public static let maxProviderIdentifierBytes = 512
  public static let maxProviderUserIDBytes = 256
  public static let maxProviderURLBytes = 16 * 1_024
  public static let maxCalendarEvents = 1_024
  public static let maxPersistedStateBytes = 4 * 1_024 * 1_024
}

public enum AlertSource: String, Codable, Sendable {
  case calendar
  case slack
  case test
}

public struct Alert: Codable, Equatable, Sendable {
  public let id: String
  public let source: AlertSource
  public let title: String
  public let body: String
  public let startsAt: Date?

  public init(
    id: String,
    source: AlertSource,
    title: String,
    body: String,
    startsAt: Date? = nil
  ) {
    self.id = id
    self.source = source
    self.title = title
    self.body = body
    self.startsAt = startsAt
  }
}

public enum OutlookResponse: String, Codable, Sendable {
  case none
  case organizer
  case tentativelyAccepted
  case accepted
  case declined
  case notResponded
}

public struct OutlookEvent: Codable, Equatable, Sendable {
  public let id: String
  public let title: String
  public let startAt: Date?
  public let isCancelled: Bool
  public let isAllDay: Bool
  public let response: OutlookResponse

  public init(
    id: String,
    title: String,
    startAt: Date?,
    isCancelled: Bool = false,
    isAllDay: Bool = false,
    response: OutlookResponse = .none
  ) {
    self.id = id
    self.title = title
    self.startAt = startAt
    self.isCancelled = isCancelled
    self.isAllDay = isAllDay
    self.response = response
  }

  public var isAlarmEligible: Bool {
    !isCancelled && !isAllDay && response != .declined && startAt != nil
  }

  public var notificationKey: String? {
    guard let startAt else {
      return nil
    }
    return "\(id)|\(Int(startAt.timeIntervalSince1970))"
  }
}

public enum ClipboardRestoreDecision: Equatable, Sendable {
  case restore
  case leaveCurrentContents

  public static func decide(
    expectedChangeCount: Int,
    currentChangeCount: Int,
    markerMatches: Bool
  ) -> Self {
    guard expectedChangeCount == currentChangeCount, markerMatches else {
      return .leaveCurrentContents
    }
    return .restore
  }
}
