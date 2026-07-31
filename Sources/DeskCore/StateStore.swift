import Foundation

public struct PersistedState: Codable, Equatable, Sendable {
  public var calendarEvents: [OutlookEvent]
  public var recentSlackEventIDs: [String]
  public var notifiedEventIDs: [String]
  public var lastSuccessfulSync: Date?

  public init(
    calendarEvents: [OutlookEvent] = [],
    recentSlackEventIDs: [String] = [],
    notifiedEventIDs: [String] = [],
    lastSuccessfulSync: Date? = nil
  ) {
    self.calendarEvents = calendarEvents
    self.recentSlackEventIDs = recentSlackEventIDs
    self.notifiedEventIDs = notifiedEventIDs
    self.lastSuccessfulSync = lastSuccessfulSync
    enforceLimits()
  }

  public mutating func enforceLimits() {
    var eventOrder: [String] = []
    var eventsByID: [String: OutlookEvent] = [:]
    for event in calendarEvents
    where ProviderIdentifierPolicy.isAllowed(event.id) {
      let characterBoundedTitle = String(
        event.title.prefix(DeskLimits.maxMessagePreviewCharacters)
      )
      let boundedEvent = OutlookEvent(
        id: event.id,
        title: TextBounds.utf8Prefix(
          characterBoundedTitle,
          maxBytes: DeskLimits.maxMessagePreviewBytes
        ),
        startAt: event.startAt,
        isCancelled: event.isCancelled,
        isAllDay: event.isAllDay,
        response: event.response
      )
      if eventsByID[event.id] == nil {
        guard eventOrder.count < DeskLimits.maxCalendarEvents else {
          continue
        }
        eventOrder.append(event.id)
      }
      eventsByID[event.id] = boundedEvent
    }
    calendarEvents = eventOrder.compactMap { eventsByID[$0] }
    recentSlackEventIDs =
      BoundedIdentifierSet(
        capacity: DeskLimits.maxRecentSlackEventIDs,
        existing: recentSlackEventIDs.filter {
          ProviderIdentifierPolicy.isAllowed($0)
        }
      ).allValues
    notifiedEventIDs =
      BoundedIdentifierSet(
        capacity: DeskLimits.maxNotifiedEventIDs,
        existing: notifiedEventIDs.filter {
          ProviderIdentifierPolicy.isAllowed(
            $0,
            maxBytes: DeskLimits.maxProviderIdentifierBytes + 32
          )
        }
      ).allValues
  }
}

public struct JSONStateStore: Sendable {
  public let fileURL: URL

  public init(fileURL: URL) {
    self.fileURL = fileURL
  }

  public func load() -> PersistedState {
    guard FileManager.default.fileExists(atPath: fileURL.path) else {
      return PersistedState()
    }
    do {
      return try loadExistingFile()
    } catch {
      backupCorruptFile()
      return PersistedState()
    }
  }

  public func loadExistingFile() throws -> PersistedState {
    let data = try Data(contentsOf: fileURL, options: [.mappedIfSafe])
    guard data.count <= DeskLimits.maxPersistedStateBytes else {
      throw ProviderParseError.payloadTooLarge
    }
    let decoder = JSONDecoder()
    decoder.dateDecodingStrategy = .iso8601
    var state = try decoder.decode(PersistedState.self, from: data)
    state.enforceLimits()
    return state
  }

  public func save(_ state: PersistedState) throws {
    var boundedState = state
    boundedState.enforceLimits()
    let parent = fileURL.deletingLastPathComponent()
    try FileManager.default.createDirectory(
      at: parent,
      withIntermediateDirectories: true
    )
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys]
    encoder.dateEncodingStrategy = .iso8601
    let data = try encoder.encode(boundedState)
    guard data.count <= DeskLimits.maxPersistedStateBytes else {
      throw ProviderParseError.payloadTooLarge
    }
    try data.write(to: fileURL, options: .atomic)
  }

  private func backupCorruptFile() {
    let timestamp = Int(Date().timeIntervalSince1970)
    let backupURL =
      fileURL
      .deletingPathExtension()
      .appendingPathExtension("corrupt-\(timestamp)-\(UUID().uuidString).json")
    try? FileManager.default.moveItem(at: fileURL, to: backupURL)
  }
}
