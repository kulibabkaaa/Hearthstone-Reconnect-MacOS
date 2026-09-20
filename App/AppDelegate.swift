import AppKit
import ServiceManagement
import Sparkle

final class AppDelegate: NSObject, NSApplicationDelegate {
  private let launchMode: AppLaunchMode
  private let hotKeyManager = GlobalHotKeyManager()
  private let autoLaunchController = AutoLaunchController()
  private let dockVisibilityController =
    DockVisibilityController()
  private let dockChangeCoordinator =
    DockVisibilityChangeCoordinator()
  private let systemExtensionController =
    SystemExtensionController()
  private let proxyController = TransparentProxyController()
  private let lobbyCoordinator = LobbyCoordinator()
  private let analyticsController = AnalyticsController()
  private let updaterController = SPUStandardUpdaterController(
    startingUpdater: false,
    updaterDelegate: nil,
    userDriverDelegate: nil
  )
  private lazy var appUninstaller = AppUninstaller(
    autoLaunchController: autoLaunchController,
    proxyController: proxyController,
    systemExtensionController: systemExtensionController
  )

  private var statusItem: NSStatusItem!
  private var reconnectMenuItem: NSMenuItem!
  private var windowController: SettingsWindowController!
  private var bugReportWindowController: BugReportWindowController?
  private var cooldownTimer: Timer?
  private var isRecordingShortcut = false
  private var isReconnectRunning = false
  private var isProxyReady = false
  private var userOpenedWindow = false
  private var isUninstalling = false
  private var isUninstallCleanupStarted = false
  private var isUpdaterStarted = false
  private var restoreAutoLaunchAfterFailedUninstall = false
  private var isAwaitingSystemExtensionApproval = false
  private var shouldPresentSystemExtensionApprovalReminder = false
  private var systemExtensionApprovalReminder =
    SystemExtensionApprovalReminder()

  private var launchedForHearthstone: Bool {
    launchMode.launchedForHearthstone
  }

  init(launchMode: AppLaunchMode) {
    self.launchMode = launchMode
    super.init()
  }

  func applicationDidFinishLaunching(
    _ notification: Notification
  ) {
    if launchMode.uninstallProcessIdentifier == nil {
      analyticsController.start()
    }
    registerDefaults()
    _ = dockVisibilityController.applyStoredPreference()
    autoLaunchController.synchronizeStoredState()
    buildMainMenu()
    buildMenuBar()
    buildWindow()
    configureSystemExtensionStatusHandlers()

    if let processIdentifier =
      launchMode.uninstallProcessIdentifier
    {
      showWindow()
      resumeUninstall(
        waitingForProcessIdentifier: processIdentifier
      )
    } else {
      startUpdaterIfNeeded()
      registerStoredHotKey()
      observeHearthstoneTermination()
      // Lobby capture is independent of the reconnect system extension. Start
      // it even while that extension is awaiting approval or cannot activate.
      lobbyCoordinator.start()
      prepareProxy()

      if !launchedForHearthstone {
        showWindow()
        switch autoLaunchController.configureDefaultIfNeeded() {
        case .success:
          break
        case .failure:
          windowController.setStatus(
            "Automatic opening couldn't be set up. Try again in Settings.",
            isError: true
          )
        }
        windowController.refresh()
      }

      updateReconnectAvailability()
      startCooldownTimerIfNeeded()
    }
  }

  func applicationShouldTerminateAfterLastWindowClosed(
    _ sender: NSApplication
  ) -> Bool {
    false
  }

  func applicationWillTerminate(_ notification: Notification) {
    analyticsController.flush()
    lobbyCoordinator.stop()
  }

  func applicationDidBecomeActive(
    _ notification: Notification
  ) {
    presentSystemExtensionApprovalReminderWhenPossible()
  }

  func applicationShouldHandleReopen(
    _ sender: NSApplication,
    hasVisibleWindows flag: Bool
  ) -> Bool {
    showWindow()
    return true
  }

