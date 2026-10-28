import AppKit
import Carbon

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

final class LobbyOverlayController: NSObject {
  // Same fixed canvas, typography and colors as the HSTracker fork.
  private static let baseSize = NSSize(width: 208, height: 233)
  /// The layout mode this block belongs to. Pass one shared session to edit several blocks together.
  let layoutSession: OverlayLayoutSession
  private let block: OverlayBlock
  private let canvas = LobbyCanvas(frame: NSRect(origin: .zero, size: baseSize))
  private var hasContent = false
  private var isPreview = false
  var onStatus: ((String) -> Void)?
  /// Whether Hearthstone is frontmost. The harness swaps this to simulate focus changes.
  var isGameFrontmost: () -> Bool = { HearthstoneApp.isFrontmost }
  var isEditing: Bool { block.isEditing }
  private var panel: NSPanel { block.panel }
  private var editor: OverlayEditingPanel { block.editor }
  private var editSurface: OverlayLayoutSurface { block.editSurface }
  private var hintPanel: NSPanel { layoutSession.hintPanel }
  private var gameFrame: NSRect? { block.gameFrame }

  var opacityPercent: Double {
    get { OverlayOpacity.percent }
    set { layoutSession.opacityPercent = newValue }
  }

  init(layoutSession: OverlayLayoutSession = OverlayLayoutSession()) {
    self.layoutSession = layoutSession
    let panel = OverlayEditingPanel(contentRect: NSRect(origin: .zero, size: Self.baseSize),
      styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
    block = OverlayBlock(id: .lobby, panel: panel, baseSize: Self.baseSize,
      keys: OverlayLayoutKeys(originX: DefaultsKey.lobbyOriginX, originY: DefaultsKey.lobbyOriginY,
        scale: DefaultsKey.lobbyScale),
      defaultOrigin: { scale, gameFrame in
        CGPoint(x: 0.16, y: 1.0 -
          (Double(Self.baseSize.height) * LobbyOverlayGeometry.clampScale(scale) + 20.0)
          / Double(gameFrame.height))
      })
    super.init()
    block.canBeginEditing = { [weak self] in self?.hasContent ?? false }
    block.onEditingFinished = { [weak self] in
      guard let self, self.isPreview else { return }
      self.panel.orderOut(nil); self.isPreview = false; self.hasContent = false
    }
    block.onPanelResize = { [weak self] in self?.applyContentScale() }
    layoutSession.register(block)
    build()
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
    block.gameFrame = gameFrame
    let names = ["Your player", "Opponent 2", "Opponent 3", "Opponent 4", "Opponent 5", "Opponent 6", "Opponent 7", "Opponent 8"]
    let rows = names.enumerated().map { index, name in
      LobbyRatingRow(position: index, name: name,
        rating: index == 7 ? .belowCutoff(8000) : .exact(9_932 - index * 300),
        rank: index == 7 ? nil : 834 + index * 900, isLocalPlayer: index == 0)
    }
    render(rows, LobbyAverageSummary(average: 8_555, difference: 1_377))
    block.restoreFrame()
  }

  // Capture events are deduplicated. Window visibility must not depend on new ratings.
  func updateGameWindow(frame: NSRect?) {
    let changed = frame != gameFrame
    if let frame { block.gameFrame = frame }
    // Leaving the game (or losing content) cancels the whole layout session when this block is in it.
    // The hint belongs to the session, so it is only hidden through `finishEditing`.
    guard frame != nil, hasContent, isGameFrontmost() else {
      if isEditing { finishEditing(save: false) }
      panel.orderOut(nil)
      editor.orderOut(nil)
      return
    }
    if !isEditing && (changed || !panel.isVisible) { block.restoreFrame() }
    panel.orderFrontRegardless()
    if isEditing { layoutSession.refreshHint(); editor.orderFrontRegardless() }
  }

  func cancelAndClose() {
    if isEditing { finishEditing(save: false) }
    hasContent = false
    isPreview = false
    block.gameFrame = nil
    panel.orderOut(nil)
    if !layoutSession.isActive { hintPanel.orderOut(nil) }
  }
  func close() { cancelAndClose() }
  func toggleEditing() { isEditing ? finishEditing(save: true) : beginEditing() }
  /// Resets only the lobby block. `layoutSession.resetLayouts()` resets every block.
  func resetLayout() { block.resetLayout() }

  private func beginEditing() {
    guard gameFrame != nil, hasContent else { return }
    layoutSession.begin([.lobby])
  }
  /// Ends the layout session this block is in, which saves or cancels every block in it.
  private func finishEditing(save: Bool) {
    guard isEditing else { return }
    layoutSession.finish(save: save)
  }
  private func resize(delta: NSPoint, from frame: NSRect) { block.resize(delta: delta, from: frame) }
  private func build() {
    panel.contentView = canvas
    canvas.setAccessibilityElement(true)
    canvas.setAccessibilityRole(.group)
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
  var diagnosticBlock: OverlayBlock { block }
  #endif
}
