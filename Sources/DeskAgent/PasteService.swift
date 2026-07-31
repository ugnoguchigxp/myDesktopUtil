import AppKit
import ApplicationServices
import DeskCore

@MainActor
final class PasteService {
  enum PasteError: LocalizedError {
    case accessibilityPermissionRequired
    case targetUnavailable
    case pasteInProgress
    case clipboardCannotBeSafelyPreserved
    case clipboardWriteFailed
    case clipboardRestoreFailed
    case eventCreationFailed

    var errorDescription: String? {
      switch self {
      case .accessibilityPermissionRequired:
        "Accessibility権限が必要です"
      case .targetUnavailable:
        "貼り付け先のアプリを特定できません"
      case .pasteInProgress:
        "別の定型文を貼り付け中です"
      case .clipboardCannotBeSafelyPreserved:
        "Clipboardが大きいか特殊な形式のため、安全に貼り付けできません"
      case .clipboardWriteFailed:
        "Clipboardへ定型文を書き込めません"
      case .clipboardRestoreFailed:
        "元のClipboardを復元できません"
      case .eventCreationFailed:
        "⌘Vイベントを作成できません"
      }
    }
  }

  private struct Representation {
    let type: NSPasteboard.PasteboardType
    let data: Data
  }

  private struct ItemSnapshot {
    let representations: [Representation]
  }

  private enum RestoreResult: Equatable {
    case restored
    case skippedBecauseOwnershipChanged
    case failed
  }

  private let markerType = NSPasteboard.PasteboardType(AppIdentity.pasteboardMarkerType)
  private var isPasting = false
  private var didRequestAccessibilityPermission = false

  func isAccessibilityTrusted() -> Bool {
    AXIsProcessTrusted()
  }

  private func requestAccessibilityPermissionIfNeeded() {
    guard !didRequestAccessibilityPermission else {
      return
    }
    didRequestAccessibilityPermission = true
    let options =
      [
        "AXTrustedCheckOptionPrompt": true
      ] as CFDictionary
    _ = AXIsProcessTrustedWithOptions(options)
  }

  func paste(
    text: String,
    into targetApplication: NSRunningApplication?,
    completion: @escaping (Result<Void, Error>) -> Void
  ) {
    guard isAccessibilityTrusted() else {
      requestAccessibilityPermissionIfNeeded()
      completion(.failure(PasteError.accessibilityPermissionRequired))
      return
    }
    guard let targetApplication,
      targetApplication.bundleIdentifier != AppIdentity.bundleIdentifier
    else {
      completion(.failure(PasteError.targetUnavailable))
      return
    }
    guard !isPasting else {
      completion(.failure(PasteError.pasteInProgress))
      return
    }
    isPasting = true

    let pasteboard = NSPasteboard.general
    let snapshot: [ItemSnapshot]
    do {
      snapshot = try capture(pasteboard)
    } catch {
      finish(.failure(error), completion: completion)
      return
    }

    let marker = UUID().uuidString
    pasteboard.clearContents()
    let snippetItem = NSPasteboardItem()
    guard snippetItem.setString(text, forType: .string),
      snippetItem.setString(marker, forType: markerType),
      pasteboard.writeObjects([snippetItem])
    else {
      let error: Error =
        restore(snapshot, to: pasteboard)
        ? PasteError.clipboardWriteFailed
        : PasteError.clipboardRestoreFailed
      finish(.failure(error), completion: completion)
      return
    }
    let ownedChangeCount = pasteboard.changeCount

    guard !targetApplication.isTerminated,
      targetApplication.activate(options: [.activateIgnoringOtherApps])
    else {
      let restoreResult = restoreIfStillOwned(
        snapshot,
        marker: marker,
        ownedChangeCount: ownedChangeCount,
        pasteboard: pasteboard
      )
      let error: Error =
        restoreResult == .failed
        ? PasteError.clipboardRestoreFailed
        : PasteError.targetUnavailable
      finish(.failure(error), completion: completion)
      return
    }

    DispatchQueue.main.asyncAfter(deadline: .now() + .milliseconds(120)) {
      guard
        NSWorkspace.shared.frontmostApplication?.processIdentifier
          == targetApplication.processIdentifier
      else {
        let restoreResult = self.restoreIfStillOwned(
          snapshot,
          marker: marker,
          ownedChangeCount: ownedChangeCount,
          pasteboard: pasteboard
        )
        let error: Error =
          restoreResult == .failed
          ? PasteError.clipboardRestoreFailed
          : PasteError.targetUnavailable
        self.finish(.failure(error), completion: completion)
        return
      }
      do {
        try self.postCommandV()
      } catch {
        let restoreResult = self.restoreIfStillOwned(
          snapshot,
          marker: marker,
          ownedChangeCount: ownedChangeCount,
          pasteboard: pasteboard
        )
        let reportedError: Error =
          restoreResult == .failed
          ? PasteError.clipboardRestoreFailed
          : error
        self.finish(.failure(reportedError), completion: completion)
        return
      }

      DispatchQueue.main.asyncAfter(deadline: .now() + .milliseconds(450)) {
        let restoreResult = self.restoreIfStillOwned(
          snapshot,
          marker: marker,
          ownedChangeCount: ownedChangeCount,
          pasteboard: pasteboard
        )
        if restoreResult == .failed {
          self.finish(
            .failure(PasteError.clipboardRestoreFailed),
            completion: completion
          )
        } else {
          self.finish(.success(()), completion: completion)
        }
      }
    }
  }

