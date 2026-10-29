import AppKit

/// The one-time What's New for the floating Reconnect button: a spotlight over the main window on the
/// Overlays → Reconnect button switch. Shown once per `WhatsNewPolicy.currentVersion`, only while the main window shows
/// that switch and Reconnect is ready; Done, Return, Esc, closing the window or quitting all count as seen.
final class WhatsNewPresenter {
  private static let closingKeys: Set<UInt16> = [36, 76, 53]   // Return, Enter, Esc
  private let defaults: UserDefaults
  private weak var host: NSWindow?
  private var spotlight: WhatsNewSpotlightView?
  private var observers: [NSObjectProtocol] = []
  private var keyMonitor: Any?
  /// The key that closed the spotlight, swallowed until it's released so a held Return can't repeat into
  /// Reconnect Now underneath.
  private var heldClosingKey: UInt16?
  var isShowing: Bool { spotlight != nil }

  init(defaults: UserDefaults = .standard) {
    self.defaults = defaults
  }

  /// Safe to call often. Shows it if it's still due; if it's already up, gives it the keyboard back; if Reconnect stops
  /// being ready, takes it down without marking it seen so it never covers a setup or error prompt.
  func presentIfNeeded(over window: NSWindow, isReconnectReady: Bool) {
    if let spotlight {
      if !isReconnectReady { remove(markSeen: false); return }
      window.makeFirstResponder(spotlight)
      spotlight.needsLayout = true
      return
    }
    guard window.isVisible, let contentView = window.contentView,
      // Not over the Settings page: wait until the switch is on screen.
      WhatsNewSpotlightView.findTarget(in: contentView).map({ !$0.isHiddenOrHasHiddenAncestor }) == true,
      WhatsNewPolicy.shouldShow(storedSeenVersion: defaults.object(forKey: DefaultsKey.whatsNewSeenVersion),
        isReconnectReady: isReconnectReady)
    else { return }
    let view = WhatsNewSpotlightView(content: .current(defaults: defaults), onDone: { [weak self] in self?.dismiss() })
    view.frame = contentView.bounds
    view.autoresizingMask = [.width, .height]
    contentView.addSubview(view, positioned: .above, relativeTo: nil)
    spotlight = view
    host = window
    window.makeFirstResponder(view)
    let center = NotificationCenter.default
    observers = [
      center.addObserver(forName: NSWindow.willCloseNotification, object: window, queue: .main) {
        [weak self] _ in self?.dismiss() },
      center.addObserver(forName: NSApplication.willTerminateNotification, object: nil, queue: .main) {
        [weak self] _ in self?.dismiss() },
    ]
    installKeyMonitor()
    view.layoutSubtreeIfNeeded()
    NSAccessibility.post(element: view, notification: .layoutChanged,
      userInfo: [.uiElements: [view.doneButton as Any]])
  }

  func dismiss() { remove(markSeen: true) }

  private func remove(markSeen: Bool) {
    guard let spotlight else { return }
    if markSeen { defaults.set(WhatsNewPolicy.currentVersion, forKey: DefaultsKey.whatsNewSeenVersion) }
    observers.forEach(NotificationCenter.default.removeObserver)
    observers = []
    self.spotlight = nil
    spotlight.removeFromSuperview()
    // Keep swallowing a closing key that's still held; otherwise stop watching keys now.
    if heldClosingKey == nil { removeKeyMonitor() }
  }

  /// Return is also the main window's Reconnect Now key. Return, Enter and Esc for this window are caught before any
  /// key equivalent runs, so they only ever close the spotlight; their auto-repeats are swallowed until release.
  private func installKeyMonitor() {
    keyMonitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown, .keyUp]) { [weak self] event in
      guard let self, let host = self.host, event.window === host else { return event }
      if let held = self.heldClosingKey, event.keyCode == held {
        // Auto-repeats are swallowed. A fresh press means the release was missed (e.g. it happened in another
        // window), so stop holding and treat it normally.
        if event.type == .keyDown && event.isARepeat { return nil }
        self.heldClosingKey = nil
        if self.spotlight == nil { self.removeKeyMonitor() }
        if event.type == .keyUp { return nil }
      }
      guard event.type == .keyDown, self.spotlight != nil, Self.closingKeys.contains(event.keyCode),
        event.modifierFlags.intersection([.command, .option, .control]).isEmpty else { return event }
      self.heldClosingKey = event.keyCode
      self.dismiss()
      return nil
    }
  }

  private func removeKeyMonitor() {
    if let keyMonitor { NSEvent.removeMonitor(keyMonitor) }
    keyMonitor = nil
    heldClosingKey = nil
  }

  #if DEBUG
  /// For the harness self-test.
  var diagnosticSpotlight: WhatsNewSpotlightView? { spotlight }
  var diagnosticIsWatchingKeys: Bool { keyMonitor != nil }
  #endif
}