  private func registerDefaults() {
    UserDefaults.standard.register(defaults: [
      DefaultsKey.keyCode:
        Int(AppConfiguration.defaultShortcutKeyCode),
      DefaultsKey.modifiers: Int(defaultCarbonModifiers()),
      DefaultsKey.hotkeyDisplay:
        AppConfiguration.defaultShortcutDisplay,
      DefaultsKey.openWithHearthstone:
        AppConfiguration.openWithHearthstoneByDefault,
      DefaultsKey.showInDock:
        AppConfiguration.showInDockByDefault,
      DefaultsKey.lastReconnectAt: 0.0,
      DefaultsKey.lobbyEnabled: true,
      DefaultsKey.lobbyOpacity: 100.0,
      DefaultsKey.lobbyShortcutKeyCode: Int(AppConfiguration.defaultLobbyShortcutKeyCode),
      DefaultsKey.lobbyShortcutModifiers: Int(defaultCarbonModifiers()),
      DefaultsKey.lobbyShortcutDisplay: AppConfiguration.defaultLobbyShortcutDisplay,
      DefaultsKey.lobbyScale: 1.0,
    ])
  }

  private func buildWindow() {
    windowController = SettingsWindowController(
      onReconnect: { [weak self] in
        self?.runReconnect()
      },
      onShortcutChanged: {
        [weak self] keyCode, modifiers, display in
        self?.changeShortcut(
          keyCode: keyCode,
          modifiers: modifiers,
          display: display
        ) ?? false
      },
      onShortcutRecordingChanged: { [weak self] recording in
        self?.setShortcutRecordingActive(recording)
      },
      onOpenWithHearthstoneChanged: { [weak self] enabled in
        self?.autoLaunchController.setEnabled(enabled)
          ?? .failure(AutoLaunchError.unavailable)
      },
      onShowInDockChanged: {
        [weak self] enabled, completion in
        guard let self else {
          completion(false)
          return
        }
        self.dockChangeCoordinator.submit(enabled) {
          [weak self] finalChoice in
          completion(
            self?.dockVisibilityController.setEnabled(
              finalChoice
            ) ?? false
          )
        }
      },
      onOpenSystemSettings: { [weak self] in
        self?.openSystemExtensionSettings()
      },
      onUninstall: { [weak self] in
        self?.confirmUninstall()
      },
      onLobbyEnabledChanged: { [weak self] enabled in
        guard let self else { return }
        self.lobbyCoordinator.setEnabled(enabled)
        self.hotKeyManager.unregister(action: .lobbyLayout)
        if enabled {
          self.registerStoredLobbyHotKey()
        }
      },
      onLobbyOpacityChanged: { [weak self] value in self?.lobbyCoordinator.setOpacity(value) },
      onLobbyShortcutChanged: { [weak self] key, modifiers, display in
        self?.changeLobbyShortcut(keyCode: key, modifiers: modifiers, display: display) ?? false
      },
      onResetLobby: { [weak self] in self?.lobbyCoordinator.resetLayout() },
      onRetryLobbySetup: { [weak self] in self?.lobbyCoordinator.retrySetup() },
      onReportBug: { [weak self] in self?.showBugReport() },
      onCheckForUpdates: { [weak self] in self?.checkForUpdates() },
      automaticUpdateChecksEnabled: { [weak self] in
        self?.updaterController.updater.automaticallyChecksForUpdates ?? true
      },
      onAutomaticUpdateChecksChanged: { [weak self] enabled in
        self?.updaterController.updater.automaticallyChecksForUpdates = enabled
      }
    )

    hotKeyManager.onHotKey = { [weak self] action in
      guard let self, !self.isRecordingShortcut else { return }
      switch action { case .reconnect: self.runReconnect(); case .lobbyLayout: self.lobbyCoordinator.toggleEditing() }
    }
    lobbyCoordinator.onStatus = { [weak self] status in
      self?.windowController.setLobbyStatus(
        status,
        canRetry: status == "Lobby setup needs approval"
      )
    }
    lobbyCoordinator.onLobbyDisplayed = { [weak self] in
      self?.analyticsController.signal(.lobbyDisplayed)
    }
  }

