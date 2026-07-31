import Foundation

public enum HotKeyModifier: String, Codable, CaseIterable, Hashable, Sendable {
  case command
  case option
  case control
  case shift
}

public struct HotKey: Codable, Equatable, Hashable, Sendable, CustomStringConvertible {
  public let modifiers: Set<HotKeyModifier>
  public let key: String

  public init(modifiers: Set<HotKeyModifier>, key: String) {
    self.modifiers = modifiers
    self.key = key.uppercased()
  }

  public var description: String {
    let order: [HotKeyModifier] = [.command, .control, .option, .shift]
    let names: [HotKeyModifier: String] = [
      .command: "Cmd",
      .control: "Control",
      .option: "Option",
      .shift: "Shift",
    ]
    return (order.compactMap { modifiers.contains($0) ? names[$0] : nil } + [key])
      .joined(separator: "+")
  }

  public static func parse(_ source: String) throws -> HotKey {
    let parts =
      source
      .split(separator: "+", omittingEmptySubsequences: false)
      .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }

    guard parts.count >= 2, let rawKey = parts.last, !rawKey.isEmpty else {
      throw SnippetError.invalidHotKey(source)
    }

    var modifiers: Set<HotKeyModifier> = []
    for rawModifier in parts.dropLast() {
      let modifier: HotKeyModifier
      switch rawModifier.lowercased() {
      case "cmd", "command", "⌘":
        modifier = .command
      case "option", "opt", "alt", "⌥":
        modifier = .option
      case "control", "ctrl", "⌃":
        modifier = .control
      case "shift", "⇧":
        modifier = .shift
      default:
        throw SnippetError.invalidHotKey(source)
      }
      guard modifiers.insert(modifier).inserted else {
        throw SnippetError.invalidHotKey(source)
      }
    }

    let key = rawKey.uppercased()
    guard validKeys.contains(key) else {
      throw SnippetError.invalidHotKey(source)
    }
    return HotKey(modifiers: modifiers, key: key)
  }

  private static let validKeys: Set<String> = {
    var values = Set((0...9).map(String.init))
    values.formUnion((65...90).compactMap { UnicodeScalar($0).map(String.init) })
    values.formUnion((1...20).map { "F\($0)" })
    values.formUnion(["SPACE", "RETURN", "TAB", "ESCAPE", "LEFT", "RIGHT", "UP", "DOWN"])
    return values
  }()
}

public struct Snippet: Codable, Equatable, Sendable {
  public let id: String
  public let label: String
  public let hotKey: HotKey?
  public let text: String

  public init(id: String, label: String, hotKey: HotKey?, text: String) {
    self.id = id
    self.label = label
    self.hotKey = hotKey
    self.text = text
  }
}

public enum SnippetError: Error, Equatable, LocalizedError, Sendable {
  case malformedTOML(line: Int, message: String)
  case missingField(index: Int, field: String)
  case unknownField(line: Int, field: String)
  case duplicateID(String)
  case duplicateHotKey(String)
  case invalidID(String)
  case invalidHotKey(String)
  case labelTooLarge(String)
  case emptyText(String)
  case tooManySnippets(Int)
  case snippetTooLarge(String)
  case totalTextTooLarge

  public var errorDescription: String? {
    switch self {
    case .malformedTOML(let line, let message):
      "snippets.toml \(line)行目: \(message)"
    case .missingField(let index, let field):
      "\(index + 1)件目の定型文に \(field) がありません"
    case .unknownField(let line, let field):
      "snippets.toml \(line)行目: 未対応の項目 \(field)"
    case .duplicateID(let id):
      "定型文IDが重複しています: \(id)"
    case .duplicateHotKey(let hotKey):
      "ショートカットが重複しています: \(hotKey)"
    case .invalidID(let id):
      "定型文IDが不正です: \(id)"
    case .invalidHotKey(let hotKey):
      "ショートカットが不正です: \(hotKey)"
    case .labelTooLarge(let id):
      "定型文の表示名が長すぎます: \(id)"
    case .emptyText(let id):
      "定型文が空です: \(id)"
    case .tooManySnippets(let count):
      "定型文が多すぎます: \(count)件"
    case .snippetTooLarge(let id):
      "定型文が大きすぎます: \(id)"
    case .totalTextTooLarge:
      "定型文の合計サイズが上限を超えています"
    }
  }
}