/// The words, with the user's own shortcuts filled in (the same display strings the main window shows).
struct WhatsNewContent {
  struct Row { let symbol: String; let title: String; let detail: String }
  let title = "What's New in HS Reconnect"
  let rows: [Row]
  /// The last row's text, by whether the card sits above the highlighted switch.
  static let switchBelow = "Use the highlighted switch below."
  static let switchHighlighted = "Use the highlighted switch."
  static let switchElsewhere = "Use the Reconnect button switch in Overlays."

  static func current(defaults: UserDefaults) -> WhatsNewContent {
    func display(_ key: String) -> String? {
      defaults.string(forKey: key).map { $0.trimmingCharacters(in: .whitespaces) }.flatMap { $0.isEmpty ? nil : $0 }
    }
    let reconnect = display(DefaultsKey.hotkeyDisplay).map { "Works like \($0)." } ?? "Works like the Reconnect shortcut."
    let layout = display(DefaultsKey.lobbyShortcutDisplay) ?? "the position shortcut"
    return WhatsNewContent(rows: [
      Row(symbol: "cursorarrow.click", title: "One click reconnects",
        detail: "Shows up in every Battlegrounds match. \(reconnect)"),
      Row(symbol: "arrow.up.and.down.and.arrow.left.and.right", title: "Move and resize it",
        detail: "Press \(layout), drag it, then press Return."),
      Row(symbol: "switch.2", title: "Turn it off any time", detail: switchBelow),
    ])
  }
}

/// A picture of the real button, drawn live by its own canvas on a dark backdrop, so it always matches the button's
/// current look. Ignores clicks; VoiceOver reads it as one image.
final class WhatsNewButtonPicture: NSView {
  private let canvas = ReconnectButtonCanvas(frame: .zero)
  private let buttonScale: CGFloat

  init(buttonScale: CGFloat) {
    self.buttonScale = buttonScale
    super.init(frame: .zero)
    wantsLayer = true
    layer?.cornerRadius = 10
    layer?.cornerCurve = .continuous
    layer?.masksToBounds = true
    canvas.allowsClick = { false }
    canvas.setAccessibilityElement(false)
    addSubview(canvas)
    setAccessibilityElement(true)
    setAccessibilityRole(.image)
    setAccessibilityLabel("Picture of the Reconnect button")
    translatesAutoresizingMaskIntoConstraints = false
  }
  required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

  override var isFlipped: Bool { true }
  override func hitTest(_ point: NSPoint) -> NSView? { nil }

  override func layout() {
    super.layout()
    let size = NSSize(width: ReconnectButtonCanvas.baseSize.width * buttonScale,
      height: ReconnectButtonCanvas.baseSize.height * buttonScale)
    canvas.frame = NSRect(x: (bounds.width - size.width) / 2, y: (bounds.height - size.height) / 2,
      width: size.width, height: size.height).integral
  }

  override func draw(_ dirtyRect: NSRect) {
    // Hearthstone's dusk purple, so the frosted button looks as it does over the game in both appearances.
    NSGradient(starting: NSColor(calibratedRed: 0.20, green: 0.13, blue: 0.27, alpha: 1),
      ending: NSColor(calibratedRed: 0.10, green: 0.07, blue: 0.14, alpha: 1))?.draw(in: bounds, angle: -90)
  }
}

/// The solid card behind the callout's text, so it reads cleanly over the dimmed window in both appearances.
final class WhatsNewCalloutView: NSView {
  override init(frame frameRect: NSRect) {
    super.init(frame: frameRect)
    wantsLayer = true
    layer?.cornerRadius = 12
    layer?.cornerCurve = .continuous
    layer?.borderWidth = 1
    layer?.shadowOpacity = 0.25
    layer?.shadowRadius = 12
    layer?.shadowOffset = CGSize(width: 0, height: -4)
    updateColors()
  }
  required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

  override func viewDidChangeEffectiveAppearance() {
    super.viewDidChangeEffectiveAppearance()
    updateColors()
  }

  private func updateColors() {
    effectiveAppearance.performAsCurrentDrawingAppearance {
      layer?.backgroundColor = NSColor.windowBackgroundColor.cgColor
      layer?.borderColor = NSColor.separatorColor.cgColor
    }
  }
}

