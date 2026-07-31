import Foundation

struct ConnectionConfiguration: Codable, Sendable {
  struct Slack: Codable, Sendable {
    var selfUserID: String

    init(selfUserID: String = "") {
      self.selfUserID = selfUserID
    }
  }

  var slack: Slack?
  var outlookPollSeconds: Int

  init(
    slack: Slack? = Slack(),
    outlookPollSeconds: Int = 180
  ) {
    self.slack = slack
    self.outlookPollSeconds = outlookPollSeconds
  }

  private enum CodingKeys: String, CodingKey {
    case slack
    case outlookPollSeconds
    case legacyGraphPollSeconds = "graphPollSeconds"
  }

  init(from decoder: Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    slack = try container.decodeIfPresent(Slack.self, forKey: .slack) ?? Slack()
    let configuredPollSeconds = try container.decodeIfPresent(
      Int.self,
      forKey: .outlookPollSeconds
    )
    let legacyPollSeconds = try container.decodeIfPresent(
      Int.self,
      forKey: .legacyGraphPollSeconds
    )
    outlookPollSeconds = configuredPollSeconds ?? legacyPollSeconds ?? 180
  }

  func encode(to encoder: Encoder) throws {
    var container = encoder.container(keyedBy: CodingKeys.self)
    try container.encodeIfPresent(slack, forKey: .slack)
    try container.encode(outlookPollSeconds, forKey: .outlookPollSeconds)
  }

  static func loadOrCreate() -> ConnectionConfiguration {
    do {
      try FileManager.default.createDirectory(
        at: AppPaths.applicationSupport,
        withIntermediateDirectories: true
      )
      if !FileManager.default.fileExists(atPath: AppPaths.connections.path) {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(ConnectionConfiguration())
        try data.write(to: AppPaths.connections, options: .atomic)
      }
      let data = try Data(contentsOf: AppPaths.connections, options: [.mappedIfSafe])
      guard data.count <= 64 * 1_024 else {
        return ConnectionConfiguration()
      }
      var configuration = try JSONDecoder().decode(
        ConnectionConfiguration.self,
        from: data
      )
      configuration.sanitize()
      return configuration
    } catch {
      return ConnectionConfiguration()
    }
  }

  private mutating func sanitize() {
    outlookPollSeconds = min(1_800, max(60, outlookPollSeconds))

    if var slack {
      slack.selfUserID = slack.selfUserID.trimmingCharacters(
        in: .whitespacesAndNewlines
      )
      if slack.selfUserID.count > 64
        || !Self.containsOnlyIdentifierCharacters(slack.selfUserID)
      {
        slack.selfUserID = ""
      }
      self.slack = slack
    }
  }

  private static func containsOnlyIdentifierCharacters(_ value: String) -> Bool {
    let allowed = CharacterSet.alphanumerics.union(
      CharacterSet(charactersIn: "-._")
    )
    return value.unicodeScalars.allSatisfy(allowed.contains)
  }
}
