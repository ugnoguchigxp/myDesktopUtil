import AppKit
import DeskCore

/// A regular draft editor window. The store is updated only after Save succeeds.
@MainActor
final class PasteSettingsController: NSWindowController, NSWindowDelegate, NSTextViewDelegate {
  private let settingsWindow: NSWindow
  private var drafts: [Snippet]
  private var selectedIndex = 0
  private var rowButtons: [SnippetRowButton] = []
  private let sidebarStack = FlippedStackView()
  private let sidebarHeading = NSTextField(labelWithString: "定型文")
  private var sidebarHeight: NSLayoutConstraint?
  private let deleteButton = NSButton()
  private let nameField = NSTextField()
  private let keyRecorder = ShortcutRecorderButton()
  private var modifierButtons: [HotKeyModifier: NSButton] = [:]
  private let shortcutHelp = NSTextField(wrappingLabelWithString: "")
  private let modePicker = NSPopUpButton()
  private let bodyView = NSTextView()
  private let modeHelp = NSTextField(wrappingLabelWithString: "")
  private let characterCount = NSTextField(labelWithString: "")
  private let errorLabel = NSTextField(wrappingLabelWithString: "")
  private let save: ([Snippet]) throws -> Void

  init(snippets: [Snippet], save: @escaping ([Snippet]) throws -> Void) {
    drafts = snippets
    self.save = save
    settingsWindow = NSWindow(
      contentRect: NSRect(x: 0, y: 0, width: 860, height: 660),
      styleMask: [.titled, .closable, .miniaturizable],
      backing: .buffered,
      defer: false
    )
    super.init(window: settingsWindow)
    settingsWindow.title = "ペースト設定"
    settingsWindow.isReleasedWhenClosed = false
    settingsWindow.level = .normal
    settingsWindow.delegate = self
    configureContent()
    showSelection()
  }

  var onClose: (() -> Void)?
  var onFocusChange: ((Bool) -> Void)?
  private var hasShown = false

  required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

  func show() {
    if !hasShown {
      settingsWindow.center()
      hasShown = true
    }
    if settingsWindow.isMiniaturized { settingsWindow.deminiaturize(nil) }
    NSApp.activate(ignoringOtherApps: false)
    settingsWindow.makeKeyAndOrderFront(nil)
  }

  func windowDidBecomeKey(_ notification: Notification) {
    onFocusChange?(true)
  }

  func windowDidResignKey(_ notification: Notification) {
    onFocusChange?(false)
  }

  func windowWillClose(_ notification: Notification) {
    onClose?()
  }