/// A within-window blur with a hole for the highlighted row. Never takes clicks.
final class WhatsNewFrostView: NSVisualEffectView {
  var cutOut: NSRect? {
    didSet { if cutOut != oldValue || maskImage?.size != bounds.size { updateMask() } }
  }
  override init(frame frameRect: NSRect) {
    super.init(frame: frameRect)
    blendingMode = .withinWindow
    material = .underWindowBackground
    state = .active
  }
  required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }
  override func hitTest(_ point: NSPoint) -> NSView? { nil }
  override func layout() {
    super.layout()
    if maskImage?.size != bounds.size { updateMask() }
  }
  private func updateMask() {
    let hole = cutOut
    maskImage = NSImage(size: bounds.size, flipped: true) { rect in
      let shape = NSBezierPath(rect: rect)
      if let hole { shape.append(NSBezierPath(roundedRect: hole, xRadius: 9, yRadius: 9)) }
      shape.windingRule = .evenOdd
      NSColor.black.setFill()
      shape.fill()
      return true
    }
  }
}

/// Draws whatever its owner hands it, above the blur; never takes clicks.
final class WhatsNewVeilView: NSView {
  var drawing: (() -> Void)?
  override var isFlipped: Bool { true }
  override func hitTest(_ point: NSPoint) -> NSView? { nil }
  override func draw(_ dirtyRect: NSRect) { drawing?() }
}

/// Dims the main window except the Overlays → Reconnect button row, which gets a blue ring and stays clickable.
/// A What's New card fills the window above that row, and an arrow runs from its "Turn it off" row to the switch.
final class WhatsNewSpotlightView: NSView {
  /// The switch the spotlight finds by its accessibility label (set in `SettingsWindowController`).
  static let targetAccessibilityLabel = "Show Reconnect button over Hearthstone"
  /// Room between the card and the ring: the lobby status line above the row stays whole, never half-covered.
  private static let gapAboveSpotlight: CGFloat = 24
  private static let arrowLane: CGFloat = 64
  private let onDone: () -> Void
  private let card = WhatsNewCalloutView()
  /// Blurs the window behind (except the highlighted row) so nothing half-covered can be read.
  private let frost = WhatsNewFrostView()
  /// Draws the tint, the ring and the arrow above the blur and below the card.
  private let veil = WhatsNewVeilView()
  private let switchRow: NSView
  private let switchText: NSTextField
  private(set) var doneButton: NSButton!
  private var cardPlacement: [NSLayoutConstraint] = []
  /// True when the card ends above the highlighted row, so "below" in the last row is right.
  private(set) var isCardAboveSpotlight = false