  private func buildMainMenu() {
    let mainMenu = NSMenu()
    let appMenuItem = NSMenuItem()
    mainMenu.addItem(appMenuItem)
    let appMenu = NSMenu()
    appMenu.addItem(
      NSMenuItem(
        title: "Check for Updates…",
        action: #selector(checkForUpdates),
        keyEquivalent: ""
      )
    )
    appMenu.addItem(.separator())
    appMenu.addItem(
      NSMenuItem(
        title: "Quit \(AppConfiguration.appName)",
        action: #selector(menuQuit),
        keyEquivalent: "q"
      )
    )
    appMenuItem.submenu = appMenu
    NSApp.mainMenu = mainMenu
  }

  private func buildMenuBar() {
    statusItem = NSStatusBar.system.statusItem(
      withLength: NSStatusItem.squareLength
    )
    if let image = NSImage(
      systemSymbolName: "arrow.triangle.2.circlepath",
      accessibilityDescription: AppConfiguration.appName
    ) {
      image.isTemplate = true
      statusItem.button?.image = image
    } else {
      statusItem.button?.title = "HS"
    }
    statusItem.button?.toolTip = AppConfiguration.appName

    let menu = NSMenu()
    reconnectMenuItem = NSMenuItem(
      title: "Reconnect",
      action: #selector(menuReconnect),
      keyEquivalent: ""
    )
    menu.addItem(reconnectMenuItem)
    menu.addItem(
      NSMenuItem(
        title: "Open Window",
        action: #selector(menuOpenWindow),
        keyEquivalent: ""
      )
    )
    menu.addItem(
      NSMenuItem(
        title: "Check for Updates…",
        action: #selector(checkForUpdates),
        keyEquivalent: ""
      )
    )
    menu.addItem(.separator())
    menu.addItem(
      NSMenuItem(
        title: "Quit",
        action: #selector(menuQuit),
        keyEquivalent: "q"
      )
    )
    statusItem.menu = menu
  }

  @objc private func checkForUpdates() {
    guard !isUninstalling, isUpdaterStarted else { return }
    userOpenedWindow = true
    updaterController.checkForUpdates(nil)
  }

  private func startUpdaterIfNeeded() {
    guard !isUpdaterStarted else { return }
    updaterController.startUpdater()
    isUpdaterStarted = true
  }

  private func showBugReport() {
    userOpenedWindow = true
    if bugReportWindowController == nil {
      bugReportWindowController = BugReportWindowController()
    }
    bugReportWindowController?.present()
  }

  private func configureSystemExtensionStatusHandlers() {
    systemExtensionController.onApprovalRequired = {
      [weak self] in
      self?.handleSystemExtensionApprovalRequired()
    }
    systemExtensionController.onDeactivationApprovalRequired = {
      [weak self] in
      self?.windowController.setStatus(
        "Approve removing HS Reconnect in System Settings, then return here."
      )
    }
  }

  private func handleSystemExtensionApprovalRequired() {
    isAwaitingSystemExtensionApproval = true
    windowController.setSystemExtensionApprovalRequired(true)
    windowController.setStatus(
      "In Extensions, open Network Extensions and allow HS Reconnect."
    )

    let hasSeenSystemPromptBefore =
      UserDefaults.standard.bool(
        forKey:
          DefaultsKey.hasSeenSystemExtensionApprovalPrompt
      )
    UserDefaults.standard.set(
      true,
      forKey:
        DefaultsKey.hasSeenSystemExtensionApprovalPrompt
    )

    guard
      systemExtensionApprovalReminder.shouldPresentAppReminder(
        hasSeenSystemPromptBefore: hasSeenSystemPromptBefore
      )
    else {
      return
    }
    shouldPresentSystemExtensionApprovalReminder = true
    showWindow()
    presentSystemExtensionApprovalReminderWhenPossible()
  }

