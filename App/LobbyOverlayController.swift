import AppKit
import Carbon

private final class LobbyEditingPanel: NSPanel {
  var onEditCommand: ((Bool) -> Void)?

  // A nonactivating panel can receive its own keys while Hearthstone remains
  // frontmost. This keeps bare Escape and Return out of the global hotkey set.
  override var canBecomeKey: Bool { true }
  override var canBecomeMain: Bool { false }

  override func keyDown(with event: NSEvent) {
    if let save = lobbyEditCommand(for: event.keyCode) {
      onEditCommand?(save)
    } else {
      super.keyDown(with: event)
    }
  }
}

private func lobbyEditCommand(for keyCode: UInt16) -> Bool? {
  switch keyCode {
  case UInt16(kVK_Escape):
    false
  case UInt16(kVK_Return), UInt16(kVK_ANSI_KeypadEnter):
    true
  default:
    nil
  }
}

// A separate hit surface leaves the actual lobby canvas unchanged during editing.
private final class LobbyLayoutSurface: NSView {
  var onEditCommand: ((Bool) -> Void)?
  var onResize: ((NSPoint, NSRect) -> Void)?
  private var resizeStart: NSRect?
  private var mouseStart = NSPoint.zero
  override var acceptsFirstResponder: Bool { true }
  override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
  override func resetCursorRects() {
    addCursorRect(bounds, cursor: .openHand)
    addCursorRect(NSRect(x: bounds.maxX - 24, y: 0, width: 24, height: 24), cursor: .crosshair)
  }
  override func mouseDown(with event: NSEvent) {
    guard let window else { return }
    let point = convert(event.locationInWindow, from: nil)
    if point.x >= bounds.maxX - 24 && point.y <= 24 {
      resizeStart = window.frame
      mouseStart = NSEvent.mouseLocation
    } else {
      resizeStart = nil
      window.performDrag(with: event)
    }
  }
  override func mouseDragged(with event: NSEvent) {
    guard let resizeStart else { return }
    let point = NSEvent.mouseLocation
    onResize?(NSPoint(x: point.x - mouseStart.x, y: point.y - mouseStart.y), resizeStart)
  }
  override func mouseUp(with event: NSEvent) { resizeStart = nil }
  override func keyDown(with event: NSEvent) {
    if let save = lobbyEditCommand(for: event.keyCode) {
      onEditCommand?(save)
    } else {
      super.keyDown(with: event)
    }
  }
  override func draw(_ dirtyRect: NSRect) {
    NSColor(calibratedRed: 0.96, green: 0.79, blue: 0.38, alpha: 1).setStroke()
    let outline = NSBezierPath(roundedRect: bounds.insetBy(dx: 1, dy: 1), xRadius: 6, yRadius: 6)
    outline.lineWidth = 2
    outline.stroke()
    let grip = NSBezierPath()
    for offset in stride(from: CGFloat(6), through: 14, by: 4) {
      grip.move(to: NSPoint(x: bounds.maxX - offset - 3, y: 4))
      grip.line(to: NSPoint(x: bounds.maxX - 4, y: offset + 3))
    }
    grip.lineWidth = 2
    grip.stroke()
  }
}

private final class LobbyCanvas: NSView {
  var rows: [LobbyRatingRow] = []
  var summary: LobbyAverageSummary?
  override var isFlipped: Bool { true }
  private let gold = NSColor(calibratedRed: 0.96, green: 0.79, blue: 0.38, alpha: 1)