  init(content: WhatsNewContent, onDone: @escaping () -> Void) {
    self.onDone = onDone
    var rowViews: [NSView] = []
    var lastText: NSTextField?
    for row in content.rows {
      let icon = NSImageView(image: NSImage(systemSymbolName: row.symbol, accessibilityDescription: nil) ?? NSImage())
      icon.symbolConfiguration = .init(pointSize: 16, weight: .regular)
      icon.imageScaling = .scaleProportionallyDown
      icon.contentTintColor = .controlAccentColor
      icon.setAccessibilityElement(false)
      icon.translatesAutoresizingMaskIntoConstraints = false
      let heading = Self.text(row.title, size: 13, weight: .semibold, color: .labelColor)
      let detail = Self.text(row.detail, size: 12, weight: .regular, color: .secondaryLabelColor)
      let text = NSStackView(views: [heading, detail])
      text.orientation = .vertical
      text.alignment = .leading
      text.spacing = 1
      text.translatesAutoresizingMaskIntoConstraints = false
      let line = NSView()
      line.translatesAutoresizingMaskIntoConstraints = false
      line.addSubview(icon)
      line.addSubview(text)
      // Icons sit in one 22 pt column, centred on their heading; the text gets a definite width so it wraps.
      NSLayoutConstraint.activate([
        icon.leadingAnchor.constraint(equalTo: line.leadingAnchor, constant: 2),
        icon.widthAnchor.constraint(equalToConstant: 22),
        icon.heightAnchor.constraint(equalToConstant: 22),
        icon.centerYAnchor.constraint(equalTo: heading.centerYAnchor),
        text.leadingAnchor.constraint(equalTo: line.leadingAnchor, constant: 36),
        text.trailingAnchor.constraint(equalTo: line.trailingAnchor),
        text.topAnchor.constraint(equalTo: line.topAnchor),
        text.bottomAnchor.constraint(equalTo: line.bottomAnchor),
        heading.widthAnchor.constraint(equalTo: text.widthAnchor),
        detail.widthAnchor.constraint(equalTo: text.widthAnchor),
      ])
      rowViews.append(line)
      lastText = detail
    }
    switchRow = rowViews.last ?? NSView()
    switchText = lastText ?? NSTextField()
    super.init(frame: .zero)
    setAccessibilityElement(true)
    setAccessibilityRole(.group)
    setAccessibilityLabel(content.title)

    card.translatesAutoresizingMaskIntoConstraints = false
    let title = Self.text(content.title, size: 19, weight: .bold, color: .labelColor)
    title.alignment = .center
    let picture = WhatsNewButtonPicture(buttonScale: 0.66)
    let body = NSStackView(views: [title, picture] + rowViews)
    body.orientation = .vertical
    body.alignment = .centerX
    body.spacing = 10
    body.setCustomSpacing(10, after: title)
    body.setCustomSpacing(14, after: picture)
    body.translatesAutoresizingMaskIntoConstraints = false
    let done = NSButton(title: "Done", target: self, action: #selector(done))
    done.bezelStyle = .rounded
    done.controlSize = .large
    // Only marks Done as the default (blue) button. The presenter's key monitor is what actually maps Return to it,
    // because Reconnect Now in the window behind answers Return too.
    done.keyEquivalent = "\r"
    done.font = .systemFont(ofSize: NSFont.systemFontSize(for: .large), weight: .semibold)
    done.setAccessibilityHelp("Closes What's New")
    done.translatesAutoresizingMaskIntoConstraints = false
    doneButton = done
    card.addSubview(body)
    card.addSubview(done)
    for layer in [frost, veil] as [NSView] {
      layer.frame = bounds
      layer.autoresizingMask = [.width, .height]
      addSubview(layer)
    }
    veil.drawing = { [weak self] in self?.drawVeil() }
    addSubview(card)

    // The picture takes spare height up to a cap; anything left over opens up above Done.
    let pictureGrows = picture.heightAnchor.constraint(equalToConstant: 132)
    pictureGrows.priority = .defaultLow
    NSLayoutConstraint.activate([
      body.topAnchor.constraint(equalTo: card.topAnchor, constant: 16),
      body.leadingAnchor.constraint(equalTo: card.leadingAnchor, constant: 16),
      body.trailingAnchor.constraint(equalTo: card.trailingAnchor, constant: -16),
      done.leadingAnchor.constraint(equalTo: card.leadingAnchor, constant: 16),
      done.trailingAnchor.constraint(equalTo: card.trailingAnchor, constant: -16),
      done.topAnchor.constraint(greaterThanOrEqualTo: body.bottomAnchor, constant: 14),
      done.bottomAnchor.constraint(equalTo: card.bottomAnchor, constant: -16),
      title.widthAnchor.constraint(equalTo: body.widthAnchor),
      picture.widthAnchor.constraint(equalTo: body.widthAnchor),
      picture.heightAnchor.constraint(greaterThanOrEqualToConstant: 58),
      picture.heightAnchor.constraint(lessThanOrEqualToConstant: 132),
      pictureGrows,
      card.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 18),
      card.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -Self.arrowLane),
      // Covers the window header completely rather than cutting through it.
      card.topAnchor.constraint(equalTo: topAnchor, constant: 8),
    ] + rowViews.map { $0.widthAnchor.constraint(equalTo: body.widthAnchor) })
  }
  required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

  private static func text(_ string: String, size: CGFloat, weight: NSFont.Weight, color: NSColor) -> NSTextField {
    let label = NSTextField(wrappingLabelWithString: string)
    label.font = .systemFont(ofSize: size, weight: weight)
    label.textColor = color
    label.isSelectable = false
    label.translatesAutoresizingMaskIntoConstraints = false
    // Text is never squeezed: if space runs short the card grows instead (and stops promising "below").
    label.setContentCompressionResistancePriority(.required, for: .vertical)
    return label
  }

  override var isFlipped: Bool { true }
  override var acceptsFirstResponder: Bool { true }

  /// The row holding the Reconnect button switch, in this view's coordinates; nil when it isn't on screen.
  var spotlightRect: NSRect? {
    guard let target = Self.findTarget(in: superview), !target.isHiddenOrHasHiddenAncestor,
      let row = target.superview else { return nil }
    return convert(row.bounds, from: row).insetBy(dx: -8, dy: -6)
  }

  static func findTarget(in view: NSView?) -> NSView? {
    guard let view, !(view is WhatsNewSpotlightView) else { return nil }
    if view.accessibilityLabel() == targetAccessibilityLabel { return view }
    for subview in view.subviews { if let found = findTarget(in: subview) { return found } }
    return nil
  }

  override func layout() {
    // The card ends just above the lobby status line over the highlighted row. If the window is too short for that,
    // it keeps its own height and may overlap the row; without the switch on screen it uses its natural height.
    NSLayoutConstraint.deactivate(cardPlacement)
    let spot = spotlightRect
    if let spot {
      let bottom = card.bottomAnchor.constraint(equalTo: topAnchor, constant: spot.minY - Self.gapAboveSpotlight)
      bottom.priority = .defaultHigh
      cardPlacement = [bottom]
    } else {
      cardPlacement = []
    }
    NSLayoutConstraint.activate(cardPlacement)
    super.layout()
    isCardAboveSpotlight = spot.map { card.frame.maxY <= $0.minY - 4 } ?? false
    let wording = spot == nil ? WhatsNewContent.switchElsewhere
      : isCardAboveSpotlight ? WhatsNewContent.switchBelow : WhatsNewContent.switchHighlighted
    if switchText.stringValue != wording { switchText.stringValue = wording; needsLayout = true }
    frost.cutOut = spot
    veil.needsDisplay = true
  }

  /// Everything but the highlighted row is blurred (`frost`) and tinted here, darker than the row in both
  /// appearances, so the row is the brightest thing in the window.
  private func drawVeil() {
    let spot = spotlightRect
    let dim = NSBezierPath(rect: bounds)
    if let spot { dim.append(NSBezierPath(roundedRect: spot, xRadius: 9, yRadius: 9)) }
    dim.windingRule = .evenOdd
    NSColor.black.withAlphaComponent(isDark ? 0.40 : 0.30).setFill()
    dim.fill()
    guard let spot else { return }
    NSColor.controlAccentColor.set()
    let ring = NSBezierPath(roundedRect: spot, xRadius: 9, yRadius: 9)
    ring.lineWidth = 2
    ring.stroke()
    guard isCardAboveSpotlight else { return }
    // The arrow: from the card's edge beside "Turn it off any time", across, one rounded corner, down onto the switch.
    let rowFrame = convert(switchRow.bounds, from: switchRow)
    let start = NSPoint(x: card.frame.maxX, y: rowFrame.midY)
    let end = NSPoint(x: spot.maxX - 34, y: spot.minY - 5)
    let corner: CGFloat = 8
    NSBezierPath(ovalIn: NSRect(x: start.x - 3, y: start.y - 3, width: 6, height: 6)).fill()
    let arrow = NSBezierPath()
    arrow.move(to: start)
    arrow.line(to: NSPoint(x: end.x - corner, y: start.y))
    arrow.curve(to: NSPoint(x: end.x, y: start.y + corner), controlPoint1: NSPoint(x: end.x, y: start.y),
      controlPoint2: NSPoint(x: end.x, y: start.y))
    arrow.line(to: end)
    arrow.lineWidth = 2
    arrow.lineCapStyle = .round
    arrow.stroke()
    let head = NSBezierPath()
    head.move(to: NSPoint(x: end.x - 6, y: end.y - 8))
    head.line(to: NSPoint(x: end.x, y: end.y + 1))
    head.line(to: NSPoint(x: end.x + 6, y: end.y - 8))
    head.close()
    head.fill()
  }

  private var isDark: Bool { effectiveAppearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua }

  override func viewDidChangeEffectiveAppearance() {
    super.viewDidChangeEffectiveAppearance()
    veil.needsDisplay = true
  }

  // Clicks inside the spotlight reach the real switch; everything else is blocked while this is up.
  override func hitTest(_ point: NSPoint) -> NSView? {
    let local = convert(point, from: superview)
    if card.frame.contains(local) { return super.hitTest(point) ?? self }
    if let spot = spotlightRect, spot.contains(local) { return nil }
    return super.hitTest(point) ?? (bounds.contains(local) ? self : nil)
  }
  override func mouseDown(with event: NSEvent) {}
  override func rightMouseDown(with event: NSEvent) {}
  override func scrollWheel(with event: NSEvent) {}
  override func keyDown(with event: NSEvent) {
    if event.keyCode == 36 || event.keyCode == 76 { onDone() } else { super.keyDown(with: event) }
  }
  override func cancelOperation(_ sender: Any?) { onDone() }
  @objc private func done() { onDone() }
}