  private func capture(_ pasteboard: NSPasteboard) throws -> [ItemSnapshot] {
    guard let pasteboardItems = pasteboard.pasteboardItems else {
      return []
    }
    guard pasteboardItems.count <= DeskLimits.maxClipboardItems else {
      throw PasteError.clipboardCannotBeSafelyPreserved
    }
    var totalBytes = 0
    var totalRepresentations = 0
    var snapshots: [ItemSnapshot] = []
    snapshots.reserveCapacity(pasteboardItems.count)

    for item in pasteboardItems {
      var representations: [Representation] = []
      for type in item.types {
        totalRepresentations += 1
        guard totalRepresentations <= DeskLimits.maxClipboardRepresentations else {
          throw PasteError.clipboardCannotBeSafelyPreserved
        }
        guard let data = item.data(forType: type) else {
          throw PasteError.clipboardCannotBeSafelyPreserved
        }
        totalBytes += data.count
        guard totalBytes <= DeskLimits.maxClipboardSnapshotBytes else {
          throw PasteError.clipboardCannotBeSafelyPreserved
        }
        representations.append(Representation(type: type, data: data))
      }
      snapshots.append(ItemSnapshot(representations: representations))
    }
    return snapshots
  }

  private func restoreIfStillOwned(
    _ snapshot: [ItemSnapshot],
    marker: String,
    ownedChangeCount: Int,
    pasteboard: NSPasteboard
  ) -> RestoreResult {
    let markerMatches = pasteboard.string(forType: markerType) == marker
    let decision = ClipboardRestoreDecision.decide(
      expectedChangeCount: ownedChangeCount,
      currentChangeCount: pasteboard.changeCount,
      markerMatches: markerMatches
    )
    guard decision == .restore else {
      return .skippedBecauseOwnershipChanged
    }
    return restore(snapshot, to: pasteboard) ? .restored : .failed
  }

  private func restore(_ snapshot: [ItemSnapshot], to pasteboard: NSPasteboard) -> Bool {
    pasteboard.clearContents()
    guard !snapshot.isEmpty else {
      return true
    }
    var items: [NSPasteboardItem] = []
    items.reserveCapacity(snapshot.count)
    for itemSnapshot in snapshot {
      let item = NSPasteboardItem()
      for representation in itemSnapshot.representations {
        guard item.setData(representation.data, forType: representation.type) else {
          return false
        }
      }
      items.append(item)
    }
    return pasteboard.writeObjects(items)
  }

  private func finish(
    _ result: Result<Void, Error>,
    completion: (Result<Void, Error>) -> Void
  ) {
    isPasting = false
    completion(result)
  }

  private func postCommandV() throws {
    guard let source = CGEventSource(stateID: .hidSystemState),
      let keyDown = CGEvent(
        keyboardEventSource: source,
        virtualKey: 9,
        keyDown: true
      ),
      let keyUp = CGEvent(
        keyboardEventSource: source,
        virtualKey: 9,
        keyDown: false
      )
    else {
      throw PasteError.eventCreationFailed
    }
    keyDown.flags = .maskCommand
    keyUp.flags = .maskCommand
    keyDown.post(tap: .cghidEventTap)
    keyUp.post(tap: .cghidEventTap)
  }
}
