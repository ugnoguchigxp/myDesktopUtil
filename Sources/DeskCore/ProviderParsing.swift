import Foundation

public enum ProviderParseError: Error, Equatable, LocalizedError, Sendable {
  case payloadTooLarge
  case tooManyChanges(Int)
  case malformedPayload
  case missingEventIdentifier
  case invalidIdentifier
  case invalidEndpoint

  public var errorDescription: String? {
    switch self {
    case .payloadTooLarge:
      "受信データが上限を超えています"
    case .tooManyChanges(let count):
      "1ページの変更件数が上限を超えています: \(count)件"
    case .malformedPayload:
      "受信データを解析できません"
    case .missingEventIdentifier:
      "イベントIDがありません"
    case .invalidIdentifier:
      "イベントIDが長すぎるか不正です"
    case .invalidEndpoint:
      "受信データの接続先が許可されていません"
    }
  }
}

public struct SlackIncomingEnvelope: Equatable, Sendable {
  public let envelopeID: String?
  public let eventID: String?
  public let alert: Alert?

  public init(envelopeID: String?, eventID: String?, alert: Alert?) {
    self.envelopeID = envelopeID
    self.eventID = eventID
    self.alert = alert
  }
}

public enum ProviderIdentifierPolicy {
  public static func isAllowed(
    _ value: String,
    maxBytes: Int = DeskLimits.maxProviderIdentifierBytes
  ) -> Bool {
    !value.isEmpty
      && value.utf8.count <= maxBytes
      && value.unicodeScalars.allSatisfy {
        !CharacterSet.controlCharacters.contains($0)
      }
  }
}

public enum SlackEventClassifier {
  public static func classify(_ data: Data, selfUserID: String) throws -> SlackIncomingEnvelope {
    guard data.count <= DeskLimits.maxIncomingEventBytes else {
      throw ProviderParseError.payloadTooLarge
    }
    let envelope: SocketEnvelope
    do {
      envelope = try JSONDecoder().decode(SocketEnvelope.self, from: data)
    } catch {
      throw ProviderParseError.malformedPayload
    }
    if let envelopeID = envelope.envelopeID,
      !ProviderIdentifierPolicy.isAllowed(envelopeID)
    {
      throw ProviderParseError.invalidIdentifier
    }

    guard envelope.type == "events_api", let payload = envelope.payload else {
      return SlackIncomingEnvelope(
        envelopeID: envelope.envelopeID,
        eventID: nil,
        alert: nil
      )
    }

    guard let eventID = payload.eventID, !eventID.isEmpty else {
      throw ProviderParseError.missingEventIdentifier
    }
    guard ProviderIdentifierPolicy.isAllowed(eventID) else {
      throw ProviderParseError.invalidIdentifier
    }
    let event = payload.event
    guard event.type == "message",
      event.user != selfUserID,
      event.botID == nil,
      event.subtype == nil,
      event.hidden != true
    else {
      return SlackIncomingEnvelope(
        envelopeID: envelope.envelopeID,
        eventID: eventID,
        alert: nil
      )
    }

    let channelType = event.channelType ?? inferredChannelType(event.channel)
    let isDirectMessage = channelType == "im"
    let isGroupDirectMessage = channelType == "mpim"
    let isMention =
      (channelType == "channel" || channelType == "group")
      && containsMention(event.text ?? "", userID: selfUserID)

    guard isDirectMessage || isGroupDirectMessage || isMention else {
      return SlackIncomingEnvelope(
        envelopeID: envelope.envelopeID,
        eventID: eventID,
        alert: nil
      )
    }

    let title: String
    if isDirectMessage {
      title = "Slack DM"
    } else if isGroupDirectMessage {
      title = "Slack グループDM"
    } else {
      title = "Slack メンション"
    }
    let sender =
      event.user.flatMap {
        ProviderIdentifierPolicy.isAllowed(
          $0,
          maxBytes: DeskLimits.maxProviderUserIDBytes
        ) ? $0 : nil
      }.map {
        "送信者: \(TextBounds.utf8Prefix($0, maxBytes: DeskLimits.maxProviderUserIDBytes))"
      } ?? "Slack"
    let characterBoundedText = String(
      (event.text ?? "").prefix(DeskLimits.maxMessagePreviewCharacters)
    )
    let preview = TextBounds.utf8Prefix(
      characterBoundedText,
      maxBytes: DeskLimits.maxMessagePreviewBytes
    )
    let body = preview.isEmpty ? sender : "\(sender)\n\(preview)"
    return SlackIncomingEnvelope(
      envelopeID: envelope.envelopeID,
      eventID: eventID,
      alert: Alert(id: eventID, source: .slack, title: title, body: body)
    )
  }

  private static func containsMention(_ text: String, userID: String) -> Bool {
    text.contains("<@\(userID)>") || text.contains("<@\(userID)|")
  }

