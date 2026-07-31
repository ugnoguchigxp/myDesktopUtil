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
