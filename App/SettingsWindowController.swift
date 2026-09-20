import AppKit

private final class SettingsCardView: NSView {
  override init(frame frameRect: NSRect) {
    super.init(frame: frameRect)
    wantsLayer = true
    updateAppearance()
  }

  required init?(coder: NSCoder) {
    nil
  }

  override func viewDidChangeEffectiveAppearance() {
    super.viewDidChangeEffectiveAppearance()
    updateAppearance()
  }

  private func updateAppearance() {
    layer?.cornerRadius = 10
    layer?.cornerCurve = .continuous
    layer?.borderWidth = 1
    layer?.borderColor =
      NSColor.separatorColor.withAlphaComponent(0.24).cgColor
    layer?.backgroundColor =
      NSColor.controlBackgroundColor.withAlphaComponent(0.36).cgColor
  }
}

final class SettingsWindowController: NSWindowController {
  private let onReconnect: () -> Void
  private let onShortcutChanged: (UInt32, UInt32, String) -> Bool
  private let onShortcutRecordingChanged: (Bool) -> Void
  private let onOpenWithHearthstoneChanged:
    (Bool) -> Result<Void, Error>
  private let onShowInDockChanged:
    (Bool, @escaping (Bool) -> Void) -> Void
  private let onOpenSystemSettings: () -> Void
  private let onUninstall: () -> Void
  private let onLobbyEnabledChanged: (Bool) -> Void
  private let onLobbyOpacityChanged: (Double) -> Void
  private let onLobbyShortcutChanged:
    (UInt32, UInt32, String) -> Bool
  private let onResetLobby: () -> Void
  private let onRetryLobbySetup: () -> Void
  private let onReportBug: () -> Void
  private let onCheckForUpdates: () -> Void
  private let automaticUpdateChecksEnabled: () -> Bool
  private let onAutomaticUpdateChecksChanged: (Bool) -> Void

  private var reconnectIsEnabled = false
  private var statusIsError = false
  private var mainPageView: NSView!
  private var settingsPageView: NSView!
  private weak var mainSettingsButton: NSButton?
  private weak var settingsBackButton: NSButton?

  private let statusLabel = NSTextField(
    wrappingLabelWithString: "Preparing the local proxy…"
  )
  private let statusTitleLabel = NSTextField(
    labelWithString: "Reconnect status"
  )
  private let settingsStatusLabel = NSTextField(
    wrappingLabelWithString: ""
  )
  private let statusIndicator = NSImageView()
  private let shortcutButton = RecorderButton(
    title: "",
    target: nil,
    action: nil
  )
  private let openWithHearthstoneCheckbox = NSButton(
    checkboxWithTitle: "Open HS Reconnect with Hearthstone",
    target: nil,
    action: nil
  )
  private let showInDockCheckbox = NSButton(
    checkboxWithTitle: "Show HS Reconnect in Dock",
    target: nil,
    action: nil
  )
  private let reconnectButton = HoverButton(
    title: "Reconnect Now",
    target: nil,
    action: nil
  )
  private let systemExtensionSettingsButton = HoverButton(
    title: "Open System Settings",
    target: nil,
    action: nil
  )
  private let uninstallButton = HoverButton(
    title: "Uninstall HS Reconnect…",
    target: nil,
    action: nil
  )
  private let lobbySwitch = NSSwitch()
  private let lobbyShortcutButton = RecorderButton(
    title: "",
    target: nil,
    action: nil
  )
  private let opacitySlider = NSSlider(
    value: 100,
    minValue: 10,
    maxValue: 100,
    target: nil,
    action: nil
  )
  private let opacityLabel = NSTextField(labelWithString: "100%")
  private let lobbyStatusLabel = NSTextField(
    labelWithString: "Waiting for Hearthstone"
  )
  private let resetLobbyButton = HoverButton(
    title: "Reset Layout",
    target: nil,
    action: nil
  )
  private let retryLobbySetupButton = HoverButton(
    title: "Retry Setup",
    target: nil,
    action: nil
  )
  private let checkForUpdatesButton = HoverButton(
    title: "Check for Updates…",
    target: nil,
    action: nil
  )
  private let reportBugButton = HoverButton(
    title: "Report a Bug…",
    target: nil,
    action: nil
  )
  private let automaticUpdateChecksCheckbox = NSButton(
    checkboxWithTitle: "Automatically check for updates",
    target: nil,
    action: nil
  )

