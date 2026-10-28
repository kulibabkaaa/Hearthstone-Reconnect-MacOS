import AppKit

/// Takes clicks but never becomes key, so Hearthstone keeps the keyboard after a click.
final class ReconnectButtonPanel: NSPanel {
  override var canBecomeKey: Bool { false }
  override var canBecomeMain: Bool { false }
}

/// Draws the button on a fixed 124×38 canvas scaled to the panel, like `LobbyCanvas`, so a resized
/// button looks identical. Every phase fits the same width; long titles shrink a little (to 10.5 pt), then truncate.
final class ReconnectButtonCanvas: NSView {
  static let baseSize = NSSize(width: ReconnectButtonLayout.baseSize.width, height: ReconnectButtonLayout.baseSize.height)
  private static let spinPeriod: TimeInterval = 1
  var buttonAppearance = ReconnectButtonModel.appearance(for: .ready) {
    didSet {
      guard buttonAppearance != oldValue else { return }
      if !buttonAppearance.isClickable { isPressed = false }
      updateSpinner()
      updateAccessibility()
      needsDisplay = true
    }
  }
  /// Extra gate checked on every click (false while layout mode is on).
  var allowsClick: () -> Bool = { true }
  var onClick: (() -> Void)?
  private var isPressed = false
  private var isHovered = false
  private var spinAngle: CGFloat = 0
  private var spinTimer: Timer?
  override var isFlipped: Bool { true }

  override init(frame frameRect: NSRect) {
    super.init(frame: frameRect)
    setAccessibilityElement(true)
    setAccessibilityRole(.button)
    updateAccessibility()
  }
  required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

  var canClick: Bool { buttonAppearance.isClickable && allowsClick() }
  var isSpinning: Bool { spinTimer != nil }