  private func presentSystemExtensionApprovalReminderWhenPossible() {
    guard
      isAwaitingSystemExtensionApproval,
      shouldPresentSystemExtensionApprovalReminder,
      !isUninstalling
    else {
      return
    }
    guard
      NSApp.isActive,
      NSApp.modalWindow == nil,
      let window = windowController.window,
      window.attachedSheet == nil
    else {
      return
    }

    shouldPresentSystemExtensionApprovalReminder = false
    let alert = NSAlert()
    alert.alertStyle = .informational
    alert.messageText = "Finish setting up HS Reconnect"
    alert.informativeText =
      "Allow HS Reconnect under Network Extensions in System Settings."
    alert.addButton(withTitle: "Open System Settings")
    alert.addButton(withTitle: "Not Now")
    alert.beginSheetModal(for: window) { [weak self] response in
      guard response == .alertFirstButtonReturn else {
        return
      }
      self?.openSystemExtensionSettings()
    }
  }

  private func openSystemExtensionSettings() {
    SMAppService.openSystemSettingsLoginItems()
  }

  private func prepareProxy() {
    isProxyReady = false
    windowController.setStatus(
      "Getting ready…"
    )
    systemExtensionController.activate { [weak self] result in
      guard let self else { return }
      guard !self.isUninstalling else { return }
      switch result {
      case .failure:
        self.windowController.setStatus(
          self.activationFailureMessage(),
          isError: true
        )
      case .success(.requiresReboot):
        self.isAwaitingSystemExtensionApproval = false
        self.shouldPresentSystemExtensionApprovalReminder = false
        self.windowController
          .setSystemExtensionApprovalRequired(false)
        self.windowController.setStatus(
          "Restart your Mac once, then open HS Reconnect again."
        )
      case .success(.activated):
        self.isAwaitingSystemExtensionApproval = false
        self.shouldPresentSystemExtensionApprovalReminder = false
        self.windowController
          .setSystemExtensionApprovalRequired(false)
        self.proxyController.prepare { [weak self] prepareResult in
          guard let self else { return }
          if self.isUninstalling {
            return
          }
          switch prepareResult {
          case .success:
            self.isProxyReady = true
            self.windowController.setStatus(
              "Ready. Start a Battlegrounds game."
            )
          case .failure:
            self.windowController.setStatus(
              "HS Reconnect couldn't start. Please try reopening the app.",
              isError: true
            )
          }
          self.updateReconnectAvailability()
        }
      }
    }
  }

  private func activationFailureMessage() -> String {
    if !Bundle.main.bundleURL.path.hasPrefix("/Applications/") {
      return
        "Move HS Reconnect to Applications, then open it again."
    }
    return
      "HS Reconnect couldn't be enabled. Please try reopening the app."
  }

  private func runReconnect() {
    guard isProxyReady else {
      windowController.setStatus(
        "The local proxy is still getting ready.",
        isError: true
      )
      return
    }
    guard !isReconnectRunning else {
      windowController.setStatus(
        "Reconnect is already in progress.",
        isError: true
      )
      return
    }

    let remaining = ReconnectCooldown.remaining(
      lastReconnectAt: UserDefaults.standard.double(
        forKey: DefaultsKey.lastReconnectAt
      ),
      now: Date().timeIntervalSince1970
    )
    guard remaining <= 0 else {
      windowController.setStatus(
        "Please wait \(Int(ceil(remaining))) seconds and try again.",
        isError: true
      )
      return
    }

    isReconnectRunning = true
    windowController.setStatus("Reconnecting…")
    updateReconnectAvailability()

    let target: ReconnectTarget
    do {
      target = try GameEndpointResolver().reconnectTarget()
    } catch {
      isReconnectRunning = false
      windowController.setStatus(
        "Start a Battlegrounds game and try again.",
        isError: true
      )
      updateReconnectAvailability()
      return
    }

    proxyController.reconnect(target: target) { [weak self] result in
      guard let self else { return }
      guard !self.isUninstalling else { return }
      self.isReconnectRunning = false
      switch result {
      case .failure:
        self.windowController.setStatus(
          "Reconnect couldn't be completed. Please try again.",
          isError: true
        )
      case .success(let response):
        if response.didCloseFlow {
          self.analyticsController.signal(.reconnectSucceeded)
          UserDefaults.standard.set(
            Date().timeIntervalSince1970,
            forKey: DefaultsKey.lastReconnectAt
          )
          self.windowController.setStatus(
            "Reconnect triggered."
          )
        } else {
          self.windowController.setStatus(
            "Start a Battlegrounds game and try again.",
            isError: true
          )
        }
      }
      self.updateReconnectAvailability()
    }
  }