  init(
    onReconnect: @escaping () -> Void,
    onShortcutChanged:
      @escaping (UInt32, UInt32, String) -> Bool,
    onShortcutRecordingChanged: @escaping (Bool) -> Void,
    onOpenWithHearthstoneChanged:
      @escaping (Bool) -> Result<Void, Error>,
    onShowInDockChanged:
      @escaping (Bool, @escaping (Bool) -> Void) -> Void,
    onOpenSystemSettings: @escaping () -> Void,
    onUninstall: @escaping () -> Void,
    onLobbyEnabledChanged: @escaping (Bool) -> Void,
    onLobbyOpacityChanged: @escaping (Double) -> Void,
    onLobbyShortcutChanged:
      @escaping (UInt32, UInt32, String) -> Bool,
    onResetLobby: @escaping () -> Void,
    onRetryLobbySetup: @escaping () -> Void,
    onReportBug: @escaping () -> Void,
    onCheckForUpdates: @escaping () -> Void,
    automaticUpdateChecksEnabled: @escaping () -> Bool,
    onAutomaticUpdateChecksChanged: @escaping (Bool) -> Void
  ) {
    self.onReconnect = onReconnect
    self.onShortcutChanged = onShortcutChanged
    self.onShortcutRecordingChanged =
      onShortcutRecordingChanged
    self.onOpenWithHearthstoneChanged =
      onOpenWithHearthstoneChanged
    self.onShowInDockChanged = onShowInDockChanged
    self.onOpenSystemSettings = onOpenSystemSettings
    self.onUninstall = onUninstall
    self.onLobbyEnabledChanged = onLobbyEnabledChanged
    self.onLobbyOpacityChanged = onLobbyOpacityChanged
    self.onLobbyShortcutChanged = onLobbyShortcutChanged
    self.onResetLobby = onResetLobby
    self.onRetryLobbySetup = onRetryLobbySetup
    self.onReportBug = onReportBug
    self.onCheckForUpdates = onCheckForUpdates
    self.automaticUpdateChecksEnabled =
      automaticUpdateChecksEnabled
    self.onAutomaticUpdateChecksChanged =
      onAutomaticUpdateChecksChanged

    let window = NSWindow(
      contentRect: NSRect(
        x: 0,
        y: 0,
        width: 440,
        height: 485
      ),
      styleMask: [.titled, .closable, .miniaturizable],
      backing: .buffered,
      defer: false
    )
    window.title = AppConfiguration.appName
    window.center()
    window.isReleasedWhenClosed = false

    super.init(window: window)
    configureControls()
    buildInterface()
    refresh()
    showMainPage()
  }

  required init?(coder: NSCoder) {
    nil
  }

  override func showWindow(_ sender: Any?) {
    showMainPage()
    super.showWindow(sender)
  }

  func refresh() {
    shortcutButton.title =
      UserDefaults.standard.string(
        forKey: DefaultsKey.hotkeyDisplay
      ) ?? AppConfiguration.defaultShortcutDisplay
    openWithHearthstoneCheckbox.state =
      UserDefaults.standard.bool(
        forKey: DefaultsKey.openWithHearthstone
      ) ? .on : .off
    showInDockCheckbox.state =
      UserDefaults.standard.bool(
        forKey: DefaultsKey.showInDock
      ) ? .on : .off
    lobbySwitch.state =
      UserDefaults.standard.bool(
        forKey: DefaultsKey.lobbyEnabled
      ) ? .on : .off
    lobbyShortcutButton.title =
      UserDefaults.standard.string(
        forKey: DefaultsKey.lobbyShortcutDisplay
      ) ?? AppConfiguration.defaultLobbyShortcutDisplay
    let opacity = UserDefaults.standard.double(
      forKey: DefaultsKey.lobbyOpacity
    )
    opacitySlider.doubleValue = opacity == 0 ? 100 : opacity
    opacityLabel.stringValue =
      "\(Int(opacitySlider.doubleValue.rounded()))%"
    automaticUpdateChecksCheckbox.state =
      automaticUpdateChecksEnabled() ? .on : .off
  }

