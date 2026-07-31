import Foundation
import Security

struct KeychainStore: Sendable {
  enum KeychainError: LocalizedError {
    case unexpectedStatus(OSStatus)
    case invalidData
    case valueTooLarge

    var errorDescription: String? {
      switch self {
      case .unexpectedStatus(let status):
        "Keychain操作に失敗しました (OSStatus \(status))"
      case .invalidData:
        "Keychainの値を読み込めません"
      case .valueTooLarge:
        "Keychainへ保存する値が長すぎます"
      }
    }
  }

  enum Account: String, CaseIterable, Sendable {
    case graphAccessToken = "graph-access-token"
    case graphRefreshToken = "graph-refresh-token"
    case graphTokenExpiry = "graph-token-expiry"
    case slackAppToken = "slack-app-token"
    case slackUserToken = "slack-user-token"
  }

  let service: String

  init(service: String = AppIdentity.keychainService) {
    self.service = service
  }

  func read(_ account: Account) throws -> String? {
    let query: [String: Any] = [
      kSecClass as String: kSecClassGenericPassword,
      kSecAttrService as String: service,
      kSecAttrAccount as String: account.rawValue,
      kSecReturnData as String: true,
      kSecMatchLimit as String: kSecMatchLimitOne,
    ]
    var result: CFTypeRef?
    let status = SecItemCopyMatching(query as CFDictionary, &result)
    if status == errSecItemNotFound {
      return nil
    }
    guard status == errSecSuccess else {
      throw KeychainError.unexpectedStatus(status)
    }
    guard let data = result as? Data,
      data.count <= 16 * 1_024,
      let value = String(data: data, encoding: .utf8)
    else {
      throw KeychainError.invalidData
    }
    return value
  }

  func write(_ value: String, account: Account) throws {
    let data = Data(value.utf8)
    guard data.count <= 16 * 1_024 else {
      throw KeychainError.valueTooLarge
    }
    let identity: [String: Any] = [
      kSecClass as String: kSecClassGenericPassword,
      kSecAttrService as String: service,
      kSecAttrAccount as String: account.rawValue,
    ]
    let update: [String: Any] = [
      kSecValueData as String: data,
      kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly,
    ]
    let updateStatus = SecItemUpdate(identity as CFDictionary, update as CFDictionary)
    if updateStatus == errSecSuccess {
      return
    }
    guard updateStatus == errSecItemNotFound else {
      throw KeychainError.unexpectedStatus(updateStatus)
    }
    var addition = identity
    addition.merge(update) { _, new in new }
    let addStatus = SecItemAdd(addition as CFDictionary, nil)
    guard addStatus == errSecSuccess else {
      throw KeychainError.unexpectedStatus(addStatus)
    }
  }

  func delete(_ account: Account) throws {
    let query: [String: Any] = [
      kSecClass as String: kSecClassGenericPassword,
      kSecAttrService as String: service,
      kSecAttrAccount as String: account.rawValue,
    ]
    let status = SecItemDelete(query as CFDictionary)
    guard status == errSecSuccess || status == errSecItemNotFound else {
      throw KeychainError.unexpectedStatus(status)
    }
  }
}