  private func updateReconnectAvailability() {
    let remaining = ReconnectCooldown.remaining(
      lastReconnectAt: UserDefaults.standard.double(
        forKey: DefaultsKey.lastReconnectAt
      ),
      now: Date().timeIntervalSince1970
    )
    let enabled =
      isProxyReady && !isReconnectRunning && remaining <= 0
    reconnectMenuItem?.isEnabled = enabled
    windowController?.setReconnectEnabled(enabled)
  }

  private func startCooldownTimerIfNeeded() {
    guard cooldownTimer == nil else { return }
    cooldownTimer = Timer.scheduledTimer(
      withTimeInterval: 0.5,
      repeats: true
    ) { [weak self] _ in
      self?.updateReconnectAvailability()
    }
  }

  private func registerStoredHotKey() {
    let shortcut = storedShortcut(in: .standard)
    persistShortcut(shortcut)
    if hotKeyManager.register(
      keyCode: shortcut.keyCode,
      modifiers: shortcut.modifiers
    ) != noErr {
      windowController?.setStatus(
        "That shortcut is already in use. Choose another one.",
        isError: true
      )
    }
    hotKeyManager.unregister(action: .lobbyLayout)
    if UserDefaults.standard.bool(forKey: DefaultsKey.lobbyEnabled) {
      registerStoredLobbyHotKey()
    }
  }

  private func registerStoredLobbyHotKey() {
    let key = UInt32(clamping: UserDefaults.standard.integer(forKey: DefaultsKey.lobbyShortcutKeyCode))
    let modifiers = UInt32(clamping: UserDefaults.standard.integer(forKey: DefaultsKey.lobbyShortcutModifiers))
    if hotKeyManager.register(action: .lobbyLayout, keyCode: key, modifiers: modifiers) != noErr {
      windowController?.setStatus("Lobby shortcut is already in use. Choose another one.", isError: true)
    }
  }

  private func setShortcutRecordingActive(_ recording: Bool) {
    if recording {
      isRecordingShortcut = true
      hotKeyManager.unregister()
    } else {
      registerStoredHotKey()
      isRecordingShortcut = false
    }
  }

  private func changeShortcut(
    keyCode: UInt32,
    modifiers: UInt32,
    display: String
  ) -> Bool {
    guard
      shortcutValidationMessage(
        keyCode: keyCode,
        modifiers: modifiers
      ) == nil
    else {
      return false
    }
    let lobbyKey = UInt32(clamping: UserDefaults.standard.integer(forKey: DefaultsKey.lobbyShortcutKeyCode))
    let lobbyModifiers = UInt32(clamping: UserDefaults.standard.integer(forKey: DefaultsKey.lobbyShortcutModifiers))
    guard keyCode != lobbyKey || modifiers != lobbyModifiers else { return false }

    let previous = storedShortcut(in: .standard)
    let status = hotKeyManager.register(
      keyCode: keyCode,
      modifiers: modifiers
    )
    guard status == noErr else {
      _ = hotKeyManager.register(
        keyCode: previous.keyCode,
        modifiers: previous.modifiers
      )
      return false
    }

    persistShortcut(
      StoredShortcut(
        keyCode: keyCode,
        modifiers: modifiers,
        display: display
      )
    )
    return true
  }