  func setStatus(
    _ message: String,
    isError: Bool = false
  ) {
    statusIsError = isError
    statusLabel.stringValue = message
    statusLabel.textColor =
      isError ? .systemRed : .secondaryLabelColor
    statusLabel.toolTip = message
    updateStatusIndicator()

    NSAccessibility.post(
      element: statusLabel,
      notification: .valueChanged
    )
  }

  func setReconnectEnabled(_ enabled: Bool) {
    reconnectIsEnabled = enabled
    reconnectButton.isEnabled = enabled
    updateStatusIndicator()
  }

  func setLobbyStatus(
    _ message: String,
    canRetry: Bool = false
  ) {
    lobbyStatusLabel.stringValue = message
    lobbyStatusLabel.toolTip = message
    retryLobbySetupButton.isHidden = !canRetry
    NSAccessibility.post(
      element: lobbyStatusLabel,
      notification: .valueChanged
    )
  }

  func setSystemExtensionApprovalRequired(
    _ required: Bool
  ) {
    systemExtensionSettingsButton.isHidden = !required
  }

  func setUninstalling(_ uninstalling: Bool) {
    uninstallButton.title =
      uninstalling
      ? "Uninstalling…"
      : "Uninstall HS Reconnect…"
    uninstallButton.isEnabled = !uninstalling
    shortcutButton.isEnabled = !uninstalling
    openWithHearthstoneCheckbox.isEnabled = !uninstalling
    showInDockCheckbox.isEnabled = !uninstalling
    reconnectButton.isEnabled =
      !uninstalling && reconnectIsEnabled
    systemExtensionSettingsButton.isEnabled = !uninstalling
    lobbySwitch.isEnabled = !uninstalling
    lobbyShortcutButton.isEnabled = !uninstalling
    opacitySlider.isEnabled = !uninstalling
    resetLobbyButton.isEnabled = !uninstalling
    retryLobbySetupButton.isEnabled = !uninstalling
    reportBugButton.isEnabled = !uninstalling
    checkForUpdatesButton.isEnabled = !uninstalling
    automaticUpdateChecksCheckbox.isEnabled = !uninstalling
  }

