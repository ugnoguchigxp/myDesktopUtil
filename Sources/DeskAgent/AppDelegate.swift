import AppKit
import DeskCore

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate, NSMenuItemValidation {
  private let snippetStore = SnippetStore()
  private let pasteService = PasteService()
  private let hotKeyManager = HotKeyManager()
  private var statusItem: NSStatusItem?
  private let menu = NSMenu()
  private var previousFrontmostApplication: NSRunningApplication?
  private var statusMessage = "起動中"
  private var settingsController: PasteSettingsController?

  func applicationDidFinishLaunching(_ notification: Notification) {
    NSApp.setActivationPolicy(.accessory)
    snippetStore.load()
    configureStatusItem()
    registerHotKeys()
  }

  func applicationWillTerminate(_ notification: Notification) {
    hotKeyManager.shutdown()
  }

  func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
    openPasteSettings()
    return true
  }

  func menuWillOpen(_ menu: NSMenu) {
    let frontmost = NSWorkspace.shared.frontmostApplication
    if frontmost?.bundleIdentifier != AppIdentity.bundleIdentifier {
      previousFrontmostApplication = frontmost
    }
    rebuildMenu()
  }

  func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
    if menuItem.action == #selector(reloadSnippets) {
      return settingsController == nil
    }
    return true
  }

  private func configureStatusItem() {
    let statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
    if let button = statusItem.button {
      button.image = NSImage(
        systemSymbolName: "doc.on.clipboard",
        accessibilityDescription: AppIdentity.name
      )
      button.toolTip = AppIdentity.name
    }
    menu.delegate = self
    statusItem.menu = menu
    self.statusItem = statusItem
    rebuildMenu()
  }

  private func rebuildMenu() {
    menu.removeAllItems()

    let heading = NSMenuItem(title: AppIdentity.name, action: nil, keyEquivalent: "")
    heading.isEnabled = false
    menu.addItem(heading)
    menu.addItem(.separator())

    if snippetStore.snippets.isEmpty {
      let emptyTitle =
        snippetStore.lastError.map { "定型文エラー: \($0)" }
        ?? "定型文がありません"
      let empty = NSMenuItem(title: emptyTitle, action: nil, keyEquivalent: "")
      empty.isEnabled = false
      menu.addItem(empty)
    } else {
      for snippet in snippetStore.snippets {
        let suffix = snippet.hotKey.map { "    \($0.description)" } ?? ""
        let item = NSMenuItem(
          title: snippet.label + suffix,
          action: #selector(pasteSnippet(_:)),
          keyEquivalent: ""
        )
        item.target = self
        item.representedObject = snippet.id
        menu.addItem(item)
      }
    }

    menu.addItem(.separator())
    menu.addItem(makeMenuItem("ペースト設定…", action: #selector(openPasteSettings)))
    menu.addItem(makeMenuItem("定型文ファイルを開く", action: #selector(openSnippets)))
    let reload = makeMenuItem("定型文を再読み込み", action: #selector(reloadSnippets))
    reload.isEnabled = settingsController == nil
    menu.addItem(reload)
    menu.addItem(.separator())

    let isAccessibilityTrusted = pasteService.isAccessibilityTrusted()
    let permission =
      isAccessibilityTrusted
      ? "Accessibility: 許可済み"
      : "Accessibility: 未許可"
    let permissionItem = NSMenuItem(title: permission, action: nil, keyEquivalent: "")
    permissionItem.isEnabled = false
    menu.addItem(permissionItem)
    if !isAccessibilityTrusted {
      menu.addItem(
        makeMenuItem(
          "Accessibility設定を開く",
          action: #selector(openAccessibilitySettings)
        )
      )
    }

    menu.addItem(
      makeMenuItem(LoginItemController.statusText, action: #selector(toggleLoginItem))
    )
    if LoginItemController.needsApproval {
      menu.addItem(
        makeMenuItem(
          "ログイン項目設定を開く",
          action: #selector(openLoginItemSettings)
        )
      )
    }

    let status = NSMenuItem(title: statusMessage, action: nil, keyEquivalent: "")
    status.isEnabled = false
    menu.addItem(status)
    menu.addItem(.separator())
    menu.addItem(makeMenuItem("終了", action: #selector(terminate)))
  }

  private func makeMenuItem(_ title: String, action: Selector) -> NSMenuItem {
    let item = NSMenuItem(title: title, action: action, keyEquivalent: "")
    item.target = self
    return item
  }

  private func registerHotKeys() {
    hotKeyManager.unregisterAll()
    var failures: [String] = []

    do {
      try hotKeyManager.register(HotKey.parse("Cmd+Option+P")) { [weak self] in
        guard let self else {
          return
        }
        previousFrontmostApplication = NSWorkspace.shared.frontmostApplication
        statusItem?.button?.performClick(nil)
      }
    } catch {
      failures.append(error.localizedDescription)
    }

    for snippet in snippetStore.snippets {
      guard let hotKey = snippet.hotKey else {
        continue
      }
      do {
        try hotKeyManager.register(hotKey) { [weak self] in
          self?.pasteSnippet(id: snippet.id, target: NSWorkspace.shared.frontmostApplication)
        }
      } catch {
        failures.append(error.localizedDescription)
      }
    }

    if failures.isEmpty {
      statusMessage = "\(snippetStore.snippets.count)件の定型文を読み込みました"
    } else {
      statusMessage = failures.joined(separator: " / ")
    }
    rebuildMenu()
  }

  @objc
  private func pasteSnippet(_ sender: NSMenuItem) {
    guard let id = sender.representedObject as? String else {
      return
    }
    pasteSnippet(id: id, target: previousFrontmostApplication)
  }

  private func pasteSnippet(id: String, target: NSRunningApplication?) {
    guard let snippet = snippetStore.snippet(id: id) else {
      statusMessage = "定型文が見つかりません: \(id)"
      rebuildMenu()
      return
    }
    if snippet.pasteMode == .copy {
      do {
        try pasteService.copy(text: snippet.text)
        statusMessage = "コピーしました: \(snippet.label)"
      } catch {
        statusMessage = error.localizedDescription
      }
      rebuildMenu()
      return
    }
    pasteService.paste(text: snippet.text, into: target) { [weak self] result in
      switch result {
      case .success:
        self?.statusMessage = "貼り付けました: \(snippet.label)"
      case .failure(let error):
        self?.statusMessage = error.localizedDescription
      }
      self?.rebuildMenu()
    }
  }

  @objc
  private func openPasteSettings() {
    if let settingsController {
      settingsController.show()
      return
    }
    guard snippetStore.lastError == nil else {
      let alert = NSAlert()
      alert.messageText = "定型文を読み込めません"
      alert.informativeText = snippetStore.lastError ?? ""
      alert.runModal()
      return
    }
    let controller = PasteSettingsController(snippets: snippetStore.snippets) { [weak self] updated in
      guard let self else { return }
      try snippetStore.save(updated)
    }
    controller.onFocusChange = { [weak self] focused in
      guard let self else { return }
      if focused {
        hotKeyManager.unregisterAll()
      } else {
        registerHotKeys()
      }
    }
    controller.onClose = { [weak self] in
      guard let self else { return }
      settingsController = nil
      registerHotKeys()
    }
    settingsController = controller
    controller.show()
  }

  @objc
  private func openSnippets() {
    NSWorkspace.shared.open(AppPaths.snippets)
  }

  @objc
  private func reloadSnippets() {
    guard settingsController == nil else { return }
    snippetStore.load()
    registerHotKeys()
  }

  @objc
  private func openAccessibilitySettings() {
    guard
      let url = URL(
        string:
          "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility"
      )
    else {
      return
    }
    NSWorkspace.shared.open(url)
  }

  @objc
  private func toggleLoginItem() {
    if LoginItemController.needsApproval {
      LoginItemController.openSettings()
      statusMessage = "ログイン時起動をシステム設定で承認してください"
      rebuildMenu()
      return
    }
    do {
      try LoginItemController.toggle()
      statusMessage = LoginItemController.statusText
    } catch {
      statusMessage = error.localizedDescription
    }
    rebuildMenu()
  }

  @objc
  private func openLoginItemSettings() {
    LoginItemController.openSettings()
  }

  @objc
  private func terminate() {
    NSApp.terminate(nil)
  }
}