public enum SnippetsTOML {
  private static let allowedFields: Set<String> = ["id", "label", "hotkey", "text"]

  public static func parse(_ source: String) throws -> [Snippet] {
    let lines = source.components(separatedBy: .newlines)
    var records: [[String: String]] = []
    var current: [String: String]?
    var lineIndex = 0

    while lineIndex < lines.count {
      let rawLine = lines[lineIndex]
      let trimmed = rawLine.trimmingCharacters(in: .whitespaces)
      let lineNumber = lineIndex + 1

      if trimmed.isEmpty || trimmed.hasPrefix("#") {
        lineIndex += 1
        continue
      }

      if trimmed == "[[snippets]]" {
        if let current {
          records.append(current)
        }
        current = [:]
        lineIndex += 1
        continue
      }

      guard current != nil else {
        throw SnippetError.malformedTOML(
          line: lineNumber,
          message: "[[snippets]] より前に値があります"
        )
      }
      guard let equalsIndex = rawLine.firstIndex(of: "=") else {
        throw SnippetError.malformedTOML(line: lineNumber, message: "=" + " がありません")
      }

      let key = rawLine[..<equalsIndex].trimmingCharacters(in: .whitespaces)
      guard allowedFields.contains(key) else {
        throw SnippetError.unknownField(line: lineNumber, field: key)
      }
      guard current?[key] == nil else {
        throw SnippetError.malformedTOML(line: lineNumber, message: "\(key) が重複しています")
      }

      let valueStart = rawLine.index(after: equalsIndex)
      var rawValue = String(rawLine[valueStart...]).trimmingCharacters(in: .whitespaces)

      if rawValue.hasPrefix("\"\"\"") {
        rawValue.removeFirst(3)
        var value = ""
        if let closing = rawValue.range(of: "\"\"\"") {
          value = String(rawValue[..<closing.lowerBound])
          try validateTrailingContent(
            String(rawValue[closing.upperBound...]),
            line: lineNumber
          )
        } else {
          lineIndex += 1
          var foundClosing = false
          while lineIndex < lines.count {
            let multilineLine = lines[lineIndex]
            if let closing = multilineLine.range(of: "\"\"\"") {
              if !value.isEmpty {
                value.append("\n")
              }
              value.append(contentsOf: multilineLine[..<closing.lowerBound])
              try validateTrailingContent(
                String(multilineLine[closing.upperBound...]),
                line: lineIndex + 1
              )
              foundClosing = true
              break
            }
            if !value.isEmpty {
              value.append("\n")
            }
            value.append(multilineLine)
            lineIndex += 1
          }
          guard foundClosing else {
            throw SnippetError.malformedTOML(
              line: lineNumber,
              message: "複数行文字列が閉じられていません"
            )
          }
        }
        current?[key] = try unescape(value, line: lineNumber)
      } else {
        current?[key] = try parseBasicString(rawValue, line: lineNumber)
      }
      lineIndex += 1
    }

    if let current {
      records.append(current)
    }
    return try validate(records)
  }

  public static func sample() -> String {
    """
    # Desk Agent snippets
    # hotkey は Cmd+Option+1 の形式で指定します。不要な場合は行ごと削除できます。

    [[snippets]]
    id = "codex-review"
    label = "Codex: コードレビュー"
    hotkey = "Cmd+Option+1"
    text = \"\"\"
    以下の変更内容をレビューしてください。

    特に次の観点を確認してください。
    - 型安全性
    - エラーハンドリング
    - パフォーマンス
    - テスト不足
    \"\"\"

    [[snippets]]
    id = "codex-investigate"
    label = "Codex: 原因調査"
    hotkey = "Cmd+Option+2"
    text = \"\"\"
    この問題の原因を調査してください。
    まだ修正は行わず、再現条件、根本原因、影響範囲を報告してください。
    \"\"\"
    """
  }

