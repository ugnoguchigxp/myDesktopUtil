import Foundation

public enum DeskLimits {
  public static let maxSnippetBytes = 64 * 1_024
  public static let maxSnippetLabelCharacters = 128
  public static let maxSnippetLabelBytes = 512
  public static let maxTotalSnippetBytes = 2 * 1_024 * 1_024
  public static let maxClipboardSnapshotBytes = 4 * 1_024 * 1_024
  public static let maxClipboardItems = 128
  public static let maxClipboardRepresentations = 512
}

public enum ClipboardRestoreDecision: Equatable, Sendable {
  case restore
  case leaveCurrentContents

  public static func decide(
    expectedChangeCount: Int,
    currentChangeCount: Int,
    markerMatches: Bool
  ) -> Self {
    guard expectedChangeCount == currentChangeCount, markerMatches else {
      return .leaveCurrentContents
    }
    return .restore
  }
}
