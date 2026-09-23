import AppKit
import NetworkExtension
import ServiceManagement
import Sparkle
import SystemExtensions

final class AppDelegate: NSObject, NSApplicationDelegate,
  SPUStandardUserDriverDelegate, SPUUpdaterDelegate
{
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
  private lazy var updaterController = SPUStandardUpdaterController(
    startingUpdater: false,
    updaterDelegate: self,
    userDriverDelegate: self
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
  private var transientStatusResetWorkItem: DispatchWorkItem?
  private var isRecordingShortcut = false
  private var isReconnectRunning = false
  private var isProxyReady = false
  private var userOpenedWindow = false
  private var isUninstalling = false
  private var isUninstallCleanupStarted = false
  private var isUpdaterStarted = false
  private var restoreAutoLaunchAfterFailedUninstall = false
  private var isAwaitingSystemExtensionApproval = false
  private var openExtensionSettingsAfterSetup = false
  private var isCheckingSystemExtensionState = false
  private var isPreparingProxy = false
  private var shouldPrepareProxyWhenAvailable = false
  private var proxyConnectionStatus: NEVPNStatus = .invalid
  private var systemExtensionActivationError: String?
  private var systemExtensionRequiresReboot = false
  private var systemExtensionApprovalWasDenied = false
  private var proxyConfigurationPermissionWasDenied = false
  private var proxyPreparationNeedsUserRetry = false
  private var hasCheckedProxyConfiguration = false
  private var hasSavedProxyConfiguration = false
  private var lastSystemExtensionState:
    SystemExtensionRuntimeState?

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
    restoreAutomaticLobbyCaptureIfNeeded()
    systemExtensionApprovalWasDenied = UserDefaults.standard.bool(
      forKey: DefaultsKey.systemExtensionApprovalWasDenied
    )
    proxyConfigurationPermissionWasDenied = UserDefaults.standard.bool(
      forKey: DefaultsKey.proxyConfigurationPermissionWasDenied
    )
    proxyPreparationNeedsUserRetry =
      proxyConfigurationPermissionWasDenied
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
      inspectExistingProxySetup()

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
    cooldownTimer?.invalidate()
    transientStatusResetWorkItem?.cancel()
    analyticsController.flush()
    lobbyCoordinator.stop()
  }

  func applicationDidBecomeActive(
    _ notification: Notification
  ) {
    if let state = lastSystemExtensionState,
      ReconnectSetupPolicy.shouldPrepareProxyAutomatically(
        extensionEnabled: state.isEnabled,
        proxyReady: isProxyReady,
        action: reconnectSetupAction(for: state)
      )
    {
      shouldPrepareProxyWhenAvailable = true
    }
    refreshSystemExtensionState()
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
      DefaultsKey.systemExtensionApprovalWasDenied: false,
      DefaultsKey.proxyConfigurationPermissionWasDenied: false,
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
      onRetrySystemExtensionApproval: { [weak self] in
        self?.retrySystemExtensionApproval()
      },
      onRetryProxySetup: { [weak self] in
        self?.retryProxySetup()
      },
      onBeginReconnectSetup: { [weak self] in
        self?.beginReconnectSetup()
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
        canRetry: status == "Lobby access needs approval"
          || status == "Lobby capture couldn't start"
      )
    }
    lobbyCoordinator.onLobbyDisplayed = { [weak self] in
      self?.analyticsController.signal(.lobbyDisplayed)
    }
  }

  private func restoreAutomaticLobbyCaptureIfNeeded() {
    let defaults = UserDefaults.standard
    guard let verified = defaults.object(forKey: DefaultsKey.lobbyAccessVerified)
      as? Bool else { return }
    // The button-gated build forcibly disabled lobby info before approval.
    // Restore the former automatic default once for people left in that state.
    if !verified {
      defaults.removeObject(forKey: DefaultsKey.lobbyEnabled)
    }
    defaults.removeObject(forKey: DefaultsKey.lobbyAccessVerified)
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
    if updaterController.updater.automaticallyChecksForUpdates {
      updaterController.updater.checkForUpdatesInBackground()
    }
  }

  func updater(
    _ updater: SPUUpdater,
    willInstallUpdateOnQuit item: SUAppcastItem,
    immediateInstallationBlock immediateInstallHandler:
      @escaping () -> Void
  ) -> Bool {
    DispatchQueue.main.async {
      immediateInstallHandler()
    }
    return true
  }

  func standardUserDriverWillHandleShowingUpdate(
    _ handleShowingUpdate: Bool,
    forUpdate update: SUAppcastItem,
    state: SPUUserUpdateState
  ) {
    guard handleShowingUpdate else { return }
    DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
      [weak self] in
      self?.hideSparkleSkipButton()
    }
  }

  private func hideSparkleSkipButton() {
    for window in NSApp.windows where window.title == "Software Update" {
      guard let contentView = window.contentView else { continue }
      _ = hideSparkleSkipButton(in: contentView)
    }
  }

  @discardableResult
  private func hideSparkleSkipButton(in view: NSView) -> Bool {
    if let button = view as? NSButton,
       button.identifier?.rawValue == "SPUUserUpdateChoiceSkip"
         || button.title == "Skip This Version"
    {
      button.isHidden = true
      return true
    }

    for subview in view.subviews where hideSparkleSkipButton(in: subview) {
      return true
    }
    return false
  }

  private func showBugReport() {
    userOpenedWindow = true
    if bugReportWindowController == nil {
      bugReportWindowController = BugReportWindowController()
    }
    bugReportWindowController?.present()
  }

  private func configureSystemExtensionStatusHandlers() {
    proxyController.onConnectionStatusChanged = {
      [weak self] status in
      guard let self else { return }
      let wasReady = self.isProxyReady
      self.proxyConnectionStatus = status
      self.recomputeProxyReadiness()
      if status != .connected {
        if wasReady {
          self.windowController.setStatus(
            "Checking the reconnect extension…"
          )
        }
        self.refreshSystemExtensionState()
      } else if !wasReady && self.isProxyReady {
        self.windowController.setStatus(
          "Ready. Start a Battlegrounds game."
        )
      }
    }
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
    showSystemExtensionEnablementHelp()
    showWindow()
  }

  private func showSystemExtensionEnablementHelp() {
    isAwaitingSystemExtensionApproval = true
    windowController.setStatus(
      "Reconnect is off. Open Network Extension Settings and turn on "
        + "HS Reconnect. If the list opens instead, choose By Category, "
        + "then Network Extensions."
    )
    windowController.setReconnectSetupAction(
      .openSystemExtensionSettings
    )
    guard openExtensionSettingsAfterSetup else { return }
    openExtensionSettingsAfterSetup = false
    DispatchQueue.main.async { [weak self] in
      guard let self, !self.isUninstalling,
        self.isAwaitingSystemExtensionApproval
      else { return }
      self.openSystemExtensionSettings()
    }
  }

  private func openSystemExtensionSettings() {
    if #available(macOS 15.0, *),
      let url = URL(string:
        "x-apple.systempreferences:com.apple.ExtensionsPreferences"
          + "?extensionPointIdentifier="
          + "com.apple.system_extension.network_extension.extension-point"
      ), NSWorkspace.shared.open(url)
    { return }
    SMAppService.openSystemSettingsLoginItems()
  }

  private func inspectExistingProxySetup() {
    proxyController.hasEnabledConfiguration { [weak self] result in
      guard let self, !self.isUninstalling else { return }
      self.hasCheckedProxyConfiguration = true
      switch result {
      case .success(let exists):
        self.hasSavedProxyConfiguration = exists
        self.shouldPrepareProxyWhenAvailable = exists
      case .failure(let error):
        NSLog("Could not inspect saved proxy configuration: %@", error as NSError)
        self.hasSavedProxyConfiguration = false
        self.shouldPrepareProxyWhenAvailable = false
      }
      self.refreshSystemExtensionState()
    }
  }

  private func beginReconnectSetup() {
    guard !isUninstalling, !isPreparingProxy,
      !systemExtensionController.isOperationPending
    else { return }
    windowController.setReconnectSetupAction(.none)
    windowController.setStatus("Getting ready…")
    openExtensionSettingsAfterSetup =
      lastSystemExtensionState?.isEnabled != true
    if lastSystemExtensionState?.isEnabled == true {
      finishPreparingProxy()
    } else {
      prepareProxy()
    }
  }

  private func prepareProxy() {
    isProxyReady = false
    systemExtensionActivationError = nil
    if systemExtensionApprovalWasDenied {
      shouldPrepareProxyWhenAvailable = false
      showSystemExtensionApprovalRetry()
      refreshSystemExtensionState()
      updateReconnectAvailability()
      return
    }
    shouldPrepareProxyWhenAvailable = true
    windowController.setStatus(
      "Getting ready…"
    )
    systemExtensionController.activate { [weak self] result in
      guard let self else { return }
      guard !self.isUninstalling else { return }
      switch result {
      case .failure(let error):
        self.openExtensionSettingsAfterSetup = false
        NSLog("System extension activation failed: %@", error as NSError)
        if Self.isSystemExtensionApprovalDenial(error) {
          self.systemExtensionApprovalWasDenied = true
          UserDefaults.standard.set(
            true,
            forKey: DefaultsKey.systemExtensionApprovalWasDenied
          )
          self.shouldPrepareProxyWhenAvailable = false
          self.showSystemExtensionApprovalRetry()
          self.updateReconnectAvailability()
          return
        }
        self.systemExtensionActivationError =
          "macOS couldn’t activate the reconnect extension. "
          + "Reinstall the latest verified installer. "
          + "If this continues, report a bug."
        if !Bundle.main.bundleURL.path.hasPrefix("/Applications/") {
          self.windowController.setStatus(
            "Move HS Reconnect to Applications, then open it again.",
            isError: true
          )
          self.windowController
            .setReconnectSetupAction(.none)
        } else {
          self.refreshSystemExtensionState()
        }
      case .success(.requiresReboot):
        self.openExtensionSettingsAfterSetup = false
        self.systemExtensionRequiresReboot = true
        self.shouldPrepareProxyWhenAvailable = false
        self.isProxyReady = false
        self.windowController
          .setReconnectSetupAction(.none)
        self.windowController.setStatus(
          "Restart your Mac to finish updating the reconnect extension.",
          isError: true
        )
        self.updateReconnectAvailability()
      case .success(.activated):
        self.openExtensionSettingsAfterSetup = false
        self.clearSystemExtensionApprovalDenial()
        self.systemExtensionRequiresReboot = false
        if self.proxyConfigurationPermissionWasDenied {
          self.showProxyConfigurationRetry()
          self.updateReconnectAvailability()
        } else {
          self.finishPreparingProxy()
        }
      }
    }
  }

  private func finishPreparingProxy(
    allowRecreateConfiguration: Bool = true
  ) {
    guard !isPreparingProxy else { return }
    shouldPrepareProxyWhenAvailable = false
    isPreparingProxy = true
    proxyController.prepare(
      allowRecreateConfiguration: allowRecreateConfiguration
    ) { [weak self] prepareResult in
      guard let self else { return }
      self.isPreparingProxy = false
      if self.isUninstalling {
        return
      }
      switch prepareResult {
      case .success:
        self.proxyConnectionStatus =
          self.proxyController.connectionStatus
        self.isAwaitingSystemExtensionApproval = false
        self.windowController
          .setReconnectSetupAction(.none)
        self.proxyConfigurationPermissionWasDenied = false
        self.proxyPreparationNeedsUserRetry = false
        self.hasSavedProxyConfiguration = true
        UserDefaults.standard.set(
          false,
          forKey: DefaultsKey.proxyConfigurationPermissionWasDenied
        )
        self.recomputeProxyReadiness()
        if self.isProxyReady {
          self.windowController.setStatus(
            "Ready. Start a Battlegrounds game."
          )
        }
      case .failure(let error):
        NSLog("Reconnect preparation failed: %@", error as NSError)
        self.shouldPrepareProxyWhenAvailable = false
        self.isProxyReady = false
        self.proxyPreparationNeedsUserRetry = true
        if error as? TransparentProxyControllerError
          == .configurationPermissionDenied
        {
          self.proxyConfigurationPermissionWasDenied = true
          UserDefaults.standard.set(
            true,
            forKey: DefaultsKey.proxyConfigurationPermissionWasDenied
          )
          self.showProxyConfigurationRetry()
        } else {
          self.windowController.setReconnectSetupAction(
            .retryProxySetup
          )
          self.windowController.setStatus(
            "Reconnect setup didn't finish. Click below to try again.",
            isError: true
          )
        }
      }
      self.updateReconnectAvailability()
    }
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
      showTemporaryMissingGameStatus()
      updateReconnectAvailability()
      return
    }

    proxyController.reconnect(target: target) { [weak self] result in
      guard let self else { return }
      guard !self.isUninstalling else { return }
      self.isReconnectRunning = false
      guard self.lastSystemExtensionState?.isEnabled == true,
        self.proxyConnectionStatus == .connected
      else {
        self.windowController.setStatus(
          "Checking the reconnect extension…"
        )
        self.refreshSystemExtensionState()
        self.updateReconnectAvailability()
        return
      }
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
          self.showTemporaryMissingGameStatus()
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

  private func showTemporaryMissingGameStatus() {
    let message = "Start a Battlegrounds game and try again."
    transientStatusResetWorkItem?.cancel()
    windowController.setStatus(message, isError: true)

    let reset = DispatchWorkItem { [weak self] in
      guard let self,
        self.isProxyReady,
        !self.isReconnectRunning,
        self.lastSystemExtensionState?.isEnabled == true,
        self.proxyConnectionStatus == .connected
      else { return }
      self.windowController.setStatus(
        "Ready. Start a Battlegrounds game.",
        ifCurrent: message
      )
    }
    transientStatusResetWorkItem = reset
    DispatchQueue.main.asyncAfter(
      deadline: .now() + 5,
      execute: reset
    )
  }

  private func startCooldownTimerIfNeeded() {
    guard cooldownTimer == nil else { return }
    cooldownTimer = Timer.scheduledTimer(
      withTimeInterval: 0.5,
      repeats: true
    ) { [weak self] _ in
      self?.updateReconnectAvailability()
      self?.refreshSystemExtensionState()
    }
  }

  private func refreshSystemExtensionState() {
    guard !isUninstalling,
      !isCheckingSystemExtensionState
    else { return }
    isCheckingSystemExtensionState = true
    systemExtensionController.currentState { [weak self] result in
      guard let self else { return }
      self.isCheckingSystemExtensionState = false
      guard !self.isUninstalling else { return }
      switch result {
      case .success(let state):
        self.applySystemExtensionState(state)
      case .failure(let error):
        NSLog(
          "System extension state check failed: %@",
          error as NSError
        )
        self.isProxyReady = false
        self.windowController.setStatus(
          "Reconnect status couldn't be checked. Please try again.",
          isError: true
        )
        self.updateReconnectAvailability()
      }
    }
  }

  private func applySystemExtensionState(
    _ state: SystemExtensionRuntimeState
  ) {
    let wasEnabled = lastSystemExtensionState?.isEnabled
    lastSystemExtensionState = state

    guard hasCheckedProxyConfiguration else { return }

    if systemExtensionRequiresReboot && !state.isEnabled {
      recomputeProxyReadiness()
      return
    }

    guard state.isEnabled else {
      if systemExtensionController.isOperationPending,
        !isAwaitingSystemExtensionApproval
      {
        updateReconnectAvailability()
        return
      }
      let action = reconnectSetupAction(for: state)
      if action == .retrySystemExtensionApproval {
        isProxyReady = false
        shouldPrepareProxyWhenAvailable = false
        showSystemExtensionApprovalRetry()
        updateReconnectAvailability()
        return
      }
      if let activationError = systemExtensionActivationError,
        !state.isAwaitingUserApproval
      {
        isProxyReady = false
        shouldPrepareProxyWhenAvailable = false
        windowController.setReconnectSetupAction(.none)
        windowController.setStatus(activationError, isError: true)
        updateReconnectAvailability()
        return
      }
      if state.isUnavailable && !systemExtensionController.isOperationPending {
        isProxyReady = false
        shouldPrepareProxyWhenAvailable = false
        showReconnectSetupHelp()
        updateReconnectAvailability()
        return
      }
      let needsUIUpdate =
        wasEnabled != false || isProxyReady
          || !isAwaitingSystemExtensionApproval
      isProxyReady = false
      shouldPrepareProxyWhenAvailable = true
      if needsUIUpdate {
        showSystemExtensionEnablementHelp()
      }
      updateReconnectAvailability()
      return
    }

    systemExtensionActivationError = nil
    clearSystemExtensionApprovalDenial()
    systemExtensionRequiresReboot = false
    isAwaitingSystemExtensionApproval = false
    let setupAction = reconnectSetupAction(for: state)
    windowController.setReconnectSetupAction(setupAction)
    if setupAction == .beginReconnectSetup {
      isProxyReady = false
      shouldPrepareProxyWhenAvailable = false
      if isPreparingProxy {
        windowController.setReconnectSetupAction(.none)
      } else {
        showReconnectSetupHelp()
      }
      updateReconnectAvailability()
      return
    }
    if setupAction == .retryProxyConfiguration {
      showProxyConfigurationRetry()
      recomputeProxyReadiness()
      return
    }
    if setupAction == .retryProxySetup {
      windowController.setStatus(
        "Reconnect setup didn't finish. Click below to try again.",
        isError: true
      )
      recomputeProxyReadiness()
      return
    }
    let wasReady = isProxyReady
    recomputeProxyReadiness()
    if !wasReady && isProxyReady {
      windowController.setStatus(
        "Ready. Start a Battlegrounds game."
      )
    }
    if wasEnabled != true {
      shouldPrepareProxyWhenAvailable = true
    }
    if shouldPrepareProxyWhenAvailable && !isProxyReady
      && ReconnectSetupPolicy.shouldPrepareProxyAutomatically(
        extensionEnabled: state.isEnabled,
        proxyReady: isProxyReady,
        action: setupAction
      )
    {
      guard !systemExtensionController.isOperationPending,
        !isPreparingProxy
      else { return }
      windowController.setStatus("Getting ready…")
      finishPreparingProxy(allowRecreateConfiguration: false)
    }
  }

  private func reconnectSetupAction(
    for state: SystemExtensionRuntimeState
  ) -> ReconnectSetupAction {
    ReconnectSetupPolicy.action(
      extensionInstalled: state.isInstalled,
      extensionEnabled: state.isEnabled,
      extensionAwaitingApproval: state.isAwaitingUserApproval,
      hasSavedProxyConfiguration: hasSavedProxyConfiguration,
      systemExtensionRetryRequired:
        systemExtensionApprovalWasDenied,
      proxyConfigurationPermissionDenied:
        proxyConfigurationPermissionWasDenied,
      proxyPreparationRetryRequired:
        proxyPreparationNeedsUserRetry
    )
  }

  private func showReconnectSetupHelp() {
    windowController.setReconnectSetupAction(.beginReconnectSetup)
    windowController.setStatus(
      lastSystemExtensionState?.isEnabled == true
        ? "Reconnect needs proxy approval. Choose Set Up Reconnect to continue."
        : "Reconnect needs approval for its network extension and proxy. "
          + "Choose Set Up Reconnect to begin."
    )
  }

  private func retrySystemExtensionApproval() {
    clearSystemExtensionApprovalDenial()
    windowController.setReconnectSetupAction(.none)
    openExtensionSettingsAfterSetup = true
    prepareProxy()
  }

  private func retryProxySetup() {
    proxyConfigurationPermissionWasDenied = false
    proxyPreparationNeedsUserRetry = false
    UserDefaults.standard.set(
      false,
      forKey: DefaultsKey.proxyConfigurationPermissionWasDenied
    )
    windowController.setReconnectSetupAction(.none)
    windowController.setStatus("Getting ready…")
    finishPreparingProxy()
  }

  private func showSystemExtensionApprovalRetry() {
    isAwaitingSystemExtensionApproval = false
    windowController.setReconnectSetupAction(
      .retrySystemExtensionApproval
    )
    windowController.setStatus(
      "Extension approval was cancelled. Click below, then approve the macOS prompt."
    )
  }

  private func showProxyConfigurationRetry() {
    windowController.setReconnectSetupAction(
      .retryProxyConfiguration
    )
    windowController.setStatus(
      "Proxy permission was denied. Click below, then choose Allow."
    )
  }

  private func clearSystemExtensionApprovalDenial() {
    systemExtensionApprovalWasDenied = false
    UserDefaults.standard.set(
      false,
      forKey: DefaultsKey.systemExtensionApprovalWasDenied
    )
  }

  private static func isSystemExtensionApprovalDenial(
    _ error: Error
  ) -> Bool {
    let error = error as NSError
    guard error.domain == OSSystemExtensionErrorDomain else {
      return false
    }
    return error.code
      == OSSystemExtensionError.Code.requestCanceled.rawValue
      || error.code
        == OSSystemExtensionError.Code.authorizationRequired.rawValue
  }

  private func recomputeProxyReadiness() {
    let newValue =
      lastSystemExtensionState?.allowsReconnect(
        proxyConnected: proxyConnectionStatus == .connected,
        isUninstalling:
          isUninstalling || systemExtensionRequiresReboot
      ) ?? false
    guard isProxyReady != newValue else { return }
    isProxyReady = newValue
    updateReconnectAvailability()
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
  }

  private func confirmUninstall() {
    guard !isUninstalling else { return }

    let alert = NSAlert()
    alert.alertStyle = .warning
    alert.messageText = "Uninstall HS Reconnect?"
    alert.informativeText =
      "This removes the app, reconnect extension, settings, "
        + "and Desktop shortcut. To reinstall or update, run the installer "
        + "instead. macOS may require a restart after full removal."
    alert.addButton(withTitle: "Uninstall")
    alert.addButton(withTitle: "Cancel")
    alert.buttons.first?.hasDestructiveAction = true

    guard alert.runModal() == .alertFirstButtonReturn else {
      return
    }

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
        self.recomputeProxyReadiness()
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
