import AppKit
import AuthenticationServices
import CryptoKit
import DeskCore
import Foundation
import Security

enum GraphIntegrationError: LocalizedError {
  case notConfigured
  case signInFailed
  case signInInProgress
  case invalidCallback
  case invalidTokenResponse
  case invalidEndpoint
  case httpStatus(Int)
  case deltaExpired
  case tooManyPages
  case tooManyChanges

  var errorDescription: String? {
    switch self {
    case .notConfigured:
      "Microsoft Client IDが未設定です"
    case .signInFailed:
      "Microsoftサインインを開始できません"
    case .signInInProgress:
      "Microsoftサインインはすでに進行中です"
    case .invalidCallback:
      "Microsoftサインインの応答が不正です"
    case .invalidTokenResponse:
      "Microsoft token応答を解析できません"
    case .invalidEndpoint:
      "Microsoft Graphの接続先が許可されていません"
    case .httpStatus(let status):
      "Microsoft GraphがHTTP \(status)を返しました"
    case .deltaExpired:
      "Microsoft Graphの差分同期状態が失効しました"
    case .tooManyPages:
      "Microsoft Graphのページ数が上限を超えました"
    case .tooManyChanges:
      "Microsoft Graphの変更件数が上限を超えました"
    }
  }
}

@MainActor
final class GraphAuthService: NSObject, ASWebAuthenticationPresentationContextProviding {
  private let configuration: ConnectionConfiguration.Microsoft
  private let keychain: KeychainStore
  private var authenticationSession: ASWebAuthenticationSession?
  private let anchor = NSWindow(
    contentRect: NSRect(x: 0, y: 0, width: 1, height: 1),
    styleMask: .borderless,
    backing: .buffered,
    defer: false
  )

  init(
    configuration: ConnectionConfiguration.Microsoft,
    keychain: KeychainStore = KeychainStore()
  ) {
    self.configuration = configuration
    self.keychain = keychain
  }

  func presentationAnchor(for session: ASWebAuthenticationSession) -> ASPresentationAnchor {
    NSApp.keyWindow ?? anchor
  }

  func validAccessToken() async throws -> String {
    if let accessToken = try keychain.read(.graphAccessToken),
      let expiryText = try keychain.read(.graphTokenExpiry),
      let expiry = TimeInterval(expiryText),
      expiry.isFinite,
      expiry > Date().addingTimeInterval(90).timeIntervalSince1970
    {
      return accessToken
    }
    if let refreshToken = try keychain.read(.graphRefreshToken) {
      return try await refresh(refreshToken: refreshToken)
    }
    throw GraphIntegrationError.signInFailed
  }

  func signIn() async throws -> String {
    guard !configuration.clientID.isEmpty else {
      throw GraphIntegrationError.notConfigured
    }
    guard authenticationSession == nil else {
      throw GraphIntegrationError.signInInProgress
    }
    let verifier = try Self.randomURLSafeString(byteCount: 48)
    let challenge = Data(SHA256.hash(data: Data(verifier.utf8))).base64URLEncodedString()
    let state = try Self.randomURLSafeString(byteCount: 24)
    let redirectURI = "\(AppIdentity.bundleIdentifier)://oauth/callback"

    var components = URLComponents()
    components.scheme = "https"
    components.host = "login.microsoftonline.com"
    components.path = "/\(configuration.tenantID)/oauth2/v2.0/authorize"
    components.queryItems = [
      URLQueryItem(name: "client_id", value: configuration.clientID),
      URLQueryItem(name: "response_type", value: "code"),
      URLQueryItem(name: "redirect_uri", value: redirectURI),
      URLQueryItem(name: "response_mode", value: "query"),
      URLQueryItem(name: "scope", value: "offline_access Calendars.Read User.Read"),
      URLQueryItem(name: "code_challenge", value: challenge),
      URLQueryItem(name: "code_challenge_method", value: "S256"),
      URLQueryItem(name: "state", value: state),
    ]
    guard let authorizationURL = components.url,
      MicrosoftLoginEndpointPolicy.isAllowed(authorizationURL)
    else {
      throw GraphIntegrationError.signInFailed
    }

    let callbackURL = try await withCheckedThrowingContinuation {
      (continuation: CheckedContinuation<URL, Error>) in
      let session = ASWebAuthenticationSession(
        url: authorizationURL,
        callbackURLScheme: AppIdentity.bundleIdentifier
      ) { [weak self] url, error in
        self?.authenticationSession = nil
        if let error {
          continuation.resume(throwing: error)
        } else if let url {
          continuation.resume(returning: url)
        } else {
          continuation.resume(throwing: GraphIntegrationError.invalidCallback)
        }
      }
      session.presentationContextProvider = self
      session.prefersEphemeralWebBrowserSession = false
      authenticationSession = session
      guard session.start() else {
        authenticationSession = nil
        continuation.resume(throwing: GraphIntegrationError.signInFailed)
        return
      }
    }

    guard
      let code = MicrosoftOAuthCallbackPolicy.authorizationCode(
        from: callbackURL,
        expectedScheme: AppIdentity.bundleIdentifier,
        expectedState: state
      )
    else {
      throw GraphIntegrationError.invalidCallback
    }

    return try await exchangeToken(
      parameters: [
        "client_id": configuration.clientID,
        "grant_type": "authorization_code",
        "code": code,
        "redirect_uri": redirectURI,
        "code_verifier": verifier,
        "scope": "offline_access Calendars.Read User.Read",
      ]
    )
  }

