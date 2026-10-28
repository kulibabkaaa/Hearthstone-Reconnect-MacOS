import AppKit

/// Takes clicks but never becomes key, so Hearthstone keeps the keyboard after a click.
final class ReconnectButtonPanel: NSPanel {
  override var canBecomeKey: Bool { false }
  override var canBecomeMain: Bool { false }
}

/// Draws the button on a fixed 176×60 canvas scaled to the panel, like `LobbyCanvas`, so a resized
/// button looks identical. Every phase fits the same width; one 18 pt title size; only a title too long to fit shrinks.
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
  /// Called by the controller after the panel is shown or hidden, so the spinner only runs on screen.
  func visibilityChanged() { updateSpinner() }
  /// With Reduce Motion on, "Reconnecting…" fades the icon in and out instead of spinning it.
  static var reducesMotion: Bool { NSWorkspace.shared.accessibilityDisplayShouldReduceMotion }

  override func draw(_ dirtyRect: NSRect) {
    guard let context = NSGraphicsContext.current?.cgContext else { return }
    let base = Self.baseSize
    context.saveGState()
    defer { context.restoreGState() }
    context.scaleBy(x: bounds.width / base.width, y: bounds.height / base.height)
    let palette = Palette(tone: buttonAppearance.tone)
    // Proportions measured from the issue #44 mockup at its native size: a frosted rim (~11 pt) around
    // a near-opaque dark pill. The rim's edge is soft: a few faint strokes, no crisp hairline.
    let rimRect = NSRect(origin: .zero, size: base)
    palette.rimFill.setFill()
    NSBezierPath(roundedRect: rimRect, xRadius: 15, yRadius: 15).fill()
    for (inset, alpha) in [(0.5, 0.20), (1.5, 0.12), (2.5, 0.06)] as [(CGFloat, CGFloat)] {
      let edge = NSBezierPath(roundedRect: rimRect.insetBy(dx: inset, dy: inset), xRadius: 15 - inset, yRadius: 15 - inset)
      edge.lineWidth = 1
      palette.edge.withAlphaComponent(palette.edge.alphaComponent * alpha / 0.20).setStroke()
      edge.stroke()
    }
    let pillWhite: CGFloat = isPressed ? 0.12 : (isHovered && canClick ? 0.24 : 0.184)
    NSColor(calibratedWhite: pillWhite, alpha: 0.93).setFill()
    NSBezierPath(roundedRect: NSRect(x: 11, y: 10.5, width: base.width - 22, height: base.height - 21),
      xRadius: 10, yRadius: 10).fill()

    drawIcon(center: NSPoint(x: 35, y: base.height / 2), palette: palette)
    // The mockup's text starts at 64 pt; the box runs to 6 pt inside the pill's right edge.
    drawTitle(buttonAppearance.title, in: NSRect(x: 64, y: 0, width: base.width - 11 - 6 - 64, height: base.height),
      color: palette.text)
  }

  /// The mockup's icon: two bold arcs with arrowheads, about 30 pt across, filled top-to-bottom with a
  /// gradient. Success shows a check mark in the same style.
  private func drawIcon(center: NSPoint, palette: Palette) {
    guard let context = NSGraphicsContext.current?.cgContext else { return }
    context.saveGState()
    defer { context.restoreGState() }
    context.translateBy(x: center.x, y: center.y)
    context.scaleBy(x: 1, y: -1)   // y up from here, so angles read like a clock face
    var alpha: CGFloat = 1
    if isSpinning {
      if Self.reducesMotion { alpha = 0.6 + 0.4 * cos(spinAngle) } else { context.rotate(by: -spinAngle) }
    }
    let colors = [palette.iconTop.cgColor, palette.iconBottom.cgColor] as CFArray
    guard let gradient = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(), colors: colors, locations: [0, 1]) else { return }
    // Fill each piece solid, then paint the gradient over just those pixels. Filling pieces one by one
    // keeps the overlap where an arrowhead meets its arc filled, whatever the outlines' winding.
    context.setAlpha(alpha)
    context.beginTransparencyLayer(auxiliaryInfo: nil)
    context.setFillColor(CGColor(gray: 1, alpha: 1))
    for piece in buttonAppearance.tone == .success ? [Self.checkPath] : Self.arrowPieces {
      context.addPath(piece)
      context.fillPath()
    }
    context.setBlendMode(.sourceIn)
    context.drawLinearGradient(gradient, start: CGPoint(x: 0, y: 15), end: CGPoint(x: 0, y: -15), options: [])
    context.endTransparencyLayer()
  }

  private static let arrowPieces: [CGPath] = {
    let radius: CGFloat = 11.2, width: CGFloat = 4.4
    var pieces: [CGPath] = []
    for turn in [0.0, CGFloat.pi] {
      // Each arc runs clockwise over ~140° and ends in an arrowhead pointing along the turn.
      let start = 160 * CGFloat.pi / 180 + turn, end = 20 * CGFloat.pi / 180 + turn
      let arc = CGMutablePath()
      arc.addArc(center: .zero, radius: radius, startAngle: start, endAngle: end, clockwise: true)
      pieces.append(arc.copy(strokingWithWidth: width, lineCap: .butt, lineJoin: .round, miterLimit: 1))
      let tip = CGPoint(x: radius * cos(end), y: radius * sin(end))
      let along = CGPoint(x: sin(end), y: -cos(end)), out = CGPoint(x: cos(end), y: sin(end))
      let head: CGFloat = 5.4, length: CGFloat = 6.2
      let arrowhead = CGMutablePath()
      arrowhead.move(to: CGPoint(x: tip.x + along.x * length * 0.75, y: tip.y + along.y * length * 0.75))
      arrowhead.addLine(to: CGPoint(x: tip.x - along.x * length * 0.25 + out.x * head, y: tip.y - along.y * length * 0.25 + out.y * head))
      arrowhead.addLine(to: CGPoint(x: tip.x - along.x * length * 0.25 - out.x * head, y: tip.y - along.y * length * 0.25 - out.y * head))
      arrowhead.closeSubpath()
      pieces.append(arrowhead)
    }
    return pieces
  }()
  private static let checkPath: CGPath = {
    let line = CGMutablePath()
    line.move(to: CGPoint(x: -10, y: 0))
    line.addLine(to: CGPoint(x: -3.5, y: -7))
    line.addLine(to: CGPoint(x: 10.5, y: 8))
    return line.copy(strokingWithWidth: 4, lineCap: .round, lineJoin: .round, miterLimit: 1)
  }()

  /// One size for every state, as the mockup's; only a title that can't fit at 18 pt shrinks (to 11 pt at most).
  static let titleFontSize: CGFloat = 18
  static func titleFont(for title: String, width: CGFloat) -> NSFont {
    var font = NSFont.systemFont(ofSize: titleFontSize, weight: .medium)
    while font.pointSize > 11, (title as NSString).size(withAttributes: titleAttributes(font)).width > width {
      font = .systemFont(ofSize: font.pointSize - 0.5, weight: .medium)
    }
    return font
  }
  private static func titleAttributes(_ font: NSFont) -> [NSAttributedString.Key: Any] {
    // The mockup's text is set a little wider than the system default.
    [.font: font, .kern: font.pointSize * 0.015]
  }
  static var titleWidth: CGFloat { baseSize.width - 11 - 6 - 64 }

  private func drawTitle(_ title: String, in rect: NSRect, color: NSColor) {
    let font = Self.titleFont(for: title, width: rect.width)
    let paragraph = NSMutableParagraphStyle()
    paragraph.lineBreakMode = .byTruncatingTail
    // Centre the capitals (not the line box) on the button, as the mockup does.
    let baseline = rect.midY + font.capHeight / 2
    let height = font.ascender - font.descender + font.leading
    let box = NSRect(x: rect.minX, y: baseline - font.ascender, width: rect.width, height: height)
    var attributes = Self.titleAttributes(font)
    attributes[.foregroundColor] = color
    attributes[.paragraphStyle] = paragraph
    (title as NSString).draw(in: box, withAttributes: attributes)
  }

  private func updateSpinner() {
    let shouldSpin = buttonAppearance.spinsIcon && window?.isVisible == true
    if shouldSpin, spinTimer == nil {
      let started = Date()
      let timer = Timer(timeInterval: 1.0 / 60, repeats: true) { [weak self] timer in
        // Timers added to the main run loop fire on the main thread.
        MainActor.assumeIsolated {
          guard let self else { timer.invalidate(); return }
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
    let iconTop: NSColor
    let iconBottom: NSColor
    let text: NSColor
    let edge: NSColor
    let rimFill: NSColor
    init(tone: ReconnectButtonTone) {
      rimFill = NSColor(calibratedRed: 1, green: 0.94, blue: 0.86, alpha: tone == .dimmed ? 0.12 : 0.20)
      switch tone {
      case .normal:
        iconTop = NSColor(calibratedRed: 0.0, green: 0.85, blue: 0.96, alpha: 1)
        iconBottom = NSColor(calibratedRed: 0.05, green: 0.40, blue: 0.88, alpha: 1)
        text = NSColor(calibratedWhite: 0.91, alpha: 1)
        edge = NSColor(calibratedWhite: 1, alpha: 0.20)
      case .dimmed:
        iconTop = NSColor(calibratedWhite: 0.66, alpha: 0.8)
        iconBottom = NSColor(calibratedWhite: 0.48, alpha: 0.8)
        text = NSColor(calibratedWhite: 0.80, alpha: 0.65)
        edge = NSColor(calibratedWhite: 1, alpha: 0.10)
      case .success:
        iconTop = NSColor(calibratedRed: 0.62, green: 0.95, blue: 0.58, alpha: 1)
        iconBottom = NSColor(calibratedRed: 0.22, green: 0.72, blue: 0.36, alpha: 1)
        text = NSColor(calibratedWhite: 0.91, alpha: 1)
        edge = NSColor(calibratedRed: 0.48, green: 0.88, blue: 0.50, alpha: 0.60)
      case .warning:
        iconTop = NSColor(calibratedRed: 1.0, green: 0.84, blue: 0.40, alpha: 1)
        iconBottom = NSColor(calibratedRed: 0.95, green: 0.58, blue: 0.16, alpha: 1)
        text = NSColor(calibratedRed: 1.0, green: 0.87, blue: 0.64, alpha: 1)
        edge = NSColor(calibratedRed: 0.98, green: 0.74, blue: 0.30, alpha: 0.60)
      case .error:
        iconTop = NSColor(calibratedRed: 1.0, green: 0.55, blue: 0.52, alpha: 1)
        iconBottom = NSColor(calibratedRed: 0.86, green: 0.26, blue: 0.28, alpha: 1)
        text = NSColor(calibratedRed: 1.0, green: 0.80, blue: 0.80, alpha: 1)
        edge = NSColor(calibratedRed: 0.95, green: 0.42, blue: 0.42, alpha: 0.60)
      }
    }
  }
}

/// The floating Reconnect button over Hearthstone (issue #44). One click asks for a reconnect, exactly
/// like the shortcut; the owner decides what that does. It moves and resizes only in layout mode.
///
/// API for the app:
/// - `updateGameWindow(frame:)` on every game-frame poll, and when the match state changes: shows the button
///   over the game while `ReconnectButtonVisibilityPolicy.shouldShow` says so (setting on, Hearthstone
///   frontmost, and in a match, in layout mode, or no match detector), hides it otherwise (and cancels a
///   running layout session it is part of).
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
  /// Whether the Reconnect button setting is on.
  var isEnabled: () -> Bool = { true }
  /// Whether the match detector is attached. Without it the button shows whenever Hearthstone is frontmost.
  var isMatchDetectorAvailable: () -> Bool = { true }
  /// Whether the player is in a match. With a detector, the button shows outside layout mode only then.
  var isInMatch: () -> Bool = { false }
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
    block.onEditingPresented = { [weak self] in self?.canvas.visibilityChanged() }
    // A layout session begun outside a match shows the button; when it ends the button goes away again.
    block.onEditingFinished = { [weak self] in
      guard let self, !self.shouldShow(hasGameWindow: true) else { return }
      self.hide()
    }
    layoutSession.register(block)
  }

  func updateGameWindow(frame: NSRect?) {
    let changed = frame != block.gameFrame
    if let frame { block.gameFrame = frame }
    guard shouldShow(hasGameWindow: frame != nil) else {
      hide()
      // Keep the hidden button placed on the game, so a layout session begun before the next frontmost
      // poll (or outside a match) starts (and saves) from the right spot.
      if changed, frame != nil { block.restoreFrame() }
      return
    }
    if !isEditing && (changed || !block.panel.isVisible) { block.restoreFrame() }
    block.panel.orderFrontRegardless()
    canvas.visibilityChanged()
    if isEditing { layoutSession.refreshHint(); block.editor.orderFrontRegardless() }
  }
  private func shouldShow(hasGameWindow: Bool) -> Bool {
    ReconnectButtonVisibilityPolicy.shouldShow(buttonEnabled: isEnabled(), hasGameWindow: hasGameWindow,
      gameFrontmost: isGameFrontmost(), detectorAvailable: isMatchDetectorAvailable(), inMatch: isInMatch(),
      isEditingLayout: isEditing,
      isShowingFeedback: isVisible && ReconnectButtonVisibilityPolicy.isReconnectFeedback(phase))
  }
  /// Hides the button. A layout session it is part of is cancelled for every block.
  func hide() {
    if isEditing { layoutSession.finish(save: false) }
    block.panel.orderOut(nil)
    block.editor.orderOut(nil)
    canvas.visibilityChanged()
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
