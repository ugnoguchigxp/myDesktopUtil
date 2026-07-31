import DeskCore
import Foundation

@MainActor
final class SnippetStore {
  private(set) var snippets: [Snippet] = []
  private(set) var lastError: String?

  func load() {
    do {
      try ensureSampleExists()
      let data = try Data(contentsOf: AppPaths.snippets, options: [.mappedIfSafe])
      guard data.count <= DeskLimits.maxTotalSnippetBytes + 64 * 1_024 else {
        throw SnippetError.totalTextTooLarge
      }
      guard let source = String(data: data, encoding: .utf8) else {
        throw SnippetError.malformedTOML(
          line: 1,
          message: "UTF-8として読み込めません"
        )
      }
      snippets = try SnippetsTOML.parse(source)
      lastError = nil
    } catch {
      snippets = []
      lastError = error.localizedDescription
    }
  }

  func snippet(id: String) -> Snippet? {
    snippets.first { $0.id == id }
  }

  private func ensureSampleExists() throws {
    guard !FileManager.default.fileExists(atPath: AppPaths.snippets.path) else {
      return
    }
    try FileManager.default.createDirectory(
      at: AppPaths.applicationSupport,
      withIntermediateDirectories: true
    )
    try Data(SnippetsTOML.sample().utf8).write(to: AppPaths.snippets, options: .atomic)
  }
}
