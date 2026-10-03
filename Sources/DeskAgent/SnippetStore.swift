import DeskCore
import Foundation

@MainActor
final class SnippetStore {
  private(set) var snippets: [Snippet] = []
  private(set) var lastError: String?
  private var loadedData: Data?
  private let directory: URL
  private var file: URL { directory.appendingPathComponent("snippets.toml") }

  init(directory: URL = AppPaths.applicationSupport) {
    self.directory = directory
  }

  enum SaveError: LocalizedError {
    case changedOnDisk

    var errorDescription: String? {
      "定型文ファイルが別の場所で変更されました。設定画面を閉じて「定型文を再読み込み」を選んでください。"
    }
  }

  func load() {
    do {
      try ensureSampleExists()
      let data = try Data(contentsOf: file, options: [.mappedIfSafe])
      guard data.count <= DeskLimits.maxTotalSnippetBytes + 64 * 1_024 else {
        throw SnippetError.totalTextTooLarge
      }
      guard let source = String(data: data, encoding: .utf8) else {
        throw SnippetError.malformedTOML(
          line: 1,
          message: "UTF-8として読み込めません"
        )
      }
      let backup = directory.appendingPathComponent("snippets.before-six-slots.toml")
      let migrationMarker = directory.appendingPathComponent("snippets.editor-v1")
      let alreadyUpgraded = FileManager.default.fileExists(atPath: migrationMarker.path)
      let expanded = alreadyUpgraded ? source : try SnippetsTOML.addingMissingDefaults(to: source)
      let parsed = try SnippetsTOML.parse(expanded)
      let expandedData = Data(expanded.utf8)
      if !alreadyUpgraded && !FileManager.default.fileExists(atPath: backup.path) {
        try data.write(to: backup, options: .atomic)
      }
      if expanded != source {
        try expandedData.write(to: file, options: .atomic)
      }
      if !alreadyUpgraded {
        try Data("1\n".utf8).write(to: migrationMarker, options: .atomic)
      }
      snippets = parsed
      loadedData = expandedData
      lastError = nil
    } catch {
      snippets = []
      loadedData = nil
      lastError = error.localizedDescription
    }
  }

  func snippet(id: String) -> Snippet? {
    snippets.first { $0.id == id }
  }

  func save(_ updatedSnippets: [Snippet]) throws {
    let source = try SnippetsTOML.serialize(updatedSnippets)
    let data = Data(source.utf8)
    guard data.count <= DeskLimits.maxTotalSnippetBytes + 64 * 1_024 else {
      throw SnippetError.totalTextTooLarge
    }
    let current = try Data(contentsOf: file)
    guard current == loadedData else {
      throw SaveError.changedOnDisk
    }
    try data.write(to: file, options: .atomic)
    snippets = updatedSnippets
    loadedData = data
    lastError = nil
  }

  private func ensureSampleExists() throws {
    guard !FileManager.default.fileExists(atPath: file.path) else {
      return
    }
    try FileManager.default.createDirectory(
      at: directory,
      withIntermediateDirectories: true
    )
    try Data(SnippetsTOML.sample().utf8).write(to: file, options: .atomic)
  }
}
