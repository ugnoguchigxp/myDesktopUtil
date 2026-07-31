import Foundation

struct ConnectionConfiguration: Codable, Sendable {
  struct Microsoft: Codable, Sendable {
    var clientID: String
    var tenantID: String

    init(clientID: String = "", tenantID: String = "common") {
      self.clientID = clientID
      self.tenantID = tenantID
    }
  }

  struct Slack: Codable, Sendable {
    var selfUserID: String

    init(selfUserID: String = "") {
      self.selfUserID = selfUserID
    }
  }

  var microsoft: Microsoft?
  var slack: Slack?
  var graphPollSeconds: Int

  init(
    microsoft: Microsoft? = Microsoft(),
    slack: Slack? = Slack(),
    graphPollSeconds: Int = 180
  ) {
    self.microsoft = microsoft
    self.slack = slack
    self.graphPollSeconds = graphPollSeconds
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
    graphPollSeconds = min(1_800, max(60, graphPollSeconds))

    if var microsoft {
      microsoft.clientID = microsoft.clientID.trimmingCharacters(
        in: .whitespacesAndNewlines
      )
      if microsoft.clientID.count > 256
        || !Self.containsOnlyIdentifierCharacters(microsoft.clientID)
      {
        microsoft.clientID = ""
      }

      microsoft.tenantID = microsoft.tenantID.trimmingCharacters(
        in: .whitespacesAndNewlines
      )
      if microsoft.tenantID.isEmpty
        || microsoft.tenantID.count > 255
        || !Self.containsOnlyIdentifierCharacters(microsoft.tenantID)
      {
        microsoft.tenantID = "common"
      }
      self.microsoft = microsoft
    }

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
