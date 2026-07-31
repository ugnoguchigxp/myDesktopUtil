import DeskCore
import Foundation

enum SlackIntegrationError: LocalizedError {
  case missingAppToken
  case missingSelfUserID
  case invalidAPIResponse
  case httpStatus(Int)
  case reconnectRequested

  var errorDescription: String? {
    switch self {
    case .missingAppToken:
      "Slack app tokenがKeychainにありません"
    case .missingSelfUserID:
      "Slack User IDを取得できません"
    case .invalidAPIResponse:
      "Slack APIの応答を解析できません"
    case .httpStatus(let status):
      "Slack APIがHTTP \(status)を返しました"
    case .reconnectRequested:
      "Slackから再接続を要求されました"
    }
  }
}

actor SlackSocketClient {
  typealias AlertHandler = @Sendable (Alert) -> Void
  typealias StatusHandler = @Sendable (String) -> Void
  typealias RecentIDsHandler = @Sendable ([String]) -> Void

  private let appToken: String
  private let userToken: String?
  private let configuredSelfUserID: String
  private let onAlert: AlertHandler
  private let onStatus: StatusHandler
  private let onRecentIDs: RecentIDsHandler
  private var recentIDs: BoundedIdentifierSet
  private var socket: URLSessionWebSocketTask?
  private var runTask: Task<Void, Never>?
  private var resolvedSelfUserID: String?
  private var stopped = true

  init(
    appToken: String,
    userToken: String?,
    selfUserID: String,
    existingRecentIDs: [String],
    onAlert: @escaping AlertHandler,
    onStatus: @escaping StatusHandler,
    onRecentIDs: @escaping RecentIDsHandler
  ) {
    self.appToken = appToken
    self.userToken = userToken
    configuredSelfUserID = selfUserID
    recentIDs = BoundedIdentifierSet(
      capacity: DeskLimits.maxRecentSlackEventIDs,
      existing: existingRecentIDs
    )
    self.onAlert = onAlert
    self.onStatus = onStatus
    self.onRecentIDs = onRecentIDs
  }

  func start() {
    guard runTask == nil else {
      return
    }
    stopped = false
    runTask = Task { [weak self] in
      await self?.runLoop()
    }
  }

  func stop() {
    stopped = true
    socket?.cancel(with: .goingAway, reason: nil)
    socket = nil
    runTask?.cancel()
    runTask = nil
    onStatus("Slack: 停止")
  }

  private func runLoop() async {
    var failureCount = 0
    while !stopped, !Task.isCancelled {
      do {
        onStatus("Slack: 接続中")
        let selfUserID = try await resolveSelfUserID()
        let socketURL = try await openSocketURL()
        try await receiveEvents(from: socketURL, selfUserID: selfUserID)
        failureCount = 0
      } catch is CancellationError {
        break
      } catch {
        guard !stopped, !Task.isCancelled else {
          break
        }
        failureCount = min(failureCount + 1, 6)
        onStatus("Slack: 再接続待ち")
        let baseSeconds = min(60.0, pow(2.0, Double(failureCount - 1)))
        let jitter = Double.random(in: 0...min(1.0, baseSeconds * 0.25))
        let nanoseconds = UInt64((baseSeconds + jitter) * 1_000_000_000)
        try? await Task.sleep(nanoseconds: nanoseconds)
      }
    }
    runTask = nil
  }

  private func receiveEvents(from url: URL, selfUserID: String) async throws {
    let configuration = URLSessionConfiguration.ephemeral
    configuration.urlCache = nil
    configuration.httpCookieStorage = nil
    let redirectDelegate = RestrictedRedirectDelegate(
      isAllowed: SlackEndpointPolicy.isAllowedSocketURL
    )
    let session = URLSession(
      configuration: configuration,
      delegate: redirectDelegate,
      delegateQueue: nil
    )
    defer { session.finishTasksAndInvalidate() }

    let socket = session.webSocketTask(with: url)
    socket.maximumMessageSize = DeskLimits.maxIncomingEventBytes
    self.socket = socket
    socket.resume()
    onStatus("Slack: 接続済み")

    defer {
      socket.cancel(with: .goingAway, reason: nil)
      self.socket = nil
    }

    while !stopped, !Task.isCancelled {
      let message = try await socket.receive()
      let data: Data
      switch message {
      case .data(let value):
        data = value
      case .string(let value):
        data = Data(value.utf8)
      @unknown default:
        continue
      }
      guard data.count <= DeskLimits.maxIncomingEventBytes else {
        continue
      }

      let header: EnvelopeHeader
      do {
        header = try JSONDecoder().decode(EnvelopeHeader.self, from: data)
      } catch {
        throw SlackIntegrationError.invalidAPIResponse
      }
      if let envelopeID = header.envelopeID {
        guard ProviderIdentifierPolicy.isAllowed(envelopeID) else {
          throw ProviderParseError.invalidIdentifier
        }
        try await acknowledge(envelopeID: envelopeID, on: socket)
      }
      if header.type == "disconnect" {
        throw SlackIntegrationError.reconnectRequested
      }

      guard
        let incoming = try? SlackEventClassifier.classify(
          data,
          selfUserID: selfUserID
        ),
        let eventID = incoming.eventID,
        let alert = incoming.alert
      else {
        continue
      }
      guard recentIDs.insert(eventID) else {
        continue
      }
      onRecentIDs(recentIDs.allValues)
      onAlert(alert)
    }
  }

  private func acknowledge(
    envelopeID: String,
    on socket: URLSessionWebSocketTask
  ) async throws {
    let data = try JSONSerialization.data(
      withJSONObject: ["envelope_id": envelopeID],
      options: []
    )
    guard let text = String(data: data, encoding: .utf8) else {
      return
    }
    try await socket.send(.string(text))
  }

  private func openSocketURL() async throws -> URL {
    guard !appToken.isEmpty else {
      throw SlackIntegrationError.missingAppToken
    }
    guard let endpoint = URL(string: "https://slack.com/api/apps.connections.open") else {
      throw SlackIntegrationError.invalidAPIResponse
    }
    var request = URLRequest(url: endpoint)
    request.httpMethod = "POST"
    request.setValue("Bearer \(appToken)", forHTTPHeaderField: "Authorization")
    request.setValue(
      "application/x-www-form-urlencoded",
      forHTTPHeaderField: "Content-Type"
    )
    let (data, response) = try await ephemeralData(for: request)
    guard let http = response as? HTTPURLResponse,
      (200..<300).contains(http.statusCode)
    else {
      throw SlackIntegrationError.httpStatus(
        (response as? HTTPURLResponse)?.statusCode ?? 0
      )
    }
    let result = try JSONDecoder().decode(SocketOpenResponse.self, from: data)
    guard result.ok,
      let urlText = result.url,
      urlText.utf8.count <= DeskLimits.maxProviderURLBytes,
      let url = URL(string: urlText),
      SlackEndpointPolicy.isAllowedSocketURL(url)
    else {
      throw SlackIntegrationError.invalidAPIResponse
    }
    return url
  }

  private func resolveSelfUserID() async throws -> String {
    if let resolvedSelfUserID {
      return resolvedSelfUserID
    }
    let configuredID = configuredSelfUserID.trimmingCharacters(in: .whitespacesAndNewlines)
    if !configuredID.isEmpty {
      guard
        ProviderIdentifierPolicy.isAllowed(
          configuredID,
          maxBytes: DeskLimits.maxProviderUserIDBytes
        )
      else {
        throw SlackIntegrationError.missingSelfUserID
      }
      resolvedSelfUserID = configuredID
      return configuredID
    }
    guard let userToken, !userToken.isEmpty else {
      throw SlackIntegrationError.missingSelfUserID
    }
    guard let endpoint = URL(string: "https://slack.com/api/auth.test") else {
      throw SlackIntegrationError.invalidAPIResponse
    }
    var request = URLRequest(url: endpoint)
    request.httpMethod = "POST"
    request.setValue("Bearer \(userToken)", forHTTPHeaderField: "Authorization")
    let (data, response) = try await ephemeralData(for: request)
    guard let http = response as? HTTPURLResponse,
      (200..<300).contains(http.statusCode)
    else {
      throw SlackIntegrationError.httpStatus(
        (response as? HTTPURLResponse)?.statusCode ?? 0
      )
    }
    let result = try JSONDecoder().decode(AuthTestResponse.self, from: data)
    guard result.ok,
      let userID = result.userID,
      ProviderIdentifierPolicy.isAllowed(
        userID,
        maxBytes: DeskLimits.maxProviderUserIDBytes
      )
    else {
      throw SlackIntegrationError.missingSelfUserID
    }
    resolvedSelfUserID = userID
    return userID
  }

  private func ephemeralData(for request: URLRequest) async throws -> (Data, URLResponse) {
    let configuration = URLSessionConfiguration.ephemeral
    configuration.urlCache = nil
    configuration.httpCookieStorage = nil
    configuration.timeoutIntervalForRequest = 30
    configuration.timeoutIntervalForResource = 60
    let redirectDelegate = RestrictedRedirectDelegate(
      isAllowed: SlackEndpointPolicy.isAllowedAPIURL
    )
    let session = URLSession(
      configuration: configuration,
      delegate: redirectDelegate,
      delegateQueue: nil
    )
    defer { session.finishTasksAndInvalidate() }
    let result = try await session.data(for: request)
    guard result.0.count <= DeskLimits.maxIncomingEventBytes else {
      throw ProviderParseError.payloadTooLarge
    }
    return result
  }

  private struct EnvelopeHeader: Decodable {
    let envelopeID: String?
    let type: String

    enum CodingKeys: String, CodingKey {
      case envelopeID = "envelope_id"
      case type
    }
  }

  private struct SocketOpenResponse: Decodable {
    let ok: Bool
    let url: String?
  }

  private struct AuthTestResponse: Decodable {
    let ok: Bool
    let userID: String?

    enum CodingKeys: String, CodingKey {
      case ok
      case userID = "user_id"
    }
  }
}