  override func draw(_ dirtyRect: NSRect) {
    guard let context = NSGraphicsContext.current?.cgContext else { return }
    context.saveGState()
    defer { context.restoreGState() }
    context.scaleBy(x: bounds.width / 208, y: bounds.height / 233)
    let background = NSBezierPath(roundedRect: NSRect(x: 0.5, y: 0.5, width: 207, height: 232), xRadius: 6, yRadius: 6)
    NSColor(calibratedWhite: 0.16, alpha: 0.72).setFill()
    background.fill()
    NSColor(calibratedWhite: 0.62, alpha: 0.45).setStroke()
    background.lineWidth = 1
    background.stroke()
    let titleFont = NSFont.systemFont(ofSize: 13, weight: .semibold)
    text("Lobby info", rect: NSRect(x: 12, y: 10, width: 70, height: 18), font: titleFont, color: .white)
    if let summary {
      let font = NSFont.monospacedDigitSystemFont(ofSize: 9, weight: .semibold)
      let average = "· AVG \(summary.average.formatted())"
      let difference = "· \(summary.difference >= 0 ? "+" : "")\(summary.difference.formatted())"
      let titleWidth = ("Lobby info" as NSString).size(withAttributes: [.font: titleFont]).width
      let averageWidth = (average as NSString).size(withAttributes: [.font: font]).width
      let x = 12 + titleWidth + 8
      text(average, rect: NSRect(x: x, y: 10, width: averageWidth, height: 18), font: font, color: gold)
      let tone = summary.difference > 0 ? NSColor(calibratedRed: 0.48, green: 0.88, blue: 0.50, alpha: 1)
        : summary.difference < 0 ? NSColor(calibratedRed: 0.95, green: 0.42, blue: 0.42, alpha: 1)
        : NSColor(calibratedWhite: 0.78, alpha: 1)
      text(difference, rect: NSRect(x: x + averageWidth + 6, y: 10, width: 196 - x - averageWidth - 6, height: 18), font: font, color: tone)
    }
    for (index, row) in rows.prefix(8).enumerated() {
      let y = CGFloat(36 + index * 23)
      text(row.name, rect: NSRect(x: 12, y: y, width: 72, height: 21),
        font: .systemFont(ofSize: 12, weight: row.isLocalPlayer ? .semibold : .regular),
        color: row.isLocalPlayer ? gold : NSColor(calibratedWhite: 0.92, alpha: 1))
      text(row.rank.map { "#\($0.formatted())" } ?? "", rect: NSRect(x: 90, y: y, width: 44, height: 21),
        font: .monospacedDigitSystemFont(ofSize: 11, weight: .medium),
        color: NSColor(calibratedWhite: 0.74, alpha: 1), alignment: .right)
      let rating: String
      let color: NSColor
      switch row.rating {
      case .exact(let value): rating = value.formatted(); color = row.isLocalPlayer ? gold : .white
      case .belowCutoff(let cutoff): rating = "<\(cutoff.formatted())"; color = NSColor(calibratedWhite: 0.72, alpha: 1)
      case .unavailable: rating = "—"; color = .systemYellow
      }
      text(rating, rect: NSRect(x: 140, y: y, width: 56, height: 21),
        font: .monospacedDigitSystemFont(ofSize: 12, weight: .medium), color: color, alignment: .right)
    }
  }
  private func text(_ value: String, rect: NSRect, font: NSFont, color: NSColor, alignment: NSTextAlignment = .left) {
    let paragraph = NSMutableParagraphStyle()
    paragraph.alignment = alignment
    paragraph.lineBreakMode = .byTruncatingTail
    let height = font.ascender - font.descender + font.leading
    let box = NSRect(x: rect.minX, y: rect.minY + (rect.height - height) / 2, width: max(0, rect.width), height: height)
    (value as NSString).draw(in: box, withAttributes: [.font: font, .foregroundColor: color, .paragraphStyle: paragraph])
  }
}

final class LobbyOverlayController: NSObject, NSWindowDelegate {
  // Same fixed canvas, typography and colors as the HSTracker fork.
  private static let baseSize = NSSize(width: 208, height: 233)
  private let panel: LobbyEditingPanel
  private let editor: LobbyEditingPanel
  private let canvas = LobbyCanvas(frame: NSRect(origin: .zero, size: baseSize))
  private let editSurface = LobbyLayoutSurface()
  private let hintPanel: NSPanel
  private var gameFrame: NSRect?
  private var editStartFrame: NSRect?
  private var hasContent = false
  private var isPreview = false
  var onStatus: ((String) -> Void)?
  private var synchronizingEditor = false
  private(set) var isEditing = false

  var opacityPercent: Double {
    get { (UserDefaults.standard.object(forKey: DefaultsKey.lobbyOpacity) as? Double) ?? 100 }
    set {
      UserDefaults.standard.set(min(max(newValue, 10), 100), forKey: DefaultsKey.lobbyOpacity)
      applyOpacity()
    }
  }

