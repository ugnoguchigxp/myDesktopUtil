import Foundation

enum AppIdentity {
  static let name = "Desk Agent"
  static let bundleIdentifier = "com.local.deskagent"
  static let keychainService = bundleIdentifier
  static let pasteboardMarkerType = "\(bundleIdentifier).paste-marker"
}

enum AppPaths {
  static var applicationSupport: URL {
    if let override = ProcessInfo.processInfo.environment["DESK_AGENT_DATA_DIR"],
      !override.isEmpty
    {
      return URL(fileURLWithPath: override, isDirectory: true)
    }
    let base =
      FileManager.default.urls(
        for: .applicationSupportDirectory,
        in: .userDomainMask
      ).first
      ?? FileManager.default.homeDirectoryForCurrentUser
      .appendingPathComponent("Library/Application Support", isDirectory: true)
    return base.appendingPathComponent("DeskAgent", isDirectory: true)
  }

  static var snippets: URL {
    applicationSupport.appendingPathComponent("snippets.toml")
  }

  static var state: URL {
    applicationSupport.appendingPathComponent("state.json")
  }

  static var connections: URL {
    applicationSupport.appendingPathComponent("connections.json")
  }
}