  // The panel never becomes key, so the first click must act straight away.
  override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
  override func mouseDown(with event: NSEvent) {
    guard canClick else { return }
    isPressed = true
    needsDisplay = true
  }
  override func mouseDragged(with event: NSEvent) {
    guard canClick else { return }
    let inside = bounds.contains(convert(event.locationInWindow, from: nil))
    if inside != isPressed { isPressed = inside; needsDisplay = true }
  }
  override func mouseUp(with event: NSEvent) {
    let inside = bounds.contains(convert(event.locationInWindow, from: nil))
    let fire = isPressed && inside && canClick
    isPressed = false
    needsDisplay = true
    if fire { onClick?() }
  }
  override func updateTrackingAreas() {
    super.updateTrackingAreas()
    trackingAreas.forEach(removeTrackingArea)
    // activeAlways: the panel is never key and the app is never active while Hearthstone is in front.
    addTrackingArea(NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect],
      owner: self, userInfo: nil))
  }
  override func mouseEntered(with event: NSEvent) { isHovered = true; needsDisplay = true }
  override func mouseExited(with event: NSEvent) { isHovered = false; needsDisplay = true }
  override func accessibilityPerformPress() -> Bool {
    guard canClick else { return false }
    onClick?()
    return true
  }
  override func viewDidMoveToWindow() {
    super.viewDidMoveToWindow()
    updateSpinner()
  }

  override func draw(_ dirtyRect: NSRect) {
    guard let context = NSGraphicsContext.current?.cgContext else { return }
    let base = Self.baseSize
    context.saveGState()
    defer { context.restoreGState() }
    context.scaleBy(x: bounds.width / base.width, y: bounds.height / base.height)
    let palette = Palette(tone: buttonAppearance.tone)
    let shape = NSRect(x: 0.5, y: 0.5, width: base.width - 1, height: base.height - 1)
    let radius = base.height * 0.18
    let background = NSBezierPath(roundedRect: shape, xRadius: radius, yRadius: radius)
    // Same fill and border tokens as the lobby canvas, so both blocks read as one family.
    let fillAlpha: CGFloat = isPressed ? 0.86 : 0.72
    let fillWhite: CGFloat = isPressed ? 0.10 : (isHovered && canClick ? 0.21 : 0.16)
    NSColor(calibratedWhite: fillWhite, alpha: fillAlpha).setFill()
    background.fill()
    palette.border.setStroke()
    background.lineWidth = 1
    background.stroke()

    let iconBox = NSRect(x: 10, y: (base.height - 20) / 2, width: 20, height: 20)
    drawIcon(in: iconBox, color: palette.icon)
    // 83 pt fits the longest title ("Reconnecting…") at the smallest size.
    let label = NSRect(x: 35, y: 0, width: base.width - 35 - 6, height: base.height)
    drawTitle(buttonAppearance.title, in: label, color: palette.text)
  }

  private func drawIcon(in box: NSRect, color: NSColor) {
    let symbol = buttonAppearance.tone == .success ? "checkmark" : "arrow.triangle.2.circlepath"
    let configuration = NSImage.SymbolConfiguration(pointSize: 15, weight: .semibold)
      .applying(NSImage.SymbolConfiguration(paletteColors: [color]))
    guard let image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)?
      .withSymbolConfiguration(configuration),
      let context = NSGraphicsContext.current?.cgContext else { return }
    let size = image.size
    let fit = min(box.width / max(size.width, 1), box.height / max(size.height, 1), 1)
    let drawSize = NSSize(width: size.width * fit, height: size.height * fit)
    context.saveGState()
    context.translateBy(x: box.midX, y: box.midY)
    if isSpinning { context.rotate(by: spinAngle) }
    image.draw(in: NSRect(x: -drawSize.width / 2, y: -drawSize.height / 2, width: drawSize.width, height: drawSize.height),
      from: .zero, operation: .sourceOver, fraction: 1, respectFlipped: true, hints: nil)
    context.restoreGState()
  }

  private func drawTitle(_ title: String, in rect: NSRect, color: NSColor) {
    var font = NSFont.systemFont(ofSize: 14, weight: .medium)
    // Shrink long titles down to 10.5 pt before truncating; the button itself never changes size.
    while font.pointSize > 10.5, (title as NSString).size(withAttributes: [.font: font]).width > rect.width {
      font = .systemFont(ofSize: font.pointSize - 0.5, weight: .medium)
    }
    let paragraph = NSMutableParagraphStyle()
    paragraph.lineBreakMode = .byTruncatingTail
    let height = font.ascender - font.descender + font.leading
    let box = NSRect(x: rect.minX, y: rect.minY + (rect.height - height) / 2, width: rect.width, height: height)
    (title as NSString).draw(in: box, withAttributes: [.font: font, .foregroundColor: color, .paragraphStyle: paragraph])
  }

  private func updateSpinner() {
    let shouldSpin = buttonAppearance.spinsIcon && window != nil
    if shouldSpin, spinTimer == nil {
      let started = Date()
      let timer = Timer(timeInterval: 1.0 / 60, repeats: true) { [weak self] _ in
        // Timers added to the main run loop fire on the main thread.
        MainActor.assumeIsolated {
          guard let self else { return }
          let elapsed = Date().timeIntervalSince(started).truncatingRemainder(dividingBy: Self.spinPeriod)
          self.spinAngle = CGFloat(elapsed / Self.spinPeriod) * 2 * .pi
          self.needsDisplay = true
        }
      }
      RunLoop.main.add(timer, forMode: .common)
      spinTimer = timer
    } else if !shouldSpin, let timer = spinTimer {
      timer.invalidate()
      spinTimer = nil
      spinAngle = 0
    }
  }
  private func updateAccessibility() {
    setAccessibilityLabel(buttonAppearance.title)
    setAccessibilityEnabled(buttonAppearance.isClickable)
  }

  private struct Palette {
    let icon: NSColor
    let text: NSColor
    let border: NSColor
    init(tone: ReconnectButtonTone) {
      let lobbyBorder = NSColor(calibratedWhite: 0.62, alpha: 0.45)
      switch tone {
      case .normal:
        icon = NSColor(calibratedRed: 0.30, green: 0.64, blue: 1.0, alpha: 1)
        text = .white
        border = lobbyBorder
      case .dimmed:
        icon = NSColor(calibratedWhite: 0.62, alpha: 0.75)
        text = NSColor(calibratedWhite: 0.80, alpha: 0.70)
        border = NSColor(calibratedWhite: 0.62, alpha: 0.30)
      case .success:
        icon = NSColor(calibratedRed: 0.48, green: 0.88, blue: 0.50, alpha: 1)
        text = .white
        border = NSColor(calibratedRed: 0.48, green: 0.88, blue: 0.50, alpha: 0.55)
      case .warning:
        icon = NSColor(calibratedRed: 0.98, green: 0.74, blue: 0.30, alpha: 1)
        text = NSColor(calibratedRed: 1.0, green: 0.88, blue: 0.66, alpha: 1)
        border = NSColor(calibratedRed: 0.98, green: 0.74, blue: 0.30, alpha: 0.60)
      case .error:
        icon = NSColor(calibratedRed: 0.95, green: 0.42, blue: 0.42, alpha: 1)
        text = NSColor(calibratedRed: 1.0, green: 0.80, blue: 0.80, alpha: 1)
        border = NSColor(calibratedRed: 0.95, green: 0.42, blue: 0.42, alpha: 0.60)
      }
    }
  }
}

