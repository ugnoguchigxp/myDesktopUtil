import AppKit
import DeskCore

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
  private let snippetStore = SnippetStore()
  private let pasteService = PasteService()
  private let hotKeyManager = HotKeyManager()
  private let alarmController = AlarmController()
  private lazy var alertCoordinator = AlertCoordinator(alarmController: alarmController)
  private let stateStore = JSONStateStore(fileURL: AppPaths.state)

  private var statusItem: NSStatusItem?
  private let menu = NSMenu()
  private var previousFrontmostApplication: NSRunningApplication?
  private var statusMessage = "起動中"
  private var alarmTimer: Timer?
  private var graphPollTimer: Timer?
  private var scheduleBook = AlarmScheduleBook()
  private var state = PersistedState()
  private var connectionConfiguration = ConnectionConfiguration()
  private var graphAuthService: GraphAuthService?
  private var graphSyncInProgress = false
  private var graphSyncTask: Task<Void, Never>?
  private var slackClient: SlackSocketClient?
  private var connectionGeneration = 0
  private var outlookStatus = "Outlook: 未設定"
  private var slackStatus = "Slack: 未設定"

  func applicationDidFinishLaunching(_ notification: Notification) {
    NSApp.setActivationPolicy(.accessory)
    state = stateStore.load()
    scheduleBook = AlarmScheduleBook(notifiedKeys: state.notifiedEventIDs)
    scheduleBook.applySnapshot(state.calendarEvents)

    snippetStore.load()
    configureStatusItem()
    configureAlertCoordinator()
    registerHotKeys()
    observeSystemEvents()
    fireDueAlerts(afterWake: false)
    configureConnections()
    handleDevelopmentArguments()
  }

  func applicationWillTerminate(_ notification: Notification) {
    alarmTimer?.invalidate()
    graphPollTimer?.invalidate()
    graphSyncTask?.cancel()
    hotKeyManager.shutdown()
    if let slackClient {
      Task {
        await slackClient.stop()
      }
    }
    persistState()
    NSWorkspace.shared.notificationCenter.removeObserver(self)
    NotificationCenter.default.removeObserver(self)
  }

  func menuWillOpen(_ menu: NSMenu) {
    let frontmost = NSWorkspace.shared.frontmostApplication
    if frontmost?.bundleIdentifier != AppIdentity.bundleIdentifier {
      previousFrontmostApplication = frontmost
    }
    rebuildMenu()
  }

  private func configureStatusItem() {
    let statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
    if let button = statusItem.button {
      button.image = NSImage(
        systemSymbolName: "bell.badge",
        accessibilityDescription: AppIdentity.name
      )
      button.toolTip = AppIdentity.name
    }
    menu.delegate = self
    statusItem.menu = menu
    self.statusItem = statusItem
    rebuildMenu()
  }

  private func configureAlertCoordinator() {
    alertCoordinator.onAcknowledged = { [weak self] _ in
      self?.fireDueAlerts(afterWake: false)
    }
    alertCoordinator.onQueueOverflow = { [weak self] in
      self?.statusMessage = "アラーム待ちキューが上限に達しました"
      self?.rebuildMenu()
    }
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
    menu.addItem(makeMenuItem("定型文ファイルを開く", action: #selector(openSnippets)))
    menu.addItem(makeMenuItem("定型文を再読み込み", action: #selector(reloadSnippets)))
    menu.addItem(makeMenuItem("アラームテスト", action: #selector(showAlarmTest)))
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

    let outlook = NSMenuItem(title: outlookStatus, action: nil, keyEquivalent: "")
    outlook.isEnabled = false
    menu.addItem(outlook)
    let slack = NSMenuItem(title: slackStatus, action: nil, keyEquivalent: "")
    slack.isEnabled = false
    menu.addItem(slack)
    menu.addItem(
      makeMenuItem("接続設定ファイルを開く", action: #selector(openConnections))
    )
    if connectionConfiguration.microsoft?.clientID.isEmpty == false {
      menu.addItem(
        makeMenuItem("Outlookにサインイン", action: #selector(signInToOutlook))
      )
    }
    menu.addItem(
      makeMenuItem("接続設定を再読み込み", action: #selector(reloadConnections))
    )
    menu.addItem(.separator())
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
  private func openSnippets() {
    NSWorkspace.shared.open(AppPaths.snippets)
  }

  @objc
  private func reloadSnippets() {
    snippetStore.load()
    registerHotKeys()
  }

  @objc
  private func openConnections() {
    NSWorkspace.shared.open(AppPaths.connections)
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
  private func reloadConnections() {
    configureConnections()
  }

  @objc
  private func signInToOutlook() {
    guard let graphAuthService else {
      outlookStatus = "Outlook: Client ID未設定"
      rebuildMenu()
      return
    }
    outlookStatus = "Outlook: サインイン中"
    rebuildMenu()
    let generation = connectionGeneration
    Task { [weak self] in
      guard let self else {
        return
      }
      do {
        _ = try await graphAuthService.signIn()
        guard generation == connectionGeneration else {
          return
        }
        outlookStatus = "Outlook: サインイン済み"
        synchronizeGraph(forceFull: true)
      } catch {
        guard generation == connectionGeneration else {
          return
        }
        outlookStatus = "Outlook: サインイン失敗"
        statusMessage = error.localizedDescription
        rebuildMenu()
      }
    }
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
  private func showAlarmTest() {
    alertCoordinator.enqueue(
      Alert(
        id: "test-\(UUID().uuidString)",
        source: .test,
        title: "Desk Agent アラームテスト",
        body: "前面カード、ベル、音、クリック停止を確認してください"
      )
    )
  }

  @objc
  private func terminate() {
    NSApp.terminate(nil)
  }

  private func observeSystemEvents() {
    NSWorkspace.shared.notificationCenter.addObserver(
      self,
      selector: #selector(didWake),
      name: NSWorkspace.didWakeNotification,
      object: nil
    )
    NotificationCenter.default.addObserver(
      self,
      selector: #selector(systemClockChanged),
      name: .NSSystemClockDidChange,
      object: nil
    )
  }

  @objc
  private func didWake() {
    fireDueAlerts(afterWake: true)
    synchronizeGraph()
  }

  @objc
  private func systemClockChanged() {
    fireDueAlerts(afterWake: false)
  }

  @objc
  private func alarmTimerFired() {
    fireDueAlerts(afterWake: false)
  }

  private func fireDueAlerts(afterWake: Bool) {
    for alert in scheduleBook.dueAlerts(at: Date(), afterWake: afterWake) {
      if !alertCoordinator.enqueue(alert) {
        scheduleBook.retryNotification(key: alert.id)
      }
    }
    state.notifiedEventIDs = scheduleBook.persistedNotifiedKeys
    persistState()
    rescheduleAlarmTimer()
  }

  private func rescheduleAlarmTimer() {
    alarmTimer?.invalidate()
    alarmTimer = nil
    guard let deadline = scheduleBook.nextDeadline(after: Date()) else {
      return
    }
    let timer = Timer(
      fireAt: deadline,
      interval: 0,
      target: self,
      selector: #selector(alarmTimerFired),
      userInfo: nil,
      repeats: false
    )
    timer.tolerance = 0.5
    RunLoop.main.add(timer, forMode: .common)
    alarmTimer = timer
  }

  private func applyCalendarEvents(_ events: [OutlookEvent]) {
    state.calendarEvents = Array(events.prefix(DeskLimits.maxCalendarEvents))
    state.enforceLimits()
    scheduleBook.applySnapshot(state.calendarEvents)
    fireDueAlerts(afterWake: false)
  }

  private func configureConnections() {
    connectionGeneration &+= 1
    graphSyncTask?.cancel()
    graphSyncTask = nil
    graphSyncInProgress = false
    graphPollTimer?.invalidate()
    graphPollTimer = nil
    if let slackClient {
      Task {
        await slackClient.stop()
      }
    }
    slackClient = nil

    connectionConfiguration = ConnectionConfiguration.loadOrCreate()
    configureGraph()
    configureSlack()
    rebuildMenu()
  }

  private func configureGraph() {
    guard let microsoft = connectionConfiguration.microsoft,
      !microsoft.clientID.isEmpty
    else {
      graphAuthService = nil
      outlookStatus = "Outlook: Client ID未設定"
      return
    }

    graphAuthService = GraphAuthService(configuration: microsoft)
    outlookStatus = "Outlook: 接続確認中"
    let timer = Timer(
      timeInterval: TimeInterval(connectionConfiguration.graphPollSeconds),
      target: self,
      selector: #selector(graphPollTimerFired),
      userInfo: nil,
      repeats: true
    )
    timer.tolerance = 10
    RunLoop.main.add(timer, forMode: .common)
    graphPollTimer = timer
    synchronizeGraph()
  }

  @objc
  private func graphPollTimerFired() {
    synchronizeGraph()
  }

  private func synchronizeGraph(forceFull: Bool = false) {
    guard !graphSyncInProgress, let graphAuthService else {
      return
    }
    graphSyncInProgress = true
    outlookStatus = "Outlook: 同期中"
    rebuildMenu()

    let savedState = state
    let generation = connectionGeneration
    graphSyncTask = Task { [weak self] in
      guard let self else {
        return
      }
      defer {
        if generation == connectionGeneration {
          graphSyncInProgress = false
          graphSyncTask = nil
          rebuildMenu()
        }
      }
      do {
        var token = try await graphAuthService.validAccessToken()
        let result: GraphSyncResult
        do {
          result = try await requestGraphSync(
            accessToken: token,
            savedState: savedState,
            forceFull: forceFull
          )
        } catch GraphIntegrationError.httpStatus(401) {
          try graphAuthService.invalidateAccessToken()
          token = try await graphAuthService.validAccessToken()
          result = try await requestGraphSync(
            accessToken: token,
            savedState: savedState,
            forceFull: forceFull
          )
        }
        guard !Task.isCancelled, generation == connectionGeneration else {
          return
        }
        applyGraphSyncResult(result)
        outlookStatus = "Outlook: 接続済み"
      } catch GraphIntegrationError.signInFailed {
        guard !Task.isCancelled, generation == connectionGeneration else {
          return
        }
        outlookStatus = "Outlook: サインインが必要"
      } catch {
        guard !Task.isCancelled, generation == connectionGeneration else {
          return
        }
        outlookStatus = "Outlook: 同期失敗"
        statusMessage = error.localizedDescription
      }
    }
  }

  private func requestGraphSync(
    accessToken: String,
    savedState: PersistedState,
    forceFull: Bool
  ) async throws -> GraphSyncResult {
    do {
      return try await GraphClient().synchronize(
        accessToken: accessToken,
        savedDeltaLink: savedState.graphDeltaLink,
        savedWindowStart: savedState.graphWindowStart,
        savedWindowEnd: savedState.graphWindowEnd,
        forceFullSync: forceFull
      )
    } catch GraphIntegrationError.deltaExpired {
      return try await GraphClient().synchronize(
        accessToken: accessToken,
        savedDeltaLink: nil,
        savedWindowStart: nil,
        savedWindowEnd: nil,
        forceFullSync: true
      )
    }
  }

  private func applyGraphSyncResult(_ result: GraphSyncResult) {
    var eventsByID: [String: OutlookEvent] = [:]
    if !result.isFullSync {
      for event in state.calendarEvents {
        eventsByID[event.id] = event
      }
    }

    for eventID in result.removedEventIDs {
      eventsByID.removeValue(forKey: eventID)
    }
    for event in result.events {
      if event.isAlarmEligible {
        eventsByID[event.id] = event
      } else {
        eventsByID.removeValue(forKey: event.id)
      }
    }

    state.calendarEvents = Array(
      eventsByID.values
        .sorted { ($0.startAt ?? .distantFuture) < ($1.startAt ?? .distantFuture) }
        .prefix(DeskLimits.maxCalendarEvents)
    )
    state.graphDeltaLink = result.deltaLink
    state.graphWindowStart = result.windowStart
    state.graphWindowEnd = result.windowEnd
    state.lastSuccessfulSync = Date()
    scheduleBook.applySnapshot(state.calendarEvents)
    fireDueAlerts(afterWake: false)
  }

  private func configureSlack() {
    let generation = connectionGeneration
    let keychain = KeychainStore()
    let appToken: String?
    let userToken: String?
    do {
      appToken = try keychain.read(.slackAppToken)
      userToken = try keychain.read(.slackUserToken)
    } catch {
      slackStatus = "Slack: Keychain読込失敗"
      statusMessage = error.localizedDescription
      return
    }
    guard let appToken, !appToken.isEmpty else {
      slackStatus = "Slack: app token未設定"
      return
    }
    let selfUserID = connectionConfiguration.slack?.selfUserID ?? ""
    let client = SlackSocketClient(
      appToken: appToken,
      userToken: userToken,
      selfUserID: selfUserID,
      existingRecentIDs: state.recentSlackEventIDs,
      onAlert: { [weak self] alert in
        Task { @MainActor in
          guard self?.connectionGeneration == generation else {
            return
          }
          self?.alertCoordinator.enqueue(alert)
        }
      },
      onStatus: { [weak self] status in
        Task { @MainActor in
          guard self?.connectionGeneration == generation else {
            return
          }
          self?.slackStatus = status
          self?.rebuildMenu()
        }
      },
      onRecentIDs: { [weak self] ids in
        Task { @MainActor in
          guard self?.connectionGeneration == generation else {
            return
          }
          self?.state.recentSlackEventIDs = ids
          self?.persistState()
        }
      }
    )
    slackClient = client
    slackStatus = "Slack: 接続開始"
    Task {
      await client.start()
    }
  }

  private func persistState() {
    state.notifiedEventIDs = scheduleBook.persistedNotifiedKeys
    do {
      try stateStore.save(state)
    } catch {
      statusMessage = "状態保存に失敗しました"
    }
  }

  private func handleDevelopmentArguments() {
    let rawArguments = Array(CommandLine.arguments.dropFirst())
    let arguments = Set(rawArguments)
    if arguments.contains("alarm-test") || arguments.contains("--alarm-test") {
      DispatchQueue.main.async { [weak self] in
        self?.showAlarmTest()
      }
    }
    if arguments.contains("--mock-outlook") {
      let start = Date().addingTimeInterval(120)
      applyCalendarEvents([
        OutlookEvent(
          id: "mock-outlook",
          title: "Mock Outlook Meeting",
          startAt: start,
          response: .accepted
        )
      ])
    }
    if arguments.contains("--mock-slack") {
      alertCoordinator.enqueue(
        Alert(
          id: "mock-slack-\(UUID().uuidString)",
          source: .slack,
          title: "Slack DM",
          body: "送信者: U_MOCK\nfixtureからの重要メッセージです"
        )
      )
    }
    if let path = argumentValue(after: "--outlook-fixture", in: rawArguments) {
      do {
        let data = try Data(
          contentsOf: URL(fileURLWithPath: path),
          options: [.mappedIfSafe]
        )
        let page = try GraphDeltaDecoder.decode(data)
        applyCalendarEvents(page.events)
        statusMessage = "Outlook fixtureを読み込みました"
      } catch {
        statusMessage = "Outlook fixture: \(error.localizedDescription)"
      }
    }
    if let path = argumentValue(after: "--slack-fixture", in: rawArguments) {
      do {
        let data = try Data(
          contentsOf: URL(fileURLWithPath: path),
          options: [.mappedIfSafe]
        )
        let configuredSelfUserID = connectionConfiguration.slack?.selfUserID ?? ""
        let selfUserID = configuredSelfUserID.isEmpty ? "U_SELF" : configuredSelfUserID
        let incoming = try SlackEventClassifier.classify(
          data,
          selfUserID: selfUserID
        )
        if let alert = incoming.alert {
          alertCoordinator.enqueue(alert)
        }
        statusMessage = "Slack fixtureを読み込みました"
      } catch {
        statusMessage = "Slack fixture: \(error.localizedDescription)"
      }
    }
  }

  private func argumentValue(after flag: String, in arguments: [String]) -> String? {
    guard let index = arguments.firstIndex(of: flag) else {
      return nil
    }
    let valueIndex = arguments.index(after: index)
    guard valueIndex < arguments.endIndex else {
      return nil
    }
    return arguments[valueIndex]
  }
}
