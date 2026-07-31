import Carbon
import DeskCore
import Foundation

private func deskAgentHotKeyHandler(
  _: EventHandlerCallRef?,
  event: EventRef?,
  userData: UnsafeMutableRawPointer?
) -> OSStatus {
  guard let event, let userData else {
    return OSStatus(eventNotHandledErr)
  }
  var hotKeyID = EventHotKeyID()
  let status = GetEventParameter(
    event,
    EventParamName(kEventParamDirectObject),
    EventParamType(typeEventHotKeyID),
    nil,
    MemoryLayout<EventHotKeyID>.size,
    nil,
    &hotKeyID
  )
  guard status == noErr else {
    return status
  }
  let manager = Unmanaged<HotKeyManager>.fromOpaque(userData).takeUnretainedValue()
  MainActor.assumeIsolated {
    manager.handle(id: hotKeyID.id)
  }
  return noErr
}

@MainActor
final class HotKeyManager {
  enum RegistrationError: LocalizedError {
    case handlerInstallationFailed(OSStatus)
    case unsupportedKey(String)
    case registrationFailed(String, OSStatus)

    var errorDescription: String? {
      switch self {
      case .handlerInstallationFailed(let status):
        "ショートカット処理を初期化できません (OSStatus \(status))"
      case .unsupportedKey(let key):
        "未対応のキーです: \(key)"
      case .registrationFailed(let hotKey, let status):
        "ショートカットを登録できません: \(hotKey) (OSStatus \(status))"
      }
    }
  }

  private var handlerRef: EventHandlerRef?
  private var registrations: [EventHotKeyRef] = []
  private var actions: [UInt32: () -> Void] = [:]
  private var nextID: UInt32 = 1
  private var handlerInstallationStatus = OSStatus(eventInternalErr)

  init() {
    var eventType = EventTypeSpec(
      eventClass: OSType(kEventClassKeyboard),
      eventKind: UInt32(kEventHotKeyPressed)
    )
    handlerInstallationStatus = InstallEventHandler(
      GetApplicationEventTarget(),
      deskAgentHotKeyHandler,
      1,
      &eventType,
      Unmanaged.passUnretained(self).toOpaque(),
      &handlerRef
    )
  }

  func shutdown() {
    unregisterAll()
    if let handlerRef {
      RemoveEventHandler(handlerRef)
    }
    handlerRef = nil
  }

  func unregisterAll() {
    for registration in registrations {
      UnregisterEventHotKey(registration)
    }
    registrations.removeAll(keepingCapacity: true)
    actions.removeAll(keepingCapacity: true)
    nextID = 1
  }

  func register(_ hotKey: HotKey, action: @escaping () -> Void) throws {
    guard handlerInstallationStatus == noErr, handlerRef != nil else {
      throw RegistrationError.handlerInstallationFailed(handlerInstallationStatus)
    }
    guard let keyCode = Self.keyCodes[hotKey.key] else {
      throw RegistrationError.unsupportedKey(hotKey.key)
    }

    let id = nextID
    nextID += 1
    let hotKeyID = EventHotKeyID(signature: 0x4441_4754, id: id)
    var reference: EventHotKeyRef?
    let status = RegisterEventHotKey(
      UInt32(keyCode),
      carbonModifiers(for: hotKey.modifiers),
      hotKeyID,
      GetApplicationEventTarget(),
      0,
      &reference
    )
    guard status == noErr, let reference else {
      throw RegistrationError.registrationFailed(hotKey.description, status)
    }
    registrations.append(reference)
    actions[id] = action
  }

  fileprivate func handle(id: UInt32) {
    actions[id]?()
  }

  private func carbonModifiers(for modifiers: Set<HotKeyModifier>) -> UInt32 {
    var result: UInt32 = 0
    if modifiers.contains(.command) {
      result |= UInt32(cmdKey)
    }
    if modifiers.contains(.option) {
      result |= UInt32(optionKey)
    }
    if modifiers.contains(.control) {
      result |= UInt32(controlKey)
    }
    if modifiers.contains(.shift) {
      result |= UInt32(shiftKey)
    }
    return result
  }

  private static let keyCodes: [String: Int] = [
    "A": kVK_ANSI_A, "B": kVK_ANSI_B, "C": kVK_ANSI_C, "D": kVK_ANSI_D,
    "E": kVK_ANSI_E, "F": kVK_ANSI_F, "G": kVK_ANSI_G, "H": kVK_ANSI_H,
    "I": kVK_ANSI_I, "J": kVK_ANSI_J, "K": kVK_ANSI_K, "L": kVK_ANSI_L,
    "M": kVK_ANSI_M, "N": kVK_ANSI_N, "O": kVK_ANSI_O, "P": kVK_ANSI_P,
    "Q": kVK_ANSI_Q, "R": kVK_ANSI_R, "S": kVK_ANSI_S, "T": kVK_ANSI_T,
    "U": kVK_ANSI_U, "V": kVK_ANSI_V, "W": kVK_ANSI_W, "X": kVK_ANSI_X,
    "Y": kVK_ANSI_Y, "Z": kVK_ANSI_Z,
    "0": kVK_ANSI_0, "1": kVK_ANSI_1, "2": kVK_ANSI_2, "3": kVK_ANSI_3,
    "4": kVK_ANSI_4, "5": kVK_ANSI_5, "6": kVK_ANSI_6, "7": kVK_ANSI_7,
    "8": kVK_ANSI_8, "9": kVK_ANSI_9,
    "F1": kVK_F1, "F2": kVK_F2, "F3": kVK_F3, "F4": kVK_F4,
    "F5": kVK_F5, "F6": kVK_F6, "F7": kVK_F7, "F8": kVK_F8,
    "F9": kVK_F9, "F10": kVK_F10, "F11": kVK_F11, "F12": kVK_F12,
    "F13": kVK_F13, "F14": kVK_F14, "F15": kVK_F15, "F16": kVK_F16,
    "F17": kVK_F17, "F18": kVK_F18, "F19": kVK_F19, "F20": kVK_F20,
    "SPACE": kVK_Space, "RETURN": kVK_Return, "TAB": kVK_Tab,
    "ESCAPE": kVK_Escape, "LEFT": kVK_LeftArrow, "RIGHT": kVK_RightArrow,
    "UP": kVK_UpArrow, "DOWN": kVK_DownArrow,
  ]
}