  private static func validate(_ records: [[String: String]]) throws -> [Snippet] {
    guard records.count <= DeskLimits.maxSnippets else {
      throw SnippetError.tooManySnippets(records.count)
    }

    var ids: Set<String> = []
    var hotKeys: Set<HotKey> = []
    var totalBytes = 0

    return try records.enumerated().map { index, record in
      guard let id = record["id"], !id.isEmpty else {
        throw SnippetError.missingField(index: index, field: "id")
      }
      guard id.count <= 64,
        id.unicodeScalars.allSatisfy({
          CharacterSet.alphanumerics.contains($0) || "-_.".unicodeScalars.contains($0)
        })
      else {
        throw SnippetError.invalidID(id)
      }
      guard ids.insert(id).inserted else {
        throw SnippetError.duplicateID(id)
      }

      guard let label = record["label"],
        !label.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
      else {
        throw SnippetError.missingField(index: index, field: "label")
      }
      guard label.count <= DeskLimits.maxSnippetLabelCharacters,
        label.utf8.count <= DeskLimits.maxSnippetLabelBytes
      else {
        throw SnippetError.labelTooLarge(id)
      }
      guard let text = record["text"] else {
        throw SnippetError.missingField(index: index, field: "text")
      }
      guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
        throw SnippetError.emptyText(id)
      }
      let byteCount = text.utf8.count
      guard byteCount <= DeskLimits.maxSnippetBytes else {
        throw SnippetError.snippetTooLarge(id)
      }
      totalBytes += byteCount
      guard totalBytes <= DeskLimits.maxTotalSnippetBytes else {
        throw SnippetError.totalTextTooLarge
      }

      let hotKey: HotKey?
      if let value = record["hotkey"], !value.isEmpty {
        let parsedHotKey = try HotKey.parse(value)
        guard hotKeys.insert(parsedHotKey).inserted else {
          throw SnippetError.duplicateHotKey(parsedHotKey.description)
        }
        hotKey = parsedHotKey
      } else {
        hotKey = nil
      }
      return Snippet(id: id, label: label, hotKey: hotKey, text: text)
    }
  }

  private static func parseBasicString(_ source: String, line: Int) throws -> String {
    guard source.first == "\"" else {
      throw SnippetError.malformedTOML(line: line, message: "値は文字列で指定してください")
    }
    var escaped = false
    var closingIndex: String.Index?
    var index = source.index(after: source.startIndex)
    while index < source.endIndex {
      let character = source[index]
      if character == "\"", !escaped {
        closingIndex = index
        break
      }
      if character == "\\", !escaped {
        escaped = true
      } else {
        escaped = false
      }
      index = source.index(after: index)
    }
    guard let closingIndex else {
      throw SnippetError.malformedTOML(line: line, message: "文字列が閉じられていません")
    }
    let valueStart = source.index(after: source.startIndex)
    let value = String(source[valueStart..<closingIndex])
    let trailingStart = source.index(after: closingIndex)
    try validateTrailingContent(String(source[trailingStart...]), line: line)
    return try unescape(value, line: line)
  }

  private static func validateTrailingContent(_ source: String, line: Int) throws {
    let trailing = source.trimmingCharacters(in: .whitespaces)
    guard trailing.isEmpty || trailing.hasPrefix("#") else {
      throw SnippetError.malformedTOML(line: line, message: "文字列の後に不正な値があります")
    }
  }

  private static func unescape(_ source: String, line: Int) throws -> String {
    var result = ""
    var iterator = source.makeIterator()
    while let character = iterator.next() {
      guard character == "\\" else {
        result.append(character)
        continue
      }
      guard let escaped = iterator.next() else {
        throw SnippetError.malformedTOML(line: line, message: "不完全なエスケープです")
      }
      switch escaped {
      case "n":
        result.append("\n")
      case "r":
        result.append("\r")
      case "t":
        result.append("\t")
      case "\"":
        result.append("\"")
      case "\\":
        result.append("\\")
      default:
        throw SnippetError.malformedTOML(
          line: line,
          message: "未対応のエスケープです: \\" + String(escaped)
        )
      }
    }
    return result
  }
}