  func clearTokens() throws {
    try keychain.delete(.graphAccessToken)
    try keychain.delete(.graphRefreshToken)
    try keychain.delete(.graphTokenExpiry)
  }

  func invalidateAccessToken() throws {
    try keychain.delete(.graphAccessToken)
    try keychain.delete(.graphTokenExpiry)
  }

  private func refresh(refreshToken: String) async throws -> String {
    try await exchangeToken(
      parameters: [
        "client_id": configuration.clientID,
        "grant_type": "refresh_token",
        "refresh_token": refreshToken,
        "scope": "offline_access Calendars.Read User.Read",
      ]
    )
  }

  private func exchangeToken(parameters: [String: String]) async throws -> String {
    guard !configuration.clientID.isEmpty,
      let tokenURL = URL(
        string: "https://login.microsoftonline.com/\(configuration.tenantID)/oauth2/v2.0/token"
      ),
      MicrosoftLoginEndpointPolicy.isAllowed(tokenURL)
    else {
      throw GraphIntegrationError.notConfigured
    }

    var request = URLRequest(url: tokenURL)
    request.httpMethod = "POST"
    request.setValue(
      "application/x-www-form-urlencoded",
      forHTTPHeaderField: "Content-Type"
    )
    request.httpBody = parameters.formURLEncodedData()

    let configuration = URLSessionConfiguration.ephemeral
    configuration.urlCache = nil
    configuration.httpCookieStorage = nil
    configuration.timeoutIntervalForRequest = 30
    configuration.timeoutIntervalForResource = 60
    let redirectDelegate = RestrictedRedirectDelegate(
      isAllowed: MicrosoftLoginEndpointPolicy.isAllowed
    )
    let session = URLSession(
      configuration: configuration,
      delegate: redirectDelegate,
      delegateQueue: nil
    )
    defer { session.finishTasksAndInvalidate() }
    let (data, response) = try await session.data(for: request)
    guard data.count <= DeskLimits.maxIncomingEventBytes,
      let http = response as? HTTPURLResponse,
      (200..<300).contains(http.statusCode)
    else {
      throw GraphIntegrationError.invalidTokenResponse
    }
    let tokenResponse = try JSONDecoder().decode(TokenResponse.self, from: data)
    guard !tokenResponse.accessToken.isEmpty,
      tokenResponse.accessToken.utf8.count <= 16 * 1_024,
      tokenResponse.refreshToken?.utf8.count ?? 0 <= 16 * 1_024
    else {
      throw GraphIntegrationError.invalidTokenResponse
    }
    try keychain.write(tokenResponse.accessToken, account: .graphAccessToken)
    if let refreshToken = tokenResponse.refreshToken {
      try keychain.write(refreshToken, account: .graphRefreshToken)
    }
    let expiry = Date().addingTimeInterval(
      TimeInterval(min(24 * 60 * 60, max(60, tokenResponse.expiresIn)))
    ).timeIntervalSince1970
    try keychain.write(String(expiry), account: .graphTokenExpiry)
    return tokenResponse.accessToken
  }

  private static func randomURLSafeString(byteCount: Int) throws -> String {
    var bytes = [UInt8](repeating: 0, count: byteCount)
    let status = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
    guard status == errSecSuccess else {
      throw KeychainStore.KeychainError.unexpectedStatus(status)
    }
    return Data(bytes).base64URLEncodedString()
  }

  private struct TokenResponse: Decodable {
    let accessToken: String
    let refreshToken: String?
    let expiresIn: Int

    enum CodingKeys: String, CodingKey {
      case accessToken = "access_token"
      case refreshToken = "refresh_token"
      case expiresIn = "expires_in"
    }
  }
}

struct GraphSyncResult: Sendable {
  let events: [OutlookEvent]
  let removedEventIDs: [String]
  let deltaLink: String?
  let windowStart: Date
  let windowEnd: Date
  let isFullSync: Bool
}

