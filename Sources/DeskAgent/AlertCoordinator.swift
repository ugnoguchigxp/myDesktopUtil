import DeskCore
import Foundation

@MainActor
final class AlertCoordinator {
  private let alarmController: AlarmController
  private var pending = BoundedFIFO<Alert>(capacity: DeskLimits.maxAlertQueue)
  private var knownIDs: Set<String> = []
  private var activeAlert: Alert?

  var onAcknowledged: ((Alert) -> Void)?
  var onQueueOverflow: (() -> Void)?

  init(alarmController: AlarmController) {
    self.alarmController = alarmController
  }

  @discardableResult
  func enqueue(_ alert: Alert) -> Bool {
    guard !knownIDs.contains(alert.id) else {
      return true
    }
    knownIDs.insert(alert.id)
    if activeAlert == nil {
      show(alert)
    } else if !pending.append(alert) {
      knownIDs.remove(alert.id)
      onQueueOverflow?()
      return false
    }
    return true
  }

  private func show(_ alert: Alert) {
    activeAlert = alert
    alarmController.show(alert) { [weak self] in
      guard let self else {
        return
      }
      let acknowledged = activeAlert
      activeAlert = nil
      if let acknowledged {
        knownIDs.remove(acknowledged.id)
      }
      if let next = pending.popFirst() {
        show(next)
      }
      if let acknowledged {
        onAcknowledged?(acknowledged)
      }
    }
  }
}