  private static func inferredChannelType(_ channel: String?) -> String? {
    guard let channel else {
      return nil
    }
    if channel.hasPrefix("D") {
      return "im"
    }
    if channel.hasPrefix("C") {
      return "channel"
    }
    return nil
  }

  private struct SocketEnvelope: Decodable {
    let envelopeID: String?
    let type: String
    let payload: EventsPayload?

    enum CodingKeys: String, CodingKey {
      case envelopeID = "envelope_id"
      case type
      case payload
    }
  }

  private struct EventsPayload: Decodable {
    let eventID: String?
    let event: MessageEvent

    enum CodingKeys: String, CodingKey {
      case eventID = "event_id"
      case event
    }
  }

  private struct MessageEvent: Decodable {
    let type: String
    let channel: String?
    let channelType: String?
    let user: String?
    let text: String?
    let subtype: String?
    let hidden: Bool?
    let botID: String?

    enum CodingKeys: String, CodingKey {
      case type
      case channel
      case channelType = "channel_type"
      case user
      case text
      case subtype
      case hidden
      case botID = "bot_id"
    }
  }
}

public struct GraphDeltaPage: Equatable, Sendable {
  public let events: [OutlookEvent]
  public let removedEventIDs: [String]
  public let nextLink: URL?
  public let deltaLink: URL?

  public init(
    events: [OutlookEvent],
    removedEventIDs: [String],
    nextLink: URL?,
    deltaLink: URL?
  ) {
    self.events = events
    self.removedEventIDs = removedEventIDs
    self.nextLink = nextLink
    self.deltaLink = deltaLink
  }
}

public enum GraphEndpointPolicy {
  public static func isAllowed(_ url: URL) -> Bool {
    url.absoluteString.utf8.count <= DeskLimits.maxProviderURLBytes
      && url.scheme?.lowercased() == "https"
      && url.host?.lowercased() == "graph.microsoft.com"
      && url.port == nil
      && url.user == nil
      && url.password == nil
  }
}

public enum MicrosoftLoginEndpointPolicy {
  public static func isAllowed(_ url: URL) -> Bool {
    url.absoluteString.utf8.count <= DeskLimits.maxProviderURLBytes
      && url.scheme?.lowercased() == "https"
      && url.host?.lowercased() == "login.microsoftonline.com"
      && url.port == nil
      && url.user == nil
      && url.password == nil
  }
}

public enum MicrosoftOAuthCallbackPolicy {
  public static func authorizationCode(
    from url: URL,
    expectedScheme: String,
    expectedState: String
  ) -> String? {
    guard
      url.absoluteString.utf8.count <= DeskLimits.maxProviderURLBytes,
      url.scheme?.lowercased() == expectedScheme.lowercased(),
      url.host?.lowercased() == "oauth",
      url.path == "/callback",
      url.port == nil,
      url.user == nil,
      url.password == nil,
      url.fragment == nil,
      let queryItems = URLComponents(
        url: url,
        resolvingAgainstBaseURL: false
      )?.queryItems
    else {
      return nil
    }

    let stateItems = queryItems.filter { $0.name == "state" }
    let codeItems = queryItems.filter { $0.name == "code" }
    guard stateItems.count == 1,
      stateItems[0].value == expectedState,
      codeItems.count == 1,
      let code = codeItems[0].value,
      ProviderIdentifierPolicy.isAllowed(
        code,
        maxBytes: DeskLimits.maxOAuthAuthorizationCodeBytes
      )
    else {
      return nil
    }
    return code
  }
}

public enum GraphSyncWindowPolicy {
  public static func isReusable(
    now: Date,
    windowStart: Date?,
    windowEnd: Date?
  ) -> Bool {
    guard let windowStart, let windowEnd, windowEnd > now else {
      return false
    }
    let inferredCreationDate = windowStart.addingTimeInterval(60 * 60)
    let age = now.timeIntervalSince(inferredCreationDate)
    return age >= 0 && age < 12 * 60 * 60
  }
}

public enum SlackEndpointPolicy {
  public static func isAllowedAPIURL(_ url: URL) -> Bool {
    isAllowed(
      url,
      scheme: "https",
      hostMatches: { $0 == "slack.com" }
    )
  }

  public static func isAllowedSocketURL(_ url: URL) -> Bool {
    isAllowed(
      url,
      scheme: "wss",
      hostMatches: { $0 == "slack.com" || $0.hasSuffix(".slack.com") }
    )
  }

  private static func isAllowed(
    _ url: URL,
    scheme: String,
    hostMatches: (String) -> Bool
  ) -> Bool {
    guard url.absoluteString.utf8.count <= DeskLimits.maxProviderURLBytes,
      url.scheme?.lowercased() == scheme,
      let host = url.host?.lowercased(),
      url.port == nil,
      url.user == nil,
      url.password == nil
    else {
      return false
    }
    return hostMatches(host)
  }
}