struct GraphClient: Sendable {
  func synchronize(
    accessToken: String,
    savedDeltaLink: String?,
    savedWindowStart: Date?,
    savedWindowEnd: Date?,
    forceFullSync: Bool = false
  ) async throws -> GraphSyncResult {
    let now = Date()
    let savedDeltaURL = savedDeltaLink.flatMap(URL.init(string:))
    let canUseDelta =
      !forceFullSync
      && savedDeltaURL.map(GraphEndpointPolicy.isAllowed) == true
      && GraphSyncWindowPolicy.isReusable(
        now: now,
        windowStart: savedWindowStart,
        windowEnd: savedWindowEnd
      )

    let windowStart: Date
    let windowEnd: Date
    if canUseDelta, let savedWindowStart, let savedWindowEnd {
      windowStart = savedWindowStart
      windowEnd = savedWindowEnd
    } else {
      windowStart = now.addingTimeInterval(-60 * 60)
      windowEnd = now.addingTimeInterval(14 * 24 * 60 * 60)
    }
    let initialURL: URL
    if canUseDelta, let savedDeltaURL {
      initialURL = savedDeltaURL
    } else {
      guard
        var components = URLComponents(
          string: "https://graph.microsoft.com/v1.0/me/calendarView/delta"
        )
      else {
        throw GraphIntegrationError.invalidEndpoint
      }
      components.queryItems = [
        URLQueryItem(name: "startDateTime", value: Self.iso8601(windowStart)),
        URLQueryItem(name: "endDateTime", value: Self.iso8601(windowEnd)),
      ]
      guard let url = components.url, GraphEndpointPolicy.isAllowed(url) else {
        throw GraphIntegrationError.invalidEndpoint
      }
      initialURL = url
    }

    let configuration = URLSessionConfiguration.ephemeral
    configuration.urlCache = nil
    configuration.httpCookieStorage = nil
    configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
    configuration.timeoutIntervalForRequest = 30
    configuration.timeoutIntervalForResource = 60
    let redirectDelegate = RestrictedRedirectDelegate(
      isAllowed: GraphEndpointPolicy.isAllowed
    )
    let session = URLSession(
      configuration: configuration,
      delegate: redirectDelegate,
      delegateQueue: nil
    )
    defer { session.finishTasksAndInvalidate() }

    var url: URL? = initialURL
    var pageCount = 0
    var events: [OutlookEvent] = []
    var removedIDs: [String] = []
    var finalDeltaLink: String?

    while let currentURL = url {
      guard GraphEndpointPolicy.isAllowed(currentURL) else {
        throw GraphIntegrationError.invalidEndpoint
      }
      pageCount += 1
      guard pageCount <= 64 else {
        throw GraphIntegrationError.tooManyPages
      }
      var request = URLRequest(url: currentURL)
      request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
      request.setValue(
        "odata.maxpagesize=20, outlook.timezone=\"UTC\"",
        forHTTPHeaderField: "Prefer"
      )
      let (data, response) = try await session.data(for: request)
      guard let http = response as? HTTPURLResponse else {
        throw GraphIntegrationError.httpStatus(0)
      }
      if http.statusCode == 410 {
        throw GraphIntegrationError.deltaExpired
      }
      guard (200..<300).contains(http.statusCode) else {
        throw GraphIntegrationError.httpStatus(http.statusCode)
      }
      let page = try GraphDeltaDecoder.decode(data)
      guard
        events.count + removedIDs.count + page.events.count
          + page.removedEventIDs.count <= DeskLimits.maxGraphChangesPerSync
      else {
        throw GraphIntegrationError.tooManyChanges
      }
      events.append(contentsOf: page.events)
      removedIDs.append(contentsOf: page.removedEventIDs)
      if let delta = page.deltaLink {
        guard GraphEndpointPolicy.isAllowed(delta) else {
          throw GraphIntegrationError.invalidEndpoint
        }
        finalDeltaLink = delta.absoluteString
      }
      url = page.nextLink
    }

    return GraphSyncResult(
      events: events,
      removedEventIDs: removedIDs,
      deltaLink: finalDeltaLink,
      windowStart: windowStart,
      windowEnd: windowEnd,
      isFullSync: !canUseDelta
    )
  }

  private static func iso8601(_ date: Date) -> String {
    ISO8601DateFormatter().string(from: date)
  }
}

extension Data {
  fileprivate func base64URLEncodedString() -> String {
    base64EncodedString()
      .replacingOccurrences(of: "+", with: "-")
      .replacingOccurrences(of: "/", with: "_")
      .replacingOccurrences(of: "=", with: "")
  }
}

extension Dictionary where Key == String, Value == String {
  fileprivate func formURLEncodedData() -> Data {
    let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-._~"))
    let value = sorted { $0.key < $1.key }.map { key, value in
      let encodedKey = key.addingPercentEncoding(withAllowedCharacters: allowed) ?? ""
      let encodedValue = value.addingPercentEncoding(withAllowedCharacters: allowed) ?? ""
      return "\(encodedKey)=\(encodedValue)"
    }.joined(separator: "&")
    return Data(value.utf8)
  }
}