  private func configureControls() {
    shortcutButton.bezelStyle = .rounded
    shortcutButton.setAccessibilityLabel(
      "Change reconnect shortcut"
    )
    shortcutButton.onRecordingStateChanged = {
      [weak self] isRecording in
      self?.onShortcutRecordingChanged(isRecording)
    }
    shortcutButton.onValidationMessage = {
      [weak self] message in
      self?.setStatus(
        message,
        isError: message != "Shortcut change cancelled."
      )
    }
    shortcutButton.onRecord = {
      [weak self] keyCode, modifiers, display in
      guard let self else { return false }
      let changed = self.onShortcutChanged(
        keyCode,
        modifiers,
        display
      )
      self.setStatus(
        changed
          ? "Shortcut changed to \(display)."
          : "That shortcut is already in use. Choose another one.",
        isError: !changed
      )
      return changed
    }

    reconnectButton.target = self
    reconnectButton.action = #selector(reconnectNow)
    reconnectButton.bezelStyle = .rounded
    reconnectButton.controlSize = .regular
    reconnectButton.keyEquivalent = "\r"
    reconnectButton.bezelColor = .controlAccentColor
    reconnectButton.contentTintColor = .white
    reconnectButton.attributedTitle = NSAttributedString(
      string: "Reconnect Now",
      attributes: [
        .foregroundColor: NSColor.white,
        .font: NSFont.systemFont(
          ofSize: NSFont.systemFontSize,
          weight: .medium
        ),
      ]
    )
    reconnectButton.setAccessibilityLabel("Reconnect now")

    systemExtensionSettingsButton.target = self
    systemExtensionSettingsButton.action =
      #selector(openSystemSettings)
    systemExtensionSettingsButton.bezelStyle = .rounded
    systemExtensionSettingsButton.isHidden = true
    systemExtensionSettingsButton.setAccessibilityLabel(
      "Open Network Extension settings"
    )

    lobbySwitch.target = self
    lobbySwitch.action = #selector(lobbyEnabledChanged)
    lobbySwitch.setAccessibilityLabel("Show lobby info")

    lobbyShortcutButton.bezelStyle = .rounded
    lobbyShortcutButton.setAccessibilityLabel(
      "Change lobby positioning shortcut"
    )
    lobbyShortcutButton.onRecordingStateChanged = {
      [weak self] recording in
      self?.onShortcutRecordingChanged(recording)
    }
    lobbyShortcutButton.onValidationMessage = {
      [weak self] message in
      self?.setLobbyStatus(message)
    }
    lobbyShortcutButton.onRecord = {
      [weak self] key, modifiers, display in
      guard let self else { return false }
      let changed = self.onLobbyShortcutChanged(
        key,
        modifiers,
        display
      )
      self.setLobbyStatus(
        changed
          ? "Position shortcut changed to \(display)."
          : "That shortcut is already in use. Choose another one."
      )
      return changed
    }

    opacitySlider.target = self
    opacitySlider.action = #selector(opacityChanged)
    opacitySlider.setAccessibilityLabel("Overlay opacity")
    resetLobbyButton.target = self
    resetLobbyButton.action = #selector(resetLobby)
    retryLobbySetupButton.target = self
    retryLobbySetupButton.action =
      #selector(retryLobbySetup)
    retryLobbySetupButton.isHidden = true

    reportBugButton.target = self
    reportBugButton.action = #selector(reportBug)
    reportBugButton.image = NSImage(
      systemSymbolName: "ladybug",
      accessibilityDescription: nil
    )
    reportBugButton.imagePosition = .imageLeading

    openWithHearthstoneCheckbox.target = self
    openWithHearthstoneCheckbox.action =
      #selector(openWithHearthstoneChanged)
    showInDockCheckbox.target = self
    showInDockCheckbox.action =
      #selector(showInDockChanged)

    checkForUpdatesButton.target = self
    checkForUpdatesButton.action = #selector(checkForUpdates)
    automaticUpdateChecksCheckbox.target = self
    automaticUpdateChecksCheckbox.action =
      #selector(automaticUpdateChecksChanged)

    uninstallButton.target = self
    uninstallButton.action = #selector(uninstall)
    uninstallButton.bezelStyle = .rounded
    uninstallButton.contentTintColor = .systemRed
    uninstallButton.hasDestructiveAction = true
    uninstallButton.setAccessibilityLabel(
      "Uninstall HS Reconnect"
    )

    statusIndicator.image = NSImage(
      systemSymbolName: "circle.fill",
      accessibilityDescription: "Reconnect status"
    )
    statusIndicator.symbolConfiguration =
      NSImage.SymbolConfiguration(
        pointSize: 12,
        weight: .medium
      )
    statusIndicator.setContentHuggingPriority(
      .required,
      for: .horizontal
    )

    statusLabel.textColor = .secondaryLabelColor
    statusLabel.maximumNumberOfLines = 2
    statusLabel.setAccessibilityLabel("Reconnect status")
    statusLabel.setContentCompressionResistancePriority(
      .defaultLow,
      for: .horizontal
    )
    statusTitleLabel.font = .systemFont(
      ofSize: 14,
      weight: .semibold
    )
    settingsStatusLabel.textColor = .secondaryLabelColor
    settingsStatusLabel.maximumNumberOfLines = 2
    settingsStatusLabel.setAccessibilityLabel("Status")
    settingsStatusLabel.isHidden = true

    lobbyStatusLabel.textColor = .secondaryLabelColor
    lobbyStatusLabel.setContentCompressionResistancePriority(
      .defaultLow,
      for: .horizontal
    )
  }