  private func changeLobbyShortcut(keyCode: UInt32, modifiers: UInt32, display: String) -> Bool {
    guard shortcutValidationMessage(keyCode: keyCode, modifiers: modifiers) == nil else { return false }
    let reconnect = storedShortcut(in: .standard)
    guard keyCode != reconnect.keyCode || modifiers != reconnect.modifiers else { return false }
    if UserDefaults.standard.bool(forKey: DefaultsKey.lobbyEnabled) {
      let oldKey = UInt32(clamping: UserDefaults.standard.integer(forKey: DefaultsKey.lobbyShortcutKeyCode))
      let oldModifiers = UInt32(clamping: UserDefaults.standard.integer(forKey: DefaultsKey.lobbyShortcutModifiers))
      let status = hotKeyManager.register(action: .lobbyLayout, keyCode: keyCode, modifiers: modifiers)
      guard status == noErr else {
        _ = hotKeyManager.register(action: .lobbyLayout, keyCode: oldKey, modifiers: oldModifiers)
        return false
      }
    } else {
      hotKeyManager.unregister(action: .lobbyLayout)
    }
    UserDefaults.standard.set(Int(keyCode), forKey: DefaultsKey.lobbyShortcutKeyCode)
    UserDefaults.standard.set(Int(modifiers), forKey: DefaultsKey.lobbyShortcutModifiers)
    UserDefaults.standard.set(display, forKey: DefaultsKey.lobbyShortcutDisplay)
    return true
  }

  private func persistShortcut(_ shortcut: StoredShortcut) {
    UserDefaults.standard.set(
      Int(shortcut.keyCode),
      forKey: DefaultsKey.keyCode
    )
    UserDefaults.standard.set(
      Int(shortcut.modifiers),
      forKey: DefaultsKey.modifiers
    )
    UserDefaults.standard.set(
      shortcut.display,
      forKey: DefaultsKey.hotkeyDisplay
    )
  }

  private func observeHearthstoneTermination() {
    NSWorkspace.shared.notificationCenter.addObserver(
      forName: NSWorkspace.didTerminateApplicationNotification,
      object: nil,
      queue: .main
    ) { [weak self] notification in
      guard let self,
        let application = notification.userInfo?[
          NSWorkspace.applicationUserInfoKey
        ] as? NSRunningApplication,
        application.bundleIdentifier
          == ProxyConstants.hearthstoneSigningIdentifier,
        self.launchedForHearthstone,
        !self.userOpenedWindow
      else {
        return
      }
      NSApp.terminate(nil)
    }
  }

  private func showWindow() {
    userOpenedWindow = true
    windowController.showWindow(nil)
    windowController.window?.makeKeyAndOrderFront(nil)
    NSApp.activate(ignoringOtherApps: true)
    windowController.refresh()
    presentSystemExtensionApprovalReminderWhenPossible()
  }

  private func confirmUninstall() {
    guard !isUninstalling else { return }

    let alert = NSAlert()
    alert.alertStyle = .warning
    alert.messageText = "Uninstall HS Reconnect?"
    alert.informativeText =
      "This removes HS Reconnect, its network extension, settings, and Desktop shortcut."
    alert.addButton(withTitle: "Uninstall")
    alert.addButton(withTitle: "Cancel")
    alert.buttons.first?.hasDestructiveAction = true

    guard alert.runModal() == .alertFirstButtonReturn else {
      return
    }

    let proxyWasReady = isProxyReady
    isUninstalling = true
    isUninstallCleanupStarted = false
    isProxyReady = false
    hotKeyManager.unregister()
    lobbyCoordinator.stop()
    windowController.setUninstalling(true)
    windowController.setStatus(
      "Preparing to uninstall HS Reconnect…"
    )
    updateReconnectAvailability()

    let configuration = NSWorkspace.OpenConfiguration()
    configuration.arguments = [
      AppLaunchMode.resumeUninstallArgument,
      String(ProcessInfo.processInfo.processIdentifier),
    ]
    configuration.createsNewApplicationInstance = true
    configuration.activates = true

    NSWorkspace.shared.openApplication(
      at: Bundle.main.bundleURL,
      configuration: configuration
    ) { [weak self] _, error in
      DispatchQueue.main.async {
        guard let self else { return }
        if error == nil {
          NSApp.terminate(nil)
          return
        }

        self.isUninstalling = false
        self.isUninstallCleanupStarted = false
        self.isReconnectRunning = false
        self.isProxyReady = proxyWasReady
        self.registerStoredHotKey()
        self.lobbyCoordinator.start()
        self.windowController.setUninstalling(false)
        self.windowController.setStatus(
          "HS Reconnect couldn't begin uninstalling. Please try again.",
          isError: true
        )
        self.updateReconnectAvailability()
      }
    }
  }