public enum GraphDeltaDecoder {
  public static func decode(_ data: Data) throws -> GraphDeltaPage {
    guard data.count <= 4 * 1_024 * 1_024 else {
      throw ProviderParseError.payloadTooLarge
    }
    let response: GraphResponse
    do {
      response = try JSONDecoder().decode(GraphResponse.self, from: data)
    } catch {
      throw ProviderParseError.malformedPayload
    }
    guard response.value.count <= DeskLimits.maxCalendarEvents else {
      throw ProviderParseError.tooManyChanges(response.value.count)
    }
    guard
      response.value.allSatisfy({
        ProviderIdentifierPolicy.isAllowed($0.id)
      })
    else {
      throw ProviderParseError.invalidIdentifier
    }
    let events = response.value.filter { $0.removed == nil }.map { event in
      OutlookEvent(
        id: event.id,
        title: TextBounds.utf8Prefix(
          String(event.subject.prefix(256)),
          maxBytes: DeskLimits.maxMessagePreviewBytes
        ),
        startAt: parseDate(event.start?.dateTime, timeZone: event.start?.timeZone),
        isCancelled: event.isCancelled,
        isAllDay: event.isAllDay,
        response: OutlookResponse(
          graphValue: event.responseStatus?.response.map { String($0.prefix(64)) }
        )
      )
    }
    let nextLink = try decodeGraphURL(response.nextLink)
    let deltaLink = try decodeGraphURL(response.deltaLink)
    return GraphDeltaPage(
      events: Array(events),
      removedEventIDs: response.value.filter { $0.removed != nil }.map(\.id),
      nextLink: nextLink,
      deltaLink: deltaLink
    )
  }

  private static func decodeGraphURL(_ source: String?) throws -> URL? {
    guard let source else {
      return nil
    }
    guard let url = URL(string: source), GraphEndpointPolicy.isAllowed(url) else {
      throw ProviderParseError.invalidEndpoint
    }
    return url
  }

  private static func parseDate(_ source: String?, timeZone: String?) -> Date? {
    guard var source, !source.isEmpty, source.utf8.count <= 128,
      timeZone?.utf8.count ?? 0 <= 128
    else {
      return nil
    }
    let timeComponent = source.split(separator: "T", maxSplits: 1).dropFirst().first ?? ""
    let hasExplicitZone =
      source.hasSuffix("Z")
      || timeComponent.contains("+")
      || timeComponent.dropFirst().contains("-")
    if !hasExplicitZone, timeZone?.uppercased() == "UTC" {
      source.append("Z")
    }

    if let date = try? iso8601WithFractionalSeconds.parse(source) {
      return date
    }
    return try? iso8601WithoutFractionalSeconds.parse(source)
  }

  private static let iso8601WithFractionalSeconds = Date.ISO8601FormatStyle(
    includingFractionalSeconds: true
  )
  private static let iso8601WithoutFractionalSeconds = Date.ISO8601FormatStyle()

  private struct GraphResponse: Decodable {
    let value: [GraphEvent]
    let nextLink: String?
    let deltaLink: String?

    enum CodingKeys: String, CodingKey {
      case value
      case nextLink = "@odata.nextLink"
      case deltaLink = "@odata.deltaLink"
    }
  }

  private struct GraphEvent: Decodable {
    let id: String
    let subject: String
    let isCancelled: Bool
    let isAllDay: Bool
    let start: GraphDateTime?
    let responseStatus: GraphResponseStatus?
    let removed: GraphRemoved?

    private enum CodingKeys: String, CodingKey {
      case id
      case subject
      case isCancelled
      case isAllDay
      case start
      case responseStatus
      case removed = "@removed"
    }

    init(from decoder: Decoder) throws {
      let container = try decoder.container(keyedBy: CodingKeys.self)
      id = try container.decode(String.self, forKey: .id)
      subject = try container.decodeIfPresent(String.self, forKey: .subject) ?? ""
      isCancelled = try container.decodeIfPresent(Bool.self, forKey: .isCancelled) ?? false
      isAllDay = try container.decodeIfPresent(Bool.self, forKey: .isAllDay) ?? false
      start = try container.decodeIfPresent(GraphDateTime.self, forKey: .start)
      responseStatus = try container.decodeIfPresent(
        GraphResponseStatus.self,
        forKey: .responseStatus
      )
      removed = try container.decodeIfPresent(GraphRemoved.self, forKey: .removed)
    }
  }

  private struct GraphDateTime: Decodable {
    let dateTime: String
    let timeZone: String?
  }

  private struct GraphResponseStatus: Decodable {
    let response: String?
  }

  private struct GraphRemoved: Decodable {}
}