  private func buildInterface() {
    guard let contentView = window?.contentView else {
      return
    }

    mainPageView = makeMainPage()
    settingsPageView = makeSettingsPage()

    for page in [mainPageView, settingsPageView] {
      guard let page else { continue }
      page.translatesAutoresizingMaskIntoConstraints = false
      contentView.addSubview(page)
      NSLayoutConstraint.activate([
        page.leadingAnchor.constraint(
          equalTo: contentView.leadingAnchor
        ),
        page.trailingAnchor.constraint(
          equalTo: contentView.trailingAnchor
        ),
        page.topAnchor.constraint(
          equalTo: contentView.topAnchor
        ),
        page.bottomAnchor.constraint(
          equalTo: contentView.bottomAnchor
        ),
      ])
    }
  }

  private func makeMainPage() -> NSView {
    let page = NSView()

    let icon = NSImageView(image: NSApp.applicationIconImage)
    icon.imageScaling = .scaleProportionallyUpOrDown
    icon.translatesAutoresizingMaskIntoConstraints = false
    NSLayoutConstraint.activate([
      icon.widthAnchor.constraint(equalToConstant: 42),
      icon.heightAnchor.constraint(equalToConstant: 42),
    ])

    let title = makeLabel(
      AppConfiguration.appName,
      size: 21,
      weight: .semibold
    )
    let subtitle = NSTextField(
      labelWithString:
        "Command Center for Hearthstone Battlegrounds"
    )
    subtitle.textColor = .secondaryLabelColor
    subtitle.font = .systemFont(ofSize: 13)
    let titleStack = makeVerticalStack(
      [title, subtitle],
      spacing: 2
    )
    let headerRow = makeHorizontalRow(
      [icon, titleStack],
      spacing: 12
    )

    let statusTextStack = makeVerticalStack(
      [statusTitleLabel, statusLabel],
      spacing: 2
    )
    let statusRow = makeHorizontalRow(
      [
        statusIndicator,
        statusTextStack,
        flexibleSpacer(),
        systemExtensionSettingsButton,
      ],
      spacing: 12
    )
    let statusCard = makeCard(containing: statusRow)

    let reconnectTitle = makeLabel(
      "Reconnect",
      size: 16,
      weight: .semibold
    )
    let reconnectHeader = makeHorizontalRow(
      [
        reconnectTitle,
        flexibleSpacer(),
        shortcutButton,
      ],
      spacing: 10
    )
    let reconnectDescription = NSTextField(
      labelWithString:
        "Restart the current Battlegrounds connection."
    )
    reconnectDescription.textColor = .secondaryLabelColor
    let reconnectStack = makeVerticalStack(
      [
        reconnectHeader,
        reconnectDescription,
        reconnectButton,
      ],
      spacing: 9
    )
    constrainFullWidth(
      [reconnectHeader, reconnectButton],
      in: reconnectStack
    )
    let reconnectCard = makeCard(
      containing: reconnectStack
    )

    let lobbyTitle = makeLabel(
      "Lobby info",
      size: 16,
      weight: .semibold
    )
    let lobbyHeader = makeHorizontalRow(
      [lobbyTitle, flexibleSpacer(), lobbySwitch],
      spacing: 12
    )
    let lobbyStatusRow = makeHorizontalRow(
      [
        lobbyStatusLabel,
        flexibleSpacer(),
        retryLobbySetupButton,
      ],
      spacing: 12
    )
    let lobbyShortcutLabel = NSTextField(
      labelWithString: "Position shortcut"
    )
    let lobbyShortcutRow = makeHorizontalRow(
      [
        lobbyShortcutLabel,
        flexibleSpacer(),
        lobbyShortcutButton,
      ],
      spacing: 12
    )

    let opacityText = NSTextField(
      labelWithString: "Overlay opacity"
    )
    opacitySlider.translatesAutoresizingMaskIntoConstraints =
      false
    opacitySlider.widthAnchor.constraint(
      equalToConstant: 150
    ).isActive = true
    opacityLabel.alignment = .right
    opacityLabel.translatesAutoresizingMaskIntoConstraints =
      false
    opacityLabel.widthAnchor.constraint(
      equalToConstant: 46
    ).isActive = true
    let opacityRow = makeHorizontalRow(
      [
        opacityText,
        flexibleSpacer(),
        opacitySlider,
        opacityLabel,
      ],
      spacing: 10
    )

    let lobbyDivider = makeDivider()
    let lobbyStack = makeVerticalStack(
      [
        lobbyHeader,
        lobbyStatusRow,
        lobbyDivider,
        lobbyShortcutRow,
        opacityRow,
        resetLobbyButton,
      ],
      spacing: 9
    )
    constrainFullWidth(
      [
        lobbyHeader,
        lobbyStatusRow,
        lobbyDivider,
        lobbyShortcutRow,
        opacityRow,
      ],
      in: lobbyStack
    )
    let lobbyCard = makeCard(containing: lobbyStack)

    let settingsButton = HoverButton(
      title: "Settings…",
      target: self,
      action: #selector(showSettings)
    )
    settingsButton.image = NSImage(
      systemSymbolName: "gearshape",
      accessibilityDescription: nil
    )
    settingsButton.imagePosition = .imageLeading
    settingsButton.setAccessibilityLabel("Open settings")
    mainSettingsButton = settingsButton
    let footerRow = makeHorizontalRow(
      [
        settingsButton,
        flexibleSpacer(),
        reportBugButton,
      ],
      spacing: 12
    )

    let footerDivider = makeDivider()
    let stack = makeVerticalStack(
      [
        headerRow,
        statusCard,
        reconnectCard,
        lobbyCard,
        footerDivider,
        footerRow,
      ],
      spacing: 10
    )
    stack.translatesAutoresizingMaskIntoConstraints = false
    page.addSubview(stack)

    constrainFullWidth(
      [
        headerRow,
        statusCard,
        reconnectCard,
        lobbyCard,
        footerDivider,
        footerRow,
      ],
      in: stack
    )
    NSLayoutConstraint.activate([
      stack.leadingAnchor.constraint(
        equalTo: page.leadingAnchor,
        constant: 18
      ),
      stack.trailingAnchor.constraint(
        equalTo: page.trailingAnchor,
        constant: -18
      ),
      stack.topAnchor.constraint(
        equalTo: page.topAnchor,
        constant: 16
      ),
      stack.bottomAnchor.constraint(
        lessThanOrEqualTo: page.bottomAnchor,
        constant: -16
      ),
    ])
    return page
  }

