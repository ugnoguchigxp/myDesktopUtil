import ServiceManagement

@MainActor
enum LoginItemController {
  static var isEnabled: Bool {
    SMAppService.mainApp.status == .enabled
  }

  static var needsApproval: Bool {
    SMAppService.mainApp.status == .requiresApproval
  }

  static var statusText: String {
    switch SMAppService.mainApp.status {
    case .enabled:
      "ログイン時に起動: オン"
    case .requiresApproval:
      "ログイン時に起動: 承認が必要"
    case .notRegistered:
      "ログイン時に起動: オフ"
    case .notFound:
      "ログイン時に起動: .app bundleから実行してください"
    @unknown default:
      "ログイン時に起動: 状態不明"
    }
  }

  static func toggle() throws {
    if isEnabled {
      try SMAppService.mainApp.unregister()
    } else {
      try SMAppService.mainApp.register()
    }
  }

  static func openSettings() {
    SMAppService.openSystemSettingsLoginItems()
  }
}
