import AppKit
import Carbon

enum HearthstoneApp {
  static let bundleIdentifier = "unity.Blizzard Entertainment.Hearthstone"
  static var isFrontmost: Bool { NSWorkspace.shared.frontmostApplication?.bundleIdentifier == bundleIdentifier }
  static func activate() {
    NSRunningApplication.runningApplications(withBundleIdentifier: bundleIdentifier).first?.activate()
  }
}

final class OverlayEditingPanel: NSPanel {
  var onEditCommand: ((Bool) -> Void)?

  // A nonactivating panel can receive its own keys while Hearthstone remains
  // frontmost. This keeps bare Escape and Return out of the global hotkey set.
  override var canBecomeKey: Bool { true }
  override var canBecomeMain: Bool { false }

  override func keyDown(with event: NSEvent) {
    if let save = overlayEditCommand(for: event.keyCode) {
      onEditCommand?(save)
    } else {
      super.keyDown(with: event)
    }
  }
}

func overlayEditCommand(for keyCode: UInt16) -> Bool? {
  switch keyCode {
  case UInt16(kVK_Escape):
    false
  case UInt16(kVK_Return), UInt16(kVK_ANSI_KeypadEnter):
    true
  default:
    nil
  }
}

// A separate hit surface leaves the block's own canvas unchanged during editing.
final class OverlayLayoutSurface: NSView {
  static let gripSize: CGFloat = 24
  var onEditCommand: ((Bool) -> Void)?
  var onResize: ((NSPoint, NSRect) -> Void)?
  private var resizeStart: NSRect?
  private var mouseStart = NSPoint.zero
  override var acceptsFirstResponder: Bool { true }
  override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
  override func resetCursorRects() {
    addCursorRect(bounds, cursor: .openHand)
    addCursorRect(NSRect(x: bounds.maxX - Self.gripSize, y: 0, width: Self.gripSize, height: Self.gripSize), cursor: .crosshair)
  }
  override func mouseDown(with event: NSEvent) {
    guard let window else { return }
    let point = convert(event.locationInWindow, from: nil)
    if point.x >= bounds.maxX - Self.gripSize && point.y <= Self.gripSize {
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
    if let save = overlayEditCommand(for: event.keyCode) {
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

/// Where a block saves its position: origin relative to the game window (bottom-left, AppKit) plus scale.
struct OverlayLayoutKeys {
  let originX: String
  let originY: String
  let scale: String
}

/// The opacity setting shared by every overlay block (`lobby.opacity`, 10–100%).
enum OverlayOpacity {
  static var percent: Double {
    get { (UserDefaults.standard.object(forKey: DefaultsKey.lobbyOpacity) as? Double) ?? 100 }
    set { UserDefaults.standard.set(min(max(newValue, 10), 100), forKey: DefaultsKey.lobbyOpacity) }
  }
  static var alpha: CGFloat { min(max(percent, 10), 100) / 100 }
}

/// One floating overlay window that the shared layout mode can move and resize: the visible panel,
/// an editor proxy on top of it, a fixed base size and a saved position relative to the game window.
/// The owner builds and draws the panel; the block handles editing, snapping, saving and restoring.
final class OverlayBlock: NSObject, NSWindowDelegate {
  let id: OverlayBlockID
  let panel: NSPanel
  let editor: OverlayEditingPanel
  let editSurface = OverlayLayoutSurface()
  let baseSize: NSSize
  var gameFrame: NSRect?
  /// False while the block has nothing to show, so a layout session leaves it out.
  var canBeginEditing: () -> Bool = { true }
  /// Runs after a layout session ends for this block, saved or cancelled.
  var onEditingFinished: (() -> Void)?
  var onPanelResize: (() -> Void)?
  /// Runs after layout mode puts the panel on screen (it may have been hidden).
  var onEditingPresented: (() -> Void)?
  /// Enter (true) or Esc (false) pressed in this block's editor. Set by the layout session.
  var onEditCommand: ((Bool) -> Void)?
  private(set) var isEditing = false
  private let keys: OverlayLayoutKeys
  private let defaultOrigin: (_ scale: Double, _ gameFrame: NSRect) -> CGPoint
  private var editStartFrame: NSRect?
  private var synchronizingEditor = false

  /// Level, transparency and Space behavior shared by every overlay window (they float over full-screen Hearthstone).
  /// Note: `isFloatingPanel = true` runs after `level` (as the lobby always did), which leaves panels at `.floating`.
  static func configureFloating(_ window: NSWindow) {
    window.level = NSWindow.Level(rawValue: Int(CGWindowLevelForKey(.normalWindow)) + 1)
    window.isOpaque = false
    window.backgroundColor = .clear
    window.hasShadow = true
    window.hidesOnDeactivate = false
    (window as? NSPanel)?.isFloatingPanel = true
    window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .canJoinAllApplications, .ignoresCycle]
    window.isReleasedWhenClosed = false
    window.animationBehavior = .none
  }

  init(id: OverlayBlockID, panel: NSPanel, baseSize: NSSize, keys: OverlayLayoutKeys,
       defaultOrigin: @escaping (_ scale: Double, _ gameFrame: NSRect) -> CGPoint) {
    self.id = id
    self.panel = panel
    self.baseSize = baseSize
    self.keys = keys
    self.defaultOrigin = defaultOrigin
    editor = OverlayEditingPanel(contentRect: NSRect(origin: .zero, size: baseSize),
      styleMask: [.titled, .resizable, .fullSizeContentView, .nonactivatingPanel], backing: .buffered, defer: false)
    super.init()
    Self.configureFloating(panel)
    Self.configureFloating(editor)
    panel.delegate = self
    editor.delegate = self
    editor.level = NSWindow.Level(rawValue: panel.level.rawValue + 2)
    editor.titleVisibility = .hidden
    editor.titlebarAppearsTransparent = true
    editor.hasShadow = false
    editor.minSize = NSSize(width: baseSize.width * 0.75, height: baseSize.height * 0.75)
    editor.maxSize = NSSize(width: baseSize.width * 1.5, height: baseSize.height * 1.5)
    for button: NSWindow.ButtonType in [.closeButton, .miniaturizeButton, .zoomButton] {
      editor.standardWindowButton(button)?.isHidden = true
    }
    editor.onEditCommand = { [weak self] save in self?.onEditCommand?(save) }
    editSurface.onEditCommand = { [weak self] save in self?.onEditCommand?(save) }
    editSurface.frame = NSRect(origin: .zero, size: baseSize)
    editSurface.autoresizingMask = [.width, .height]
    editSurface.onResize = { [weak self] delta, frame in self?.resize(delta: delta, from: frame) }
    editor.contentView = editSurface
    applyOpacity()
  }

  /// Records the start frame and puts the editor proxy over the panel. The session orders windows front.
  func prepareEditing() {
    editStartFrame = panel.frame
    isEditing = true
    syncEditorToPanel()
  }
  func presentEditing() {
    panel.orderFrontRegardless()
    editor.orderFrontRegardless()
    applyOpacity()
    onEditingPresented?()
  }
  func finishEditing(save: Bool) {
    guard isEditing else { return }
    if save { saveFrame() }
    else if let editStartFrame { panel.setFrame(editStartFrame, display: true) }
    isEditing = false
    editor.orderOut(nil)
    onEditingFinished?()
    applyOpacity()
  }
  func resize(delta: NSPoint, from frame: NSRect) {
    let next = LobbyOverlayGeometry.resizedFrame(from: frame, delta: delta, baseSize: baseSize)
    editor.setFrame(next, display: true)
  }
  func resetLayout() {
    UserDefaults.standard.removeObject(forKey: keys.originX)
    UserDefaults.standard.removeObject(forKey: keys.originY)
    UserDefaults.standard.set(1.0, forKey: keys.scale)
    restoreFrame()
    if isEditing { syncEditorToPanel() }
  }
  func applyOpacity() { panel.alphaValue = OverlayOpacity.alpha }

  func saveFrame() {
    guard let gameFrame else { return }
    let origin = LobbyOverlayGeometry.normalizedOrigin(frame: panel.frame, gameFrame: gameFrame)
    UserDefaults.standard.set(origin.x, forKey: keys.originX)
    UserDefaults.standard.set(origin.y, forKey: keys.originY)
    UserDefaults.standard.set(panel.frame.width / baseSize.width, forKey: keys.scale)
  }
  func restoreFrame() {
    guard let gameFrame else { return }
    let scale = UserDefaults.standard.object(forKey: keys.scale) as? Double ?? 1
    let fallback = defaultOrigin(scale, gameFrame)
    let origin = CGPoint(x: UserDefaults.standard.object(forKey: keys.originX) as? Double ?? fallback.x,
      y: UserDefaults.standard.object(forKey: keys.originY) as? Double ?? fallback.y)
    let screen = NSScreen.screens.max { a, b in
      let x = a.frame.intersection(gameFrame), y = b.frame.intersection(gameFrame)
      return x.width * x.height < y.width * y.height
    }
    panel.setFrame(LobbyOverlayGeometry.restoredFrame(origin: origin, scale: scale,
      baseSize: baseSize, gameFrame: gameFrame, visibleFrame: screen?.frame ?? gameFrame), display: true)
  }

  private func syncEditorToPanel() {
    synchronizingEditor = true
    editor.setFrame(panel.frame, display: true)
    synchronizingEditor = false
  }
  func windowDidResize(_ notification: Notification) {
    if (notification.object as? NSWindow) === editor, isEditing, !synchronizingEditor {
      panel.setFrame(editor.frame, display: true)
    }
    onPanelResize?()
  }
  func windowWillResize(_ sender: NSWindow, to frameSize: NSSize) -> NSSize {
    guard sender === editor else { return frameSize }
    let dx = (frameSize.width - sender.frame.width) / baseSize.width
    let dy = (frameSize.height - sender.frame.height) / baseSize.height
    let scale = LobbyOverlayGeometry.clampScale(sender.frame.width / baseSize.width + (abs(dx) >= abs(dy) ? dx : dy))
    return NSSize(width: baseSize.width * scale, height: baseSize.height * scale)
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
}

/// One layout mode for every overlay block. It owns the single hint panel; Enter in any block's editor
/// saves every block in the session, Esc puts every block back where it started.
///
/// Typical use (one shared session for the app):
///   session.toggle([.lobby, .reconnectButton])   // Cmd-Shift-L: begin, or save if already active
///   session.finish(save: false)                   // cancel all
///   session.resetLayouts()                        // Settings › Reset Layout, every block
///   session.opacityPercent = 60                   // Settings › Overlay opacity, every block
final class OverlayLayoutSession {
  let hintPanel: NSPanel
  private var blocks: [OverlayBlockID: OverlayBlock] = [:]
  /// Blocks in the running session, in the order they were begun. Empty when layout mode is off.
  private(set) var activeBlockIDs: [OverlayBlockID] = []
  var isActive: Bool { !activeBlockIDs.isEmpty }

  init() {
    hintPanel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 330, height: 32),
      styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
    OverlayBlock.configureFloating(hintPanel)
    hintPanel.level = NSWindow.Level(rawValue: hintPanel.level.rawValue + 7)
    buildHint()
  }

  /// Called by each block's owner once. A later block with the same ID replaces the earlier one.
  func register(_ block: OverlayBlock) {
    blocks[block.id] = block
    block.onEditCommand = { [weak self] save in self?.finish(save: save) }
  }
  func block(_ id: OverlayBlockID) -> OverlayBlock? { blocks[id] }
  func isEditing(_ id: OverlayBlockID) -> Bool { activeBlockIDs.contains(id) }

  /// Starts layout mode for the given blocks that have a game frame and content. Returns whether a session
  /// now edits at least one of `ids`. A running session is left as it is (blocks can't join it).
  @discardableResult
  func begin(_ ids: [OverlayBlockID]) -> Bool {
    guard !isActive else { return ids.contains(where: activeBlockIDs.contains) }
    var seen = Set<OverlayBlockID>()
    let editable = ids.filter { seen.insert($0).inserted }.compactMap { blocks[$0] }
      .filter { $0.gameFrame != nil && $0.canBeginEditing() }
    guard let first = editable.first else { return false }
    activeBlockIDs = editable.map(\.id)
    editable.forEach { $0.prepareEditing() }
    HearthstoneApp.activate()
    editable.forEach { $0.presentEditing() }
    first.editor.makeKeyAndOrderFront(nil)
    first.editor.makeFirstResponder(first.editSurface)
    refreshHint()
    return true
  }
  /// Ends layout mode: save writes every block's position, cancel restores every block's start frame.
  func finish(save: Bool) {
    guard isActive else { return }
    let active = activeBlockIDs.compactMap { blocks[$0] }
    activeBlockIDs = []
    hintPanel.orderOut(nil)
    active.forEach { $0.finishEditing(save: save) }
  }
  /// The layout shortcut: saves when a session is running, otherwise begins one.
  @discardableResult
  func toggle(_ ids: [OverlayBlockID]) -> Bool {
    if isActive { finish(save: true); return true }
    return begin(ids)
  }
  /// Puts the given blocks (default: all) back at their default spot and scale.
  func resetLayouts(_ ids: [OverlayBlockID] = OverlayBlockID.allCases) {
    ids.compactMap { blocks[$0] }.forEach { $0.resetLayout() }
  }
  var opacityPercent: Double {
    get { OverlayOpacity.percent }
    set { OverlayOpacity.percent = newValue; applyOpacity() }
  }
  func applyOpacity() { blocks.values.forEach { $0.applyOpacity() } }

  /// Re-centres the hint over the game and keeps it in front. Blocks call this on every game-frame update.
  func refreshHint() {
    guard isActive else { return }
    if let gameFrame = activeBlockIDs.lazy.compactMap({ self.blocks[$0]?.gameFrame }).first {
      hintPanel.setFrameOrigin(NSPoint(x: gameFrame.midX - hintPanel.frame.width / 2, y: gameFrame.maxY - 48))
    }
    hintPanel.orderFrontRegardless()
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
}