  private func makeSettingsPage() -> NSView {
    let page = NSView()

    let backButton = HoverButton(
      title: "Back",
      target: self,
      action: #selector(showMain)
    )
    backButton.image = NSImage(
      systemSymbolName: "chevron.left",
      accessibilityDescription: nil
    )
    backButton.imagePosition = .imageLeading
    backButton.bezelStyle = .rounded
    backButton.setAccessibilityLabel("Back to main view")
    settingsBackButton = backButton

    let headerRow = makeHorizontalRow(
      [backButton, flexibleSpacer()],
      spacing: 12
    )

    let generalTitle = makeLabel(
      "General",
      size: 17,
      weight: .semibold
    )
    let generalContent = makeVerticalStack(
      [
        openWithHearthstoneCheckbox,
        showInDockCheckbox,
      ],
      spacing: 10
    )
    let generalCard = makeCard(containing: generalContent)

    let updatesTitle = makeLabel(
      "Updates",
      size: 17,
      weight: .semibold
    )
    let updateActionRow = makeHorizontalRow(
      [
        automaticUpdateChecksCheckbox,
        flexibleSpacer(),
        checkForUpdatesButton,
      ],
      spacing: 12
    )
    let updatesCard = makeCard(containing: updateActionRow)

    let advancedTitle = makeLabel(
      "Advanced",
      size: 17,
      weight: .semibold
    )
    let advancedDescription = NSTextField(
      wrappingLabelWithString:
        "Remove HS Reconnect, its network extension, and saved settings from this Mac."
    )
    advancedDescription.textColor = .secondaryLabelColor
    advancedDescription.maximumNumberOfLines = 2
    let advancedContent = makeVerticalStack(
      [
        advancedDescription,
        uninstallButton,
      ],
      spacing: 10
    )
    let advancedCard = makeCard(
      containing: advancedContent
    )

    let version = Bundle.main.object(
      forInfoDictionaryKey:
        "CFBundleShortVersionString"
    ) as? String ?? "1.3.0"
    let versionLabel = NSTextField(
      labelWithString: "HS Reconnect \(version)"
    )
    versionLabel.textColor = .tertiaryLabelColor
    versionLabel.alignment = .center

    let generalDivider = makeDivider()
    let updatesDivider = makeDivider()
    let advancedDivider = makeDivider()
    let settingsSpacer = flexibleVerticalSpacer()
    let stack = makeVerticalStack(
      [
        headerRow,
        generalTitle,
        generalCard,
        generalDivider,
        updatesTitle,
        updatesCard,
        updatesDivider,
        advancedTitle,
        advancedCard,
        settingsSpacer,
        advancedDivider,
        settingsStatusLabel,
        versionLabel,
      ],
      spacing: 10
    )
    stack.translatesAutoresizingMaskIntoConstraints = false
    page.addSubview(stack)

    constrainFullWidth(
      [
        headerRow,
        generalTitle,
        generalCard,
        generalDivider,
        updatesTitle,
        updatesCard,
        updatesDivider,
        advancedTitle,
        advancedCard,
        advancedDivider,
        settingsStatusLabel,
        versionLabel,
      ],
      in: stack
    )
    NSLayoutConstraint.activate([
      stack.leadingAnchor.constraint(
        equalTo: page.leadingAnchor,
        constant: 18
      ),
      stack.trailingAnchor.constraint(
        equalTo: page.trailingAnchor,
        constant: -18
      ),
      stack.topAnchor.constraint(
        equalTo: page.topAnchor,
        constant: 16
      ),
      stack.bottomAnchor.constraint(
        equalTo: page.bottomAnchor,
        constant: -16
      ),
    ])
    return page
  }

