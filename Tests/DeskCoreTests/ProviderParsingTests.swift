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

  func testGraphDeltaDecoding() throws {
    let data = Data(
      """
      {
        "@odata.deltaLink": "https://graph.microsoft.com/delta-token",
        "value": [
          {
            "id": "event-1",
            "subject": "Weekly Meeting",
            "isCancelled": false,
            "isAllDay": false,
            "start": {
              "dateTime": "2033-05-18T03:33:20.000Z",
              "timeZone": "UTC"
            },
            "responseStatus": { "response": "accepted" }
          },
          {
            "id": "deleted-event",
            "@removed": { "reason": "deleted" }
          }
        ]
      }
      """.utf8
    )
    let page = try GraphDeltaDecoder.decode(data)
    XCTAssertEqual(page.events.count, 1)
    XCTAssertEqual(page.events[0].title, "Weekly Meeting")
    XCTAssertEqual(page.events[0].response, .accepted)
    XCTAssertNotNil(page.events[0].startAt)
    XCTAssertNotNil(page.deltaLink)
    XCTAssertEqual(page.removedEventIDs, ["deleted-event"])
  }

  func testGraphUTCDateWithoutZoneSuffix() throws {
    let data = Data(
      """
      {
        "value": [{
          "id": "event-utc",
          "subject": "UTC event",
          "isCancelled": false,
          "isAllDay": false,
          "start": {
            "dateTime": "2033-05-18T03:33:20.000",
            "timeZone": "UTC"
          }
        }]
      }
      """.utf8
    )
    let page = try GraphDeltaDecoder.decode(data)
    XCTAssertNotNil(page.events.first?.startAt)
  }

  func testGraphEndpointPolicyRejectsTokenExfiltrationURLs() {
    XCTAssertTrue(
      GraphEndpointPolicy.isAllowed(
        URL(string: "https://graph.microsoft.com/v1.0/me/calendarView/delta")!
      )
    )
    XCTAssertFalse(
      GraphEndpointPolicy.isAllowed(
        URL(string: "https://evil.example/steal")!
      )
    )
    XCTAssertFalse(
      GraphEndpointPolicy.isAllowed(
        URL(string: "https://graph.microsoft.com@evil.example/steal")!
      )
    )
    XCTAssertFalse(
      GraphEndpointPolicy.isAllowed(
        URL(string: "http://graph.microsoft.com/v1.0/me")!
      )
    )
  }

  func testMicrosoftLoginEndpointPolicyAllowsOnlyOfficialSecureHost() {
    XCTAssertTrue(
      MicrosoftLoginEndpointPolicy.isAllowed(
        URL(string: "https://login.microsoftonline.com/common/oauth2/v2.0/token")!
      )
    )
    XCTAssertFalse(
      MicrosoftLoginEndpointPolicy.isAllowed(
        URL(string: "http://login.microsoftonline.com/common")!
      )
    )
    XCTAssertFalse(
      MicrosoftLoginEndpointPolicy.isAllowed(
        URL(string: "https://login.microsoftonline.com.evil.example/common")!
      )
    )
    XCTAssertFalse(
      MicrosoftLoginEndpointPolicy.isAllowed(
        URL(string: "https://login.microsoftonline.com:444/common")!
      )
    )
  }

  func testMicrosoftOAuthCallbackRequiresExactRouteAndSingleParameters() {
    let scheme = "com.local.deskagent"
    let state = "expected-state"
    XCTAssertEqual(
      MicrosoftOAuthCallbackPolicy.authorizationCode(
        from: URL(
          string: "\(scheme)://oauth/callback?code=valid-code&state=\(state)"
        )!,
        expectedScheme: scheme,
        expectedState: state
      ),
      "valid-code"
    )

    let rejectedURLs = [
      "\(scheme)://other/callback?code=valid-code&state=\(state)",
      "\(scheme)://oauth/other?code=valid-code&state=\(state)",
      "\(scheme)://oauth/callback?code=valid-code&state=wrong-state",
      "\(scheme)://oauth/callback?code=first&code=second&state=\(state)",
      "\(scheme)://oauth/callback?code=valid-code&state=\(state)&state=duplicate",
      "\(scheme)://oauth/callback?code=valid-code&state=\(state)#fragment",
    ]
    for source in rejectedURLs {
      XCTAssertNil(
        MicrosoftOAuthCallbackPolicy.authorizationCode(
          from: URL(string: source)!,
          expectedScheme: scheme,
          expectedState: state
        ),
        source
      )
    }

    let oversizedCode = String(
      repeating: "a",
      count: DeskLimits.maxOAuthAuthorizationCodeBytes + 1
    )
    XCTAssertNil(
      MicrosoftOAuthCallbackPolicy.authorizationCode(
        from: URL(
          string: "\(scheme)://oauth/callback?code=\(oversizedCode)&state=\(state)"
        )!,
        expectedScheme: scheme,
        expectedState: state
      )
    )
  }

  func testGraphWindowIsRenewedTwelveHoursAfterCreation() {
    let createdAt = Date(timeIntervalSince1970: 2_000_000_000)
    let windowStart = createdAt.addingTimeInterval(-60 * 60)
    let windowEnd = createdAt.addingTimeInterval(14 * 24 * 60 * 60)

    XCTAssertTrue(
      GraphSyncWindowPolicy.isReusable(
        now: createdAt.addingTimeInterval(12 * 60 * 60 - 1),
        windowStart: windowStart,
        windowEnd: windowEnd
      )
    )
    XCTAssertFalse(
      GraphSyncWindowPolicy.isReusable(
        now: createdAt.addingTimeInterval(12 * 60 * 60),
        windowStart: windowStart,
        windowEnd: windowEnd
      )
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

  func testGraphPageOverEventLimitIsRejected() throws {
    let values = (0...DeskLimits.maxCalendarEvents).map { index in
      [
        "id": "event-\(index)",
        "subject": "Meeting",
        "isCancelled": false,
        "isAllDay": false,
      ] as [String: Any]
    }
    let data = try JSONSerialization.data(withJSONObject: ["value": values])

    XCTAssertThrowsError(try GraphDeltaDecoder.decode(data)) { error in
      XCTAssertEqual(
        error as? ProviderParseError,
        .tooManyChanges(DeskLimits.maxCalendarEvents + 1)
      )
    }
  }

  func testGraphPageRejectsUntrustedNextLink() {
    let data = Data(
      """
      {
        "@odata.nextLink": "https://evil.example/steal-token",
        "value": []
      }
      """.utf8
    )

    XCTAssertThrowsError(try GraphDeltaDecoder.decode(data)) { error in
      XCTAssertEqual(error as? ProviderParseError, .invalidEndpoint)
    }
  }

  func testGraphEventIdentifierHasByteLimit() throws {
    let oversizedID = String(
      repeating: "x",
      count: DeskLimits.maxProviderIdentifierBytes + 1
    )
    let data = try JSONSerialization.data(
      withJSONObject: [
        "value": [
          [
            "id": oversizedID,
            "subject": "Meeting",
            "isCancelled": false,
            "isAllDay": false,
          ]
        ]
      ]
    )

    XCTAssertThrowsError(try GraphDeltaDecoder.decode(data)) { error in
      XCTAssertEqual(error as? ProviderParseError, .invalidIdentifier)
    }
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
