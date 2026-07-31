import Foundation

enum TextBounds {
  static func utf8Prefix(_ source: String, maxBytes: Int) -> String {
    guard maxBytes > 0 else {
      return ""
    }
    guard source.utf8.count > maxBytes else {
      return source
    }

    var bytes = Array(source.utf8.prefix(maxBytes))
    while !bytes.isEmpty {
      if let result = String(bytes: bytes, encoding: .utf8) {
        return result
      }
      bytes.removeLast()
    }
    return ""
  }
}