  private func resumeUninstall(
    waitingForProcessIdentifier processIdentifier: Int32
  ) {
    isUninstalling = true
    isUninstallCleanupStarted = false
    restoreAutoLaunchAfterFailedUninstall =
      UserDefaults.standard.bool(
        forKey: DefaultsKey.openWithHearthstone
      )
    isProxyReady = false
    windowController.setUninstalling(true)
    windowController.setStatus("Uninstalling HS Reconnect…")
    updateReconnectAvailability()
    waitForOriginalProcessToExit(processIdentifier)
  }

  private func waitForOriginalProcessToExit(
    _ processIdentifier: Int32
  ) {
    let originalApplication = NSRunningApplication(
      processIdentifier: processIdentifier
    )
    if let originalApplication,
      originalApplication.bundleIdentifier
        == AppConfiguration.bundleIdentifier,
      !originalApplication.isTerminated
    {
      DispatchQueue.main.asyncAfter(
        deadline: .now() + 0.1
      ) { [weak self] in
        self?.waitForOriginalProcessToExit(
          processIdentifier
        )
      }
      return
    }

    DispatchQueue.main.asyncAfter(
      deadline: .now() + 0.5
    ) { [weak self] in
      self?.beginUninstallCleanup()
    }
  }

  private func beginUninstallCleanup() {
    guard isUninstalling, !isUninstallCleanupStarted else {
      return
    }
    isUninstallCleanupStarted = true

    appUninstaller.uninstall { [weak self] result in
      guard let self else { return }
      switch result {
      case .success:
        NSApp.terminate(nil)
      case .failure(let error):
        self.isUninstalling = false
        self.isUninstallCleanupStarted = false
        self.isReconnectRunning = false
        let shouldRestoreRuntime =
          self.shouldRestoreRuntimeAfterFailedUninstall(error)
        if shouldRestoreRuntime {
          if self.restoreAutoLaunchAfterFailedUninstall {
            _ = self.autoLaunchController.setEnabled(true)
          }
          self.startUpdaterIfNeeded()
          self.registerStoredHotKey()
          self.lobbyCoordinator.start()
        }
        self.restoreAutoLaunchAfterFailedUninstall = false
        self.windowController.setUninstalling(false)
        self.windowController.setStatus(
          self.uninstallFailureMessage(error),
          isError: true
        )
        self.updateReconnectAvailability()
        if shouldRestoreRuntime {
          self.startCooldownTimerIfNeeded()
          self.prepareProxy()
        }
      }
    }
  }

  private func shouldRestoreRuntimeAfterFailedUninstall(
    _ error: Error
  ) -> Bool {
    guard let error = error as? AppUninstallerError else {
      return true
    }
    return AppUninstallRecoveryPolicy.shouldRestoreRuntime(
      after: error.failureStage
    )
  }

  private func uninstallFailureMessage(_ error: Error) -> String {
    if let error = error as? AppUninstallerError,
      case .notInstalledInApplications = error
    {
      return
        "Open the installed copy from Applications, then try again."
    }
    return "HS Reconnect couldn't be uninstalled. Please try again."
  }

  @objc private func menuReconnect() {
    runReconnect()
  }

  @objc private func menuOpenWindow() {
    showWindow()
  }

  @objc private func menuQuit() {
    NSApp.terminate(nil)
  }
}