  private func makeCard(containing content: NSView)
    -> NSView
  {
    let card = SettingsCardView()
    content.translatesAutoresizingMaskIntoConstraints = false
    card.addSubview(content)
    NSLayoutConstraint.activate([
      content.leadingAnchor.constraint(
        equalTo: card.leadingAnchor,
        constant: 12
      ),
      content.trailingAnchor.constraint(
        equalTo: card.trailingAnchor,
        constant: -12
      ),
      content.topAnchor.constraint(
        equalTo: card.topAnchor,
        constant: 11
      ),
      content.bottomAnchor.constraint(
        equalTo: card.bottomAnchor,
        constant: -11
      ),
    ])
    return card
  }

  private func makeLabel(
    _ text: String,
    size: CGFloat,
    weight: NSFont.Weight
  ) -> NSTextField {
    let label = NSTextField(labelWithString: text)
    label.font = .systemFont(
      ofSize: size,
      weight: weight
    )
    return label
  }

  private func makeVerticalStack(
    _ views: [NSView],
    spacing: CGFloat
  ) -> NSStackView {
    let stack = NSStackView(views: views)
    stack.orientation = .vertical
    stack.alignment = .leading
    stack.spacing = spacing
    return stack
  }

  private func makeHorizontalRow(
    _ views: [NSView],
    spacing: CGFloat
  ) -> NSStackView {
    let row = NSStackView(views: views)
    row.orientation = .horizontal
    row.alignment = .centerY
    row.spacing = spacing
    return row
  }

  private func flexibleSpacer() -> NSView {
    let spacer = NSView()
    spacer.setContentHuggingPriority(
      .defaultLow,
      for: .horizontal
    )
    spacer.setContentCompressionResistancePriority(
      .defaultLow,
      for: .horizontal
    )
    return spacer
  }

  private func flexibleVerticalSpacer() -> NSView {
    let spacer = NSView()
    spacer.setContentHuggingPriority(
      .defaultLow,
      for: .vertical
    )
    spacer.setContentCompressionResistancePriority(
      .defaultLow,
      for: .vertical
    )
    return spacer
  }

  private func makeDivider() -> NSBox {
    let divider = NSBox()
    divider.boxType = .separator
    return divider
  }

  private func constrainFullWidth(
    _ views: [NSView],
    in stack: NSStackView
  ) {
    for view in views {
      view.translatesAutoresizingMaskIntoConstraints = false
      view.widthAnchor.constraint(
        equalTo: stack.widthAnchor
      ).isActive = true
    }
  }

