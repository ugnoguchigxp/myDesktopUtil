import Darwin
import Foundation

enum CommandLineMode {
  static func exitCodeIfRequested() -> Int32? {
    let arguments = Array(CommandLine.arguments.dropFirst())
    guard arguments.first == "secret" else {
      return nil
    }
    guard arguments.count == 3,
      let operation = arguments.dropFirst().first,
      let account = KeychainStore.Account(
        rawValue: arguments.dropFirst(2).first ?? ""
      )
    else {
      writeUsage()
      return 64
    }

    let keychain = KeychainStore()
    do {
      switch operation {
      case "set":
        guard let pointer = getpass("Secret: ") else {
          FileHandle.standardError.write(Data("入力を読み込めません\n".utf8))
          return 1
        }
        let value = String(cString: pointer)
        guard !value.isEmpty, value.utf8.count <= 16 * 1_024 else {
          FileHandle.standardError.write(Data("値が空か、長すぎます\n".utf8))
          return 1
        }
        try keychain.write(value, account: account)
        FileHandle.standardOutput.write(Data("Keychainへ保存しました\n".utf8))
      case "delete":
        try keychain.delete(account)
        FileHandle.standardOutput.write(Data("Keychainから削除しました\n".utf8))
      default:
        writeUsage()
        return 64
      }
    } catch {
      FileHandle.standardError.write(Data((error.localizedDescription + "\n").utf8))
      return 1
    }
    return 0
  }

  private static func writeUsage() {
    let accounts = KeychainStore.Account.allCases.map(\.rawValue).joined(separator: "|")
    let usage = """
      Usage:
        desk-agent secret set <\(accounts)>
        desk-agent secret delete <\(accounts)>
      """
    FileHandle.standardError.write(Data((usage + "\n").utf8))
  }
}