  private func configureContent() {
    guard let content = settingsWindow.contentView else { return }
    let sidebar = sidebarStack
    sidebar.orientation = .vertical
    sidebar.distribution = .fill
    sidebar.alignment = .leading
    sidebar.spacing = 6
    sidebar.edgeInsets = NSEdgeInsets(top: 12, left: 12, bottom: 12, right: 12)
    sidebarHeading.font = .systemFont(ofSize: 12, weight: .semibold)
    sidebarHeading.textColor = .secondaryLabelColor
    sidebar.addArrangedSubview(sidebarHeading)
    rebuildRows()
    let sidebarScroll = NSScrollView()
    sidebarScroll.drawsBackground = false
    sidebarScroll.hasVerticalScroller = true
    sidebarScroll.autohidesScrollers = true
    sidebarScroll.documentView = sidebar
    sidebar.translatesAutoresizingMaskIntoConstraints = false
    sidebar.widthAnchor.constraint(equalTo: sidebarScroll.contentView.widthAnchor).isActive = true
    sidebarHeight = sidebar.heightAnchor.constraint(equalToConstant: CGFloat(42 + drafts.count * 64))
    sidebarHeight?.isActive = true
    let sidebarBox = NSBox()
    sidebarBox.boxType = .custom
    sidebarBox.borderWidth = 0
    sidebarBox.cornerRadius = 10
    sidebarBox.fillColor = .controlBackgroundColor
    sidebarBox.contentViewMargins = .zero
    sidebarBox.contentView = sidebarScroll
    sidebarBox.widthAnchor.constraint(equalToConstant: 244).isActive = true
    let addButton = NSButton(title: "＋ 追加", target: self, action: #selector(addSnippet))
    addButton.bezelStyle = .rounded
    deleteButton.title = "削除"
    deleteButton.target = self
    deleteButton.action = #selector(deleteSnippet)
    deleteButton.bezelStyle = .rounded
    let listActions = NSStackView(views: [addButton, deleteButton])
    listActions.orientation = .horizontal
    listActions.distribution = .fillEqually
    listActions.spacing = 8
    let sidebarGroup = stack([sidebarBox, listActions], spacing: 12)
    sidebarGroup.widthAnchor.constraint(equalToConstant: 244).isActive = true

    nameField.placeholderString = "例：コードレビュー"
    nameField.heightAnchor.constraint(equalToConstant: 30).isActive = true
    keyRecorder.heightAnchor.constraint(equalToConstant: 30).isActive = true
    keyRecorder.onRecord = { [weak self] key, modifiers in
      guard let self else { return }
      if !modifiers.isEmpty {
        for (modifier, button) in modifierButtons {
          button.state = modifiers.contains(modifier) ? .on : .off
        }
      }
      errorLabel.stringValue = ""
      updateShortcutHelp()
    }
    let nameGroup = stack([label("表示名", size: 12, weight: .semibold), nameField], spacing: 8)
    let hotKeyGroup = stack([label("ショートカットのキー", size: 12, weight: .semibold), keyRecorder], spacing: 8)
    hotKeyGroup.widthAnchor.constraint(equalToConstant: 174).isActive = true
    let fields = NSStackView(views: [nameGroup, hotKeyGroup])
    fields.orientation = .horizontal
    fields.distribution = .fill
    fields.alignment = .top
    fields.spacing = 16
    nameGroup.widthAnchor.constraint(equalTo: fields.widthAnchor, constant: -190).isActive = true

    let modifierRow = NSStackView()
    modifierRow.orientation = .horizontal
    modifierRow.distribution = .fillEqually
    modifierRow.spacing = 8
    for (modifier, title) in [
      (HotKeyModifier.command, "⌘ Cmd"), (.option, "⌥ Option / Alt"),
      (.shift, "⇧ Shift"), (.control, "⌃ Control"),
    ] {
      let button = NSButton(checkboxWithTitle: title, target: self, action: #selector(modifiersChanged))
      button.font = .systemFont(ofSize: 12)
      modifierButtons[modifier] = button
      modifierRow.addArrangedSubview(button)
    }
    shortcutHelp.font = .systemFont(ofSize: 11)
    shortcutHelp.textColor = .secondaryLabelColor
    shortcutHelp.heightAnchor.constraint(equalToConstant: 30).isActive = true
    let shortcutOptions = stack([modifierRow, shortcutHelp], spacing: 6)

    modePicker.addItems(withTitles: PasteMode.allCases.map(\.title))
    modePicker.target = self
    modePicker.action = #selector(updatePasteMode)
    modeHelp.font = .systemFont(ofSize: 12)
    modeHelp.textColor = .secondaryLabelColor
    modeHelp.heightAnchor.constraint(equalToConstant: 34).isActive = true
    let modeGroup = stack([
      label("ショートカットを押したとき", size: 12, weight: .semibold), modePicker, modeHelp,
    ], spacing: 7)

    let bodyScroll = NSScrollView()
    bodyScroll.borderType = .bezelBorder
    bodyScroll.hasVerticalScroller = true
    bodyScroll.autohidesScrollers = true
    bodyScroll.documentView = bodyView
    bodyView.isRichText = false
    bodyView.frame = NSRect(x: 0, y: 0, width: 500, height: 190)
    bodyView.isAutomaticQuoteSubstitutionEnabled = false
    bodyView.isAutomaticDashSubstitutionEnabled = false
    bodyView.isAutomaticTextReplacementEnabled = false
    bodyView.isAutomaticSpellingCorrectionEnabled = false
    bodyView.font = .systemFont(ofSize: 14)
    bodyView.textContainerInset = NSSize(width: 12, height: 12)
    bodyView.isVerticallyResizable = true
    bodyView.isHorizontallyResizable = false
    bodyView.autoresizingMask = [.width]
    bodyView.textContainer?.widthTracksTextView = true
    bodyView.textContainer?.containerSize = NSSize(width: 500, height: CGFloat.greatestFiniteMagnitude)
    bodyView.delegate = self
    bodyScroll.heightAnchor.constraint(greaterThanOrEqualToConstant: 190).isActive = true
    bodyScroll.setContentHuggingPriority(.init(1), for: .vertical)
    characterCount.font = .systemFont(ofSize: 11)
    characterCount.textColor = .secondaryLabelColor
    errorLabel.font = .systemFont(ofSize: 12)
    errorLabel.textColor = .systemRed
    errorLabel.heightAnchor.constraint(equalToConstant: 38).isActive = true
    let editor = stack([
      fields, shortcutOptions, modeGroup, label("貼り付ける本文", size: 12, weight: .semibold),
      bodyScroll, characterCount, errorLabel,
    ], spacing: 12)
    let body = NSStackView(views: [sidebarGroup, editor])
    body.orientation = .horizontal
    body.distribution = .fill
    body.alignment = .top
    body.spacing = 24
    sidebarGroup.heightAnchor.constraint(equalTo: body.heightAnchor).isActive = true
    editor.heightAnchor.constraint(equalTo: body.heightAnchor).isActive = true
    editor.widthAnchor.constraint(equalTo: body.widthAnchor, constant: -268).isActive = true

    let separator = NSBox()
    separator.boxType = .separator
    let footnote = label("保存すると、ショートカットにもすぐ反映されます。", size: 11)
    footnote.textColor = .secondaryLabelColor
    let cancelButton = NSButton(title: "キャンセル", target: self, action: #selector(cancel(_:)))
    cancelButton.bezelStyle = .rounded
    cancelButton.keyEquivalent = "\u{1b}"
    let saveButton = NSButton(title: "保存", target: self, action: #selector(saveSettings))
    saveButton.bezelStyle = .rounded
    saveButton.keyEquivalent = "\r"
    let spacer = NSView()
    let footer = NSStackView(views: [footnote, spacer, cancelButton, saveButton])
    footer.orientation = .horizontal
    footer.distribution = .fill
    footer.alignment = .centerY
    footer.spacing = 12
    spacer.setContentHuggingPriority(.init(1), for: .horizontal)
    let root = stack([body, separator, footer], spacing: 20)
    content.addSubview(root)
    root.translatesAutoresizingMaskIntoConstraints = false
    NSLayoutConstraint.activate([
      root.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 24),
      root.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -24),
      root.topAnchor.constraint(equalTo: content.topAnchor, constant: 24),
      root.bottomAnchor.constraint(equalTo: content.bottomAnchor, constant: -20),
    ])
    settingsWindow.initialFirstResponder = nameField
  }

  private func label(_ text: String, size: CGFloat, weight: NSFont.Weight = .regular) -> NSTextField {
    let field = NSTextField(labelWithString: text)
    field.font = .systemFont(ofSize: size, weight: weight)
    return field
  }

  private func stack(_ views: [NSView], spacing: CGFloat) -> NSStackView {
    let stack = NSStackView(views: views)
    stack.orientation = .vertical
    stack.distribution = .fill
    stack.alignment = .leading
    stack.spacing = spacing
    for view in views {
      view.translatesAutoresizingMaskIntoConstraints = false
      view.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
    }
    return stack
  }

  private func captureSelection() throws {
    guard drafts.indices.contains(selectedIndex) else { return }
    let hotKey: HotKey?
    if let key = keyRecorder.key {
      guard !selectedModifiers.isEmpty else {
        throw ShortcutInputError.modifierRequired
      }
      let value = HotKey(modifiers: selectedModifiers, key: key)
      hotKey = try HotKey.parse(value.description)
    } else {
      hotKey = nil
    }
    let original = drafts[selectedIndex]
    drafts[selectedIndex] = Snippet(
      id: original.id, label: nameField.stringValue, hotKey: hotKey,
      text: bodyView.string, pasteMode: PasteMode.allCases[modePicker.indexOfSelectedItem]
    )
  }

  private func showSelection() {
    let hasSelection = drafts.indices.contains(selectedIndex)
    nameField.isEnabled = hasSelection
    keyRecorder.isEnabled = hasSelection
    for button in modifierButtons.values { button.isEnabled = hasSelection }
    modePicker.isEnabled = hasSelection
    bodyView.isEditable = hasSelection
    deleteButton.isEnabled = hasSelection
    updateRows()
    guard hasSelection else {
      nameField.stringValue = ""
      keyRecorder.key = nil
      bodyView.string = ""
      modeHelp.stringValue = "「＋ 追加」から定型文を登録してください。"
      updateCharacterCount()
      shortcutHelp.stringValue = ""
      return
    }
    let snippet = drafts[selectedIndex]
    nameField.stringValue = snippet.label
    keyRecorder.key = snippet.hotKey?.key
    let modifiers = snippet.hotKey?.modifiers ?? [.command, .option]
    for (modifier, button) in modifierButtons {
      button.state = modifiers.contains(modifier) ? .on : .off
    }
    updateShortcutHelp()
    bodyView.string = snippet.text
    modePicker.selectItem(at: PasteMode.allCases.firstIndex(of: snippet.pasteMode) ?? 0)
    updatePasteMode()
    updateCharacterCount()
  }

  private func rebuildRows() {
    for button in rowButtons {
      sidebarStack.removeArrangedSubview(button)
      button.removeFromSuperview()
    }
    rowButtons = drafts.indices.map { index in
      let button = SnippetRowButton(target: self, action: #selector(selectSnippet(_:)))
      button.tag = index
      button.setButtonType(.pushOnPushOff)
      sidebarStack.addArrangedSubview(button)
      button.widthAnchor.constraint(equalTo: sidebarStack.widthAnchor, constant: -24).isActive = true
      button.heightAnchor.constraint(equalToConstant: 58).isActive = true
      return button
    }
    sidebarHeight?.constant = CGFloat(42 + drafts.count * 64)
    updateRows()
  }

  private func updateRows() {
    sidebarHeading.stringValue = "定型文（\(drafts.count)件）"
    for (index, button) in rowButtons.enumerated() {
      let snippet = drafts[index]
      let shortcut = snippet.hotKey?.description ?? "メニューから実行"
      button.update(title: "\(index + 1)  \(snippet.label)", shortcut: shortcut, selected: index == selectedIndex)
      button.setAccessibilityLabel("\(snippet.label)、\(shortcut)")
    }
  }

  @objc private func addSnippet() {
    do {
      try captureSelection()
      drafts.append(Snippet(id: "snippet-\(UUID().uuidString.lowercased())", label: "新しい定型文", hotKey: nil, text: ""))
      selectedIndex = drafts.count - 1
      rebuildRows()
      errorLabel.stringValue = ""
      showSelection()
      sidebarStack.layoutSubtreeIfNeeded()
      rowButtons[selectedIndex].scrollToVisible(rowButtons[selectedIndex].bounds)
      settingsWindow.makeFirstResponder(nameField)
      nameField.selectText(nil)
    } catch {
      showError(error)
    }
  }

  @objc private func deleteSnippet() {
    guard drafts.indices.contains(selectedIndex) else { return }
    drafts.remove(at: selectedIndex)
    selectedIndex = max(0, min(selectedIndex, drafts.count - 1))
    rebuildRows()
    errorLabel.stringValue = ""
    showSelection()
  }

  @objc private func selectSnippet(_ sender: NSButton) {
    do {
      try captureSelection()
      selectedIndex = sender.tag
      errorLabel.stringValue = ""
      showSelection()
    } catch {
      showError(error)
      updateRows()
    }
  }

  @objc private func updatePasteMode() {
    modeHelp.stringValue = modePicker.indexOfSelectedItem == 0
      ? "入力中のアプリへ本文を貼り付けます。元のクリップボードは保持されます。"
      : "本文をクリップボードに保存します。好きなタイミングで⌘Vを押して貼り付けられます。"
  }

  private var selectedModifiers: Set<HotKeyModifier> {
    Set(modifierButtons.compactMap { $0.value.state == .on ? $0.key : nil })
  }

  @objc private func modifiersChanged() {
    errorLabel.stringValue = ""
    updateShortcutHelp()
  }

  private func updateShortcutHelp() {
    let shortcut = keyRecorder.key.map { HotKey(modifiers: selectedModifiers, key: $0).description }
    shortcutHelp.stringValue = (shortcut.map { "設定: \($0)" } ?? "ショートカットなし（メニューから実行）")
      + "\nキー欄を選んでキーを押してください。Deleteで解除できます。"
  }

  func textDidChange(_ notification: Notification) { updateCharacterCount() }

  private func updateCharacterCount() {
    characterCount.stringValue = "\(bodyView.string.count)文字 · 改行と空行はそのまま反映されます"
  }

  @objc private func saveSettings() {
    do {
      settingsWindow.makeFirstResponder(nil)
      try captureSelection()
      try save(drafts)
      settingsWindow.close()
    } catch {
      showError(error)
    }
  }

  @objc private func cancel(_ sender: Any?) {
    settingsWindow.close()
  }

  private func showError(_ error: Error) {
    if case SnippetError.emptyText(let id) = error,
      let snippet = drafts.first(where: { $0.id == id })
    {
      errorLabel.stringValue = "「\(snippet.label)」の本文を入力してください。"
    } else {
      errorLabel.stringValue = error.localizedDescription
    }
  }
}

private final class FlippedStackView: NSStackView {
  override var isFlipped: Bool { true }
}

@MainActor
final class ShortcutRecorderButton: NSButton {
  var key: String? {
    didSet {
      title = key ?? "クリックしてキーを入力"
      setAccessibilityValue(key ?? "未設定")
    }
  }
  var onRecord: ((String?, Set<HotKeyModifier>) -> Void)?

  init() {
    super.init(frame: .zero)
    bezelStyle = .rounded
    title = "クリックしてキーを入力"
    font = .monospacedSystemFont(ofSize: 12, weight: .medium)
    target = self
    action = #selector(startRecording)
    setAccessibilityLabel("ショートカットのキー。クリックしてキーを押すと登録できます")
    toolTip = "単独キー、またはCmd・Option・Shift・Controlとの組み合わせを押してください。"
  }

  required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

  override var acceptsFirstResponder: Bool { true }

  @objc private func startRecording() {
    window?.makeFirstResponder(self)
  }

  override func becomeFirstResponder() -> Bool {
    let result = super.becomeFirstResponder()
    if result { title = "キーを押してください…" }
    return result
  }

  override func resignFirstResponder() -> Bool {
    let result = super.resignFirstResponder()
    if result { title = key ?? "クリックしてキーを入力" }
    return result
  }

  override func performKeyEquivalent(with event: NSEvent) -> Bool {
    guard window?.firstResponder === self else {
      return super.performKeyEquivalent(with: event)
    }
    keyDown(with: event)
    return true
  }

  override func keyDown(with event: NSEvent) {
    var modifiers: Set<HotKeyModifier> = []
    if event.modifierFlags.contains(.command) { modifiers.insert(.command) }
    if event.modifierFlags.contains(.option) { modifiers.insert(.option) }
    if event.modifierFlags.contains(.shift) { modifiers.insert(.shift) }
    if event.modifierFlags.contains(.control) { modifiers.insert(.control) }
    if event.keyCode == 51 && modifiers.isEmpty {
      key = nil
      onRecord?(nil, [])
      return
    }
    guard let name = HotKeyManager.keyName(for: event.keyCode) else {
      NSSound.beep()
      return
    }
    key = name
    onRecord?(name, modifiers)
  }
}

private enum ShortcutInputError: LocalizedError {
  case modifierRequired

  var errorDescription: String? {
    "Cmd・Option・Shift・Controlのいずれかを選んでください。"
  }
}

@MainActor
private final class SnippetRowButton: NSButton {
  private let nameLabel = NSTextField(labelWithString: "")
  private let shortcutLabel = NSTextField(labelWithString: "")

  init(target: AnyObject, action: Selector) {
    super.init(frame: .zero)
    self.target = target
    self.action = action
    title = ""
    isBordered = false
    wantsLayer = true
    layer?.cornerRadius = 8
    nameLabel.font = .systemFont(ofSize: 13, weight: .medium)
    shortcutLabel.font = .monospacedSystemFont(ofSize: 11, weight: .regular)
    for label in [nameLabel, shortcutLabel] {
      label.lineBreakMode = .byTruncatingTail
      label.setAccessibilityElement(false)
      label.translatesAutoresizingMaskIntoConstraints = false
      addSubview(label)
      label.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 12).isActive = true
      label.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -12).isActive = true
    }
    nameLabel.topAnchor.constraint(equalTo: topAnchor, constant: 10).isActive = true
    shortcutLabel.topAnchor.constraint(equalTo: nameLabel.bottomAnchor, constant: 5).isActive = true
  }

  required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

  override func hitTest(_ point: NSPoint) -> NSView? {
    super.hitTest(point) == nil ? nil : self
  }

  func update(title: String, shortcut: String, selected: Bool) {
    nameLabel.stringValue = title
    shortcutLabel.stringValue = shortcut
    state = selected ? .on : .off
    layer?.backgroundColor = (selected ? NSColor.controlAccentColor : .clear).cgColor
    nameLabel.textColor = selected ? .white : .labelColor
    shortcutLabel.textColor = selected ? .white.withAlphaComponent(0.85) : .secondaryLabelColor
  }
}