  private func updateStatusIndicator() {
    statusTitleLabel.stringValue = statusIsError
      ? "Attention needed"
      : (reconnectIsEnabled
        ? "Ready to reconnect"
        : "Reconnect status")
    statusIndicator.contentTintColor =
      statusIsError
      ? .systemRed
      : (reconnectIsEnabled ? .systemGreen : .systemOrange)
  }

  private func setSettingsFeedback(
    _ message: String,
    isError: Bool = false
  ) {
    settingsStatusLabel.stringValue = message
    settingsStatusLabel.textColor =
      isError ? .systemRed : .secondaryLabelColor
    settingsStatusLabel.toolTip = message
    settingsStatusLabel.isHidden = false
    NSAccessibility.post(
      element: settingsStatusLabel,
      notification: .valueChanged
    )
  }

  private func showMainPage() {
    guard let mainPageView,
      let settingsPageView
    else {
      return
    }
    settingsPageView.isHidden = true
    mainPageView.isHidden = false
    window?.title = AppConfiguration.appName
    window?.makeFirstResponder(mainSettingsButton)
    NSAccessibility.post(
      element: mainPageView,
      notification: .layoutChanged
    )
  }

  private func showSettingsPage() {
    guard let mainPageView,
      let settingsPageView
    else {
      return
    }
    refresh()
    mainPageView.isHidden = true
    settingsPageView.isHidden = false
    window?.title = "Settings"
    settingsStatusLabel.isHidden =
      settingsStatusLabel.stringValue.isEmpty
    window?.makeFirstResponder(settingsBackButton)
    NSAccessibility.post(
      element: settingsPageView,
      notification: .layoutChanged
    )
  }

  @objc private func showSettings() {
    showSettingsPage()
  }

  @objc private func showMain() {
    showMainPage()
  }

  @objc private func reconnectNow() {
    onReconnect()
  }

  @objc private func openSystemSettings() {
    onOpenSystemSettings()
  }

  @objc private func uninstall() {
    onUninstall()
  }

  @objc private func openWithHearthstoneChanged() {
    let enabled =
      openWithHearthstoneCheckbox.state == .on
    switch onOpenWithHearthstoneChanged(enabled) {
    case .success:
      let message =
        enabled
        ? "HS Reconnect will open with Hearthstone."
        : "Automatic opening is off."
      setStatus(message)
      setSettingsFeedback(message)
    case .failure:
      let message =
        "Automatic opening couldn't be changed. Please try again."
      setStatus(message, isError: true)
      setSettingsFeedback(message, isError: true)
      refresh()
    }
  }

  @objc private func showInDockChanged() {
    let enabled = showInDockCheckbox.state == .on
    onShowInDockChanged(enabled) {
      [weak self] succeeded in
      guard let self else { return }
      if succeeded {
        let message =
          enabled
          ? "HS Reconnect is shown in the Dock."
          : "HS Reconnect is hidden from the Dock. Use the menu bar icon to open it."
        self.setStatus(message)
        self.setSettingsFeedback(message)
      } else {
        let message =
          "Dock visibility couldn't be changed. Please try again."
        self.setStatus(message, isError: true)
        self.setSettingsFeedback(message, isError: true)
        self.refresh()
      }
    }
  }

  @objc private func lobbyEnabledChanged() {
    onLobbyEnabledChanged(lobbySwitch.state == .on)
  }

  @objc private func opacityChanged() {
    opacityLabel.stringValue =
      "\(Int(opacitySlider.doubleValue.rounded()))%"
    onLobbyOpacityChanged(opacitySlider.doubleValue)
  }

  @objc private func resetLobby() {
    onResetLobby()
  }

  @objc private func retryLobbySetup() {
    onRetryLobbySetup()
  }

  @objc private func reportBug() {
    onReportBug()
  }

  @objc private func checkForUpdates() {
    onCheckForUpdates()
  }

  @objc private func automaticUpdateChecksChanged() {
    onAutomaticUpdateChecksChanged(
      automaticUpdateChecksCheckbox.state == .on
    )
  }
}