/// The floating Reconnect button over Hearthstone (issue #44). One click asks for a reconnect, exactly
/// like the shortcut; the owner decides what that does. It moves and resizes only in layout mode.
///
/// API for the app:
/// - `updateGameWindow(frame:)` on every game-frame poll: shows the button over the game while Hearthstone
///   is frontmost, hides it otherwise (and cancels a running layout session it is part of).
/// - `hide()` when the setting is turned off.
/// - `render(_:)` with the current `ReconnectButtonPhase` (call again on each `nextChange`).
/// - `onReconnect` fires only for a clickable phase and only while layout mode is off.
/// - Layout mode, reset and opacity live on the shared `layoutSession`.
final class ReconnectButtonOverlayController: NSObject {
  let layoutSession: OverlayLayoutSession
  private let block: OverlayBlock
  private let canvas = ReconnectButtonCanvas(frame: NSRect(origin: .zero, size: ReconnectButtonCanvas.baseSize))
  var onReconnect: (() -> Void)?
  /// Whether Hearthstone is frontmost. The harness swaps this to simulate focus changes.
  var isGameFrontmost: () -> Bool = { HearthstoneApp.isFrontmost }
  private(set) var phase: ReconnectButtonPhase = .ready
  var isEditing: Bool { block.isEditing }
  var isVisible: Bool { block.panel.isVisible }
  var opacityPercent: Double {
    get { OverlayOpacity.percent }
    set { layoutSession.opacityPercent = newValue }
  }

  init(layoutSession: OverlayLayoutSession = OverlayLayoutSession()) {
    self.layoutSession = layoutSession
    let panel = ReconnectButtonPanel(contentRect: NSRect(origin: .zero, size: ReconnectButtonCanvas.baseSize),
      styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
    block = OverlayBlock(id: .reconnectButton, panel: panel, baseSize: ReconnectButtonCanvas.baseSize,
      keys: OverlayLayoutKeys(originX: DefaultsKey.reconnectButtonOriginX,
        originY: DefaultsKey.reconnectButtonOriginY, scale: DefaultsKey.reconnectButtonScale),
      defaultOrigin: { scale, gameFrame in
        ReconnectButtonLayout.defaultNormalizedOrigin(scale: scale, gameFrame: gameFrame)
      })
    super.init()
    panel.ignoresMouseEvents = false
    panel.contentView = canvas
    canvas.allowsClick = { [weak self] in !(self?.layoutSession.isActive ?? true) }
    canvas.onClick = { [weak self] in self?.onReconnect?() }
    block.onPanelResize = { [weak self] in self?.canvas.needsDisplay = true }
    layoutSession.register(block)
  }

  func updateGameWindow(frame: NSRect?) {
    let changed = frame != block.gameFrame
    if let frame { block.gameFrame = frame }
    guard frame != nil, isGameFrontmost() else { hide(); return }
    if !isEditing && (changed || !block.panel.isVisible) { block.restoreFrame() }
    block.panel.orderFrontRegardless()
    if isEditing { layoutSession.refreshHint(); block.editor.orderFrontRegardless() }
  }
  /// Hides the button. A layout session it is part of is cancelled for every block.
  func hide() {
    if isEditing { layoutSession.finish(save: false) }
    block.panel.orderOut(nil)
    block.editor.orderOut(nil)
  }
  func render(_ phase: ReconnectButtonPhase) {
    self.phase = phase
    canvas.buttonAppearance = ReconnectButtonModel.appearance(for: phase)
  }
  /// Resets only the button block. `layoutSession.resetLayouts()` resets every block.
  func resetLayout() { block.resetLayout() }

  #if DEBUG
  var diagnosticBlock: OverlayBlock { block }
  var diagnosticCanvas: ReconnectButtonCanvas { canvas }
  #endif
}