  override init() {
    panel = LobbyEditingPanel(contentRect: NSRect(origin: .zero, size: Self.baseSize),
      styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
    editor = LobbyEditingPanel(contentRect: NSRect(origin: .zero, size: Self.baseSize),
      styleMask: [.titled, .resizable, .fullSizeContentView, .nonactivatingPanel], backing: .buffered, defer: false)
    hintPanel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 330, height: 32),
      styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
    super.init()
    for window in [panel, editor, hintPanel] {
      window.level = NSWindow.Level(rawValue: Int(CGWindowLevelForKey(.normalWindow)) + 1)
      window.isOpaque = false
      window.backgroundColor = .clear
      window.hasShadow = true
      window.hidesOnDeactivate = false
      window.isFloatingPanel = true
      window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .canJoinAllApplications, .ignoresCycle]
      window.isReleasedWhenClosed = false
      window.animationBehavior = .none
    }
    panel.delegate = self
    editor.delegate = self
    editor.level = NSWindow.Level(rawValue: panel.level.rawValue + 2)
    hintPanel.level = NSWindow.Level(rawValue: panel.level.rawValue + 7)
    editor.titleVisibility = .hidden
    editor.titlebarAppearsTransparent = true
    editor.hasShadow = false
    editor.minSize = NSSize(width: Self.baseSize.width * 0.75, height: Self.baseSize.height * 0.75)
    editor.maxSize = NSSize(width: Self.baseSize.width * 1.5, height: Self.baseSize.height * 1.5)
    for button: NSWindow.ButtonType in [.closeButton, .miniaturizeButton, .zoomButton] {
      editor.standardWindowButton(button)?.isHidden = true
    }
    editor.onEditCommand = { [weak self] save in
      self?.finishEditing(save: save)
    }
    editSurface.onEditCommand = { [weak self] save in
      self?.finishEditing(save: save)
    }
    build()
    buildHint()
    applyOpacity()
  }



  func show(rows: [LobbyRatingRow], summary: LobbyAverageSummary?, gameFrame: NSRect?) {
    isPreview = false
    hasContent = true
    render(rows, summary)
    updateGameWindow(frame: gameFrame)
  }

  func showPreview(gameFrame: NSRect) {
    isPreview = true
    hasContent = true
    self.gameFrame = gameFrame
    let names = ["Your player", "Opponent 2", "Opponent 3", "Opponent 4", "Opponent 5", "Opponent 6", "Opponent 7", "Opponent 8"]
    let rows = names.enumerated().map { index, name in
      LobbyRatingRow(position: index, name: name,
        rating: index == 7 ? .belowCutoff(8000) : .exact(9_932 - index * 300),
        rank: index == 7 ? nil : 834 + index * 900, isLocalPlayer: index == 0)
    }
    render(rows, LobbyAverageSummary(average: 8_555, difference: 1_377))
    restoreFrame()
  }

  // Capture events are deduplicated. Window visibility must not depend on new ratings.
  func updateGameWindow(frame: NSRect?) {
    let changed = frame != gameFrame
    if let frame { gameFrame = frame }
    guard frame != nil, hasContent else {
      if isEditing { finishEditing(save: false) }
      panel.orderOut(nil)
      hintPanel.orderOut(nil)
      editor.orderOut(nil)
      return
    }
    guard hearthstoneIsActive else {
      if isEditing { finishEditing(save: false) }
      panel.orderOut(nil)
      hintPanel.orderOut(nil)
      editor.orderOut(nil)
      return
    }
    if !isEditing && (changed || !panel.isVisible) { restoreFrame() }
    panel.orderFrontRegardless()
    if isEditing { positionHint(); hintPanel.orderFrontRegardless(); editor.orderFrontRegardless() }
  }

  func cancelAndClose() {
    if isEditing { finishEditing(save: false) }
    hasContent = false
    isPreview = false
    gameFrame = nil
    panel.orderOut(nil)
    hintPanel.orderOut(nil)
  }
  func close() { cancelAndClose() }
  func toggleEditing() { isEditing ? finishEditing(save: true) : beginEditing() }
  func resetLayout() {
    UserDefaults.standard.removeObject(forKey: DefaultsKey.lobbyOriginX)
    UserDefaults.standard.removeObject(forKey: DefaultsKey.lobbyOriginY)
    UserDefaults.standard.set(1.0, forKey: DefaultsKey.lobbyScale)
    restoreFrame()
    if isEditing {
      synchronizingEditor = true
      editor.setFrame(panel.frame, display: true)
      synchronizingEditor = false
    }
  }

  private var hearthstoneIsActive: Bool {
    NSWorkspace.shared.frontmostApplication?.bundleIdentifier == "unity.Blizzard Entertainment.Hearthstone"
  }
  private func beginEditing() {
    guard gameFrame != nil, hasContent else { return }
    editStartFrame = panel.frame
    isEditing = true
    synchronizingEditor = true
    editor.setFrame(panel.frame, display: true)
    synchronizingEditor = false
    NSRunningApplication.runningApplications(withBundleIdentifier: "unity.Blizzard Entertainment.Hearthstone").first?.activate()
    panel.orderFrontRegardless()
    editor.makeKeyAndOrderFront(nil)
    editor.makeFirstResponder(editSurface)
    positionHint()
    hintPanel.orderFrontRegardless()
    applyOpacity()
  }
  private func finishEditing(save: Bool) {
    guard isEditing else { return }
    if save { saveFrame() }
    else if let editStartFrame { panel.setFrame(editStartFrame, display: true) }
    isEditing = false
    editor.orderOut(nil)
    hintPanel.orderOut(nil)
    if isPreview { panel.orderOut(nil); isPreview = false; hasContent = false }
    applyOpacity()
  }
  private func resize(delta: NSPoint, from frame: NSRect) {
    let next = LobbyOverlayGeometry.resizedFrame(from: frame, delta: delta, baseSize: Self.baseSize)
    editor.setFrame(next, display: true)
  }
  func windowDidResize(_ notification: Notification) {
    if (notification.object as? NSWindow) === editor, isEditing, !synchronizingEditor {
      panel.setFrame(editor.frame, display: true)
    }
    applyContentScale()
  }
  func windowWillResize(_ sender: NSWindow, to frameSize: NSSize) -> NSSize {
    guard sender === editor else { return frameSize }
    let dx = (frameSize.width - sender.frame.width) / Self.baseSize.width
    let dy = (frameSize.height - sender.frame.height) / Self.baseSize.height
    let scale = LobbyOverlayGeometry.clampScale(sender.frame.width / Self.baseSize.width + (abs(dx) >= abs(dy) ? dx : dy))
    return NSSize(width: Self.baseSize.width * scale, height: Self.baseSize.height * scale)
  }
  func windowDidMove(_ notification: Notification) {
    guard (notification.object as? NSWindow) === editor, isEditing, !synchronizingEditor else { return }
    var frame = editor.frame
    let screen = NSScreen.screens.max { a, b in
      let x = a.frame.intersection(frame), y = b.frame.intersection(frame)
      return x.width * x.height < y.width * y.height
    }
    if !NSEvent.modifierFlags.contains(.option), let gameFrame {
      frame = LobbyOverlayGeometry.snappedFrame(frame, to: gameFrame)
      if let screen { frame = LobbyOverlayGeometry.snappedFrame(frame, to: screen.visibleFrame) }
    }
    if let screen { frame = LobbyOverlayGeometry.reachableFrame(frame, in: screen.visibleFrame) }
    if frame != editor.frame {
      synchronizingEditor = true
      editor.setFrame(frame, display: true)
      synchronizingEditor = false
    }
    panel.setFrame(frame, display: true)
  }
  private func applyOpacity() { panel.alphaValue = min(max(opacityPercent, 10), 100) / 100 }
  private func saveFrame() {
    guard let gameFrame else { return }
    let origin = LobbyOverlayGeometry.normalizedOrigin(frame: panel.frame, gameFrame: gameFrame)
    UserDefaults.standard.set(origin.x, forKey: DefaultsKey.lobbyOriginX)
    UserDefaults.standard.set(origin.y, forKey: DefaultsKey.lobbyOriginY)
    UserDefaults.standard.set(panel.frame.width / Self.baseSize.width, forKey: DefaultsKey.lobbyScale)
  }
  private func restoreFrame() {
    guard let gameFrame else { return }
    let scale = UserDefaults.standard.object(forKey: DefaultsKey.lobbyScale) as? Double ?? 1
    let defaultOriginY = 1.0 -
      (Double(Self.baseSize.height) * LobbyOverlayGeometry.clampScale(scale) + 20.0)
      / Double(gameFrame.height)
    let origin = CGPoint(x: UserDefaults.standard.object(forKey: DefaultsKey.lobbyOriginX) as? Double ?? 0.16,
      y: UserDefaults.standard.object(forKey: DefaultsKey.lobbyOriginY) as? Double
        ?? defaultOriginY)
    let screen = NSScreen.screens.max { a, b in
      let x = a.frame.intersection(gameFrame), y = b.frame.intersection(gameFrame)
      return x.width * x.height < y.width * y.height
    }
    panel.setFrame(LobbyOverlayGeometry.restoredFrame(origin: origin, scale: scale,
      baseSize: Self.baseSize, gameFrame: gameFrame, visibleFrame: screen?.frame ?? gameFrame), display: true)
  }
  private func positionHint() {
    guard let gameFrame else { return }
    hintPanel.setFrameOrigin(NSPoint(x: gameFrame.midX - hintPanel.frame.width / 2, y: gameFrame.maxY - 48))
  }
  private func buildHint() {
    let view = NSView(frame: NSRect(origin: .zero, size: hintPanel.frame.size))
    view.wantsLayer = true
    view.layer?.backgroundColor = NSColor(calibratedWhite: 0.12, alpha: 0.95).cgColor
    view.layer?.cornerRadius = 8
    let label = NSTextField(labelWithString: "Layout mode · Enter saves · Esc cancels")
    label.font = .systemFont(ofSize: 12, weight: .medium)
    label.textColor = .white
    label.alignment = .center
    label.frame = NSRect(x: 8, y: 8, width: 314, height: 17)
    view.addSubview(label)
    hintPanel.contentView = view
    hintPanel.ignoresMouseEvents = true
  }
  private func build() {
    panel.contentView = canvas
    canvas.setAccessibilityElement(true)
    canvas.setAccessibilityRole(.group)
    editSurface.frame = NSRect(origin: .zero, size: Self.baseSize)
    editSurface.autoresizingMask = [.width, .height]
    editSurface.onResize = { [weak self] delta, frame in self?.resize(delta: delta, from: frame) }
    editor.contentView = editSurface
    panel.ignoresMouseEvents = true
  }
  private func render(_ rows: [LobbyRatingRow], _ summary: LobbyAverageSummary?) {
    canvas.rows = rows
    canvas.summary = summary
    canvas.setAccessibilityLabel("Lobby info. " + rows.map { $0.name }.joined(separator: ", "))
    applyContentScale()
  }
  private func applyContentScale() { canvas.needsDisplay = true }

  #if DEBUG
  func beginDiagnosticEditing() { beginEditing() }
  func verifyDiagnosticEditing() {
    precondition(isEditing && editor.isVisible)
    precondition(editor.styleMask.contains(.nonactivatingPanel))
    precondition(editor.canBecomeKey && !editor.canBecomeMain)
    precondition(panel.styleMask.contains(.nonactivatingPanel) && panel.ignoresMouseEvents)
    precondition(panel.collectionBehavior.contains(.fullScreenAuxiliary))
    precondition(panel.collectionBehavior.contains(.canJoinAllApplications))
    precondition(editor.firstResponder === editSurface)
    editSurface.keyDown(with: diagnosticKeyEvent(kVK_Escape))
    precondition(!isEditing)
    showPreview(gameFrame: gameFrame!)
    beginEditing()
    precondition(editor.firstResponder === editSurface)
    editSurface.keyDown(with: diagnosticKeyEvent(kVK_Return))
    precondition(!isEditing)
    showPreview(gameFrame: gameFrame!)
    beginEditing()
    let original = panel.frame
    editor.setFrame(original.offsetBy(dx: 40, dy: -25), display: true)
    precondition(panel.frame == editor.frame)
    resize(delta: NSPoint(x: 20, y: -20), from: editor.frame)
    precondition(panel.frame == editor.frame)
    finishEditing(save: false)
    precondition(panel.frame == original)
    precondition(!editor.isVisible && !hintPanel.isVisible && panel.ignoresMouseEvents)
    showPreview(gameFrame: gameFrame!)
    beginEditing()
    editor.setFrame(panel.frame.offsetBy(dx: 40, dy: -25), display: true)
    let saved = panel.frame
    finishEditing(save: true)
    showPreview(gameFrame: gameFrame!)
    precondition(abs(panel.frame.minX - saved.minX) < 0.01)
    precondition(abs(panel.frame.minY - saved.minY) < 0.01)
    opacityPercent = 10
    precondition(panel.alphaValue == 0.1)
    opacityPercent = 100
    precondition(panel.alphaValue == 1)
    beginEditing()
    cancelAndClose()
    precondition(!panel.isVisible && !editor.isVisible && !hintPanel.isVisible)
    print("PASS: nonactivating edit-key routing, fullscreen policies, proxy drag/resize, cancel restoration, saved position, 10–100% opacity, cleanup")
  }
  private func diagnosticKeyEvent(_ keyCode: Int) -> NSEvent {
    guard let event = NSEvent.keyEvent(
      with: .keyDown,
      location: .zero,
      modifierFlags: [],
      timestamp: 0,
      windowNumber: editor.windowNumber,
      context: nil,
      characters: "",
      charactersIgnoringModifiers: "",
      isARepeat: false,
      keyCode: UInt16(keyCode)
    ) else {
      preconditionFailure("Couldn't create a diagnostic key event")
    }
    return event
  }
  func writeDiagnosticPNG(to url: URL) throws {
    guard let view = panel.contentView else { return }
    view.layoutSubtreeIfNeeded()
    guard let bitmap = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { return }
    view.cacheDisplay(in: view.bounds, to: bitmap)
    guard let data = bitmap.representation(using: .png, properties: [:]) else { return }
    try data.write(to: url, options: .atomic)
  }
  var diagnosticFrameSize: NSSize { panel.frame.size }
  #endif
}
