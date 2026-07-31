import XCTest

@testable import DeskCore

final class ProviderParsingTests: XCTestCase {
  func testSlackDirectMessage() throws {
    let envelope = try SlackEventClassifier.classify(
      fixture(eventID: "dm", channelType: "im", text: "hello"),
      selfUserID: "U_SELF"
    )
    XCTAssertEqual(envelope.alert?.title, "Slack DM")
  }

  func testSlackGroupDirectMessage() throws {
    let envelope = try SlackEventClassifier.classify(
      fixture(eventID: "mpim", channelType: "mpim", text: "hello"),
      selfUserID: "U_SELF"
    )
    XCTAssertEqual(envelope.alert?.title, "Slack グループDM")
  }

  func testSlackMention() throws {
    let envelope = try SlackEventClassifier.classify(
      fixture(eventID: "mention", channelType: "channel", text: "<@U_SELF> hello"),
      selfUserID: "U_SELF"
    )
    XCTAssertEqual(envelope.alert?.title, "Slack メンション")
  }

  func testNormalChannelMessageIsExcluded() throws {
    let envelope = try SlackEventClassifier.classify(
      fixture(eventID: "normal", channelType: "channel", text: "hello"),
      selfUserID: "U_SELF"
    )
    XCTAssertNil(envelope.alert)
  }

  func testOwnMessageIsExcluded() throws {
    let envelope = try SlackEventClassifier.classify(
      fixture(
        eventID: "own",
        channelType: "im",
        userID: "U_SELF",
        text: "hello"
      ),
      selfUserID: "U_SELF"
    )
    XCTAssertNil(envelope.alert)
  }

  func testSlackEventIdentifierHasByteLimit() {
    let oversizedID = String(
      repeating: "x",
      count: DeskLimits.maxProviderIdentifierBytes + 1
    )
    XCTAssertThrowsError(
      try SlackEventClassifier.classify(
        fixture(eventID: oversizedID, channelType: "im", text: "hello"),
        selfUserID: "U_SELF"
      )
    ) { error in
      XCTAssertEqual(error as? ProviderParseError, .invalidIdentifier)
    }
  }

  func testSlackEventIdentifierRejectsControlCharacters() {
    XCTAssertThrowsError(
      try SlackEventClassifier.classify(
        fixture(eventID: "event\nid", channelType: "im", text: "hello"),
        selfUserID: "U_SELF"
      )
    ) { error in
      XCTAssertEqual(error as? ProviderParseError, .invalidIdentifier)
    }
  }

  func testSlackEnvelopeIdentifierRejectsControlCharacters() {
    XCTAssertThrowsError(
      try SlackEventClassifier.classify(
        fixture(
          eventID: "event-id",
          envelopeID: "envelope\nid",
          channelType: "im",
          text: "hello"
        ),
        selfUserID: "U_SELF"
      )
    ) { error in
      XCTAssertEqual(error as? ProviderParseError, .invalidIdentifier)
    }
  }

  func testSlackSenderIdentifierCannotInjectControlCharacters() throws {
    let envelope = try SlackEventClassifier.classify(
      fixture(
        eventID: "event-id",
        channelType: "im",
        userID: "U_OTHER\n偽装",
        text: "hello"
      ),
      selfUserID: "U_SELF"
    )

    XCTAssertEqual(envelope.alert?.body, "Slack\nhello")
  }

  func testSlackPreviewHasByteLimitForCombiningText() throws {
    let combiningText = "a" + String(repeating: "\u{0301}", count: 2_000)
    let envelope = try SlackEventClassifier.classify(
      fixture(eventID: "bounded", channelType: "im", text: combiningText),
      selfUserID: "U_SELF"
    )

    XCTAssertLessThan(
      envelope.alert?.body.utf8.count ?? .max,
      DeskLimits.maxMessagePreviewBytes + DeskLimits.maxProviderUserIDBytes + 32
    )
  }

  func testSlackEndpointPolicyAllowsOnlyOfficialSecureHosts() {
    XCTAssertTrue(
      SlackEndpointPolicy.isAllowedAPIURL(
        URL(string: "https://slack.com/api/auth.test")!
      )
    )
    XCTAssertTrue(
      SlackEndpointPolicy.isAllowedSocketURL(
        URL(string: "wss://wss-primary.slack.com/link")!
      )
    )
    XCTAssertFalse(
      SlackEndpointPolicy.isAllowedSocketURL(
        URL(string: "wss://slack.com.evil.example/link")!
      )
    )
    XCTAssertFalse(
      SlackEndpointPolicy.isAllowedSocketURL(
        URL(string: "ws://wss-primary.slack.com/link")!
      )
    )
  }

  private func fixture(
    eventID: String,
    envelopeID: String? = nil,
    channelType: String,
    userID: String = "U_OTHER",
    text: String
  ) throws -> Data {
    try JSONSerialization.data(
      withJSONObject: [
        "envelope_id": envelopeID ?? "envelope-\(eventID)",
        "type": "events_api",
        "payload": [
          "event_id": eventID,
          "event": [
            "type": "message",
            "channel": "C123",
            "channel_type": channelType,
            "user": userID,
            "text": text,
          ],
        ],
      ]
    )
  }
}
