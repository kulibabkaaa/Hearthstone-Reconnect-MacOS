#if DEBUG
import AppKit
import Carbon

/// Self-tests for the Reconnect button block and the shared layout mode, run by `LobbyUIHarness --self-test`.
/// Like `LobbyOverlayController.verifyDiagnosticEditing()`, failures stop the process with a precondition.
enum OverlayLayoutDiagnostics {
  static func verifyButton(_ button: ReconnectButtonOverlayController, gameWindow: NSWindow) {
    let session = button.layoutSession
    let block = button.diagnosticBlock
    let panel = block.panel
    let canvas = button.diagnosticCanvas
    let game = gameWindow.frame
    var clicks = 0
    button.onReconnect = { clicks += 1 }
    button.isGameFrontmost = { true }
    session.resetLayouts([.reconnectButton])
    button.render(.ready)
    button.updateGameWindow(frame: game)

    precondition(panel.isVisible)
    precondition(panel.styleMask.contains(.nonactivatingPanel) && panel.styleMask.contains(.borderless))
    precondition(!panel.canBecomeKey && !panel.canBecomeMain && !panel.ignoresMouseEvents)
    precondition(panel.collectionBehavior.isSuperset(of:
      [.canJoinAllSpaces, .fullScreenAuxiliary, .canJoinAllApplications, .ignoresCycle]))
    let reference = NSPanel(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: true)
    OverlayBlock.configureFloating(reference)
    precondition(panel.level == reference.level && !panel.hidesOnDeactivate && panel.isFloatingPanel)
    precondition(block.editor.level.rawValue == panel.level.rawValue + 2)
    precondition(session.hintPanel.level.rawValue == panel.level.rawValue + 7)
    precondition(canvas.acceptsFirstMouse(for: nil) && panel.contentView === canvas)
    print("PASS: button panel takes clicks, never key or main, nonactivating, full-screen auxiliary, all apps, first mouse, lobby window levels (panel \(panel.level.rawValue), editor +2, hint +7)")

    precondition(roughly(panel.frame.size, ReconnectButtonCanvas.baseSize))
    precondition(abs(panel.frame.minX - (game.minX + 0.735 * game.width)) <= 1)
    precondition(abs(panel.frame.maxY - (game.maxY - 0.184 * game.height)) <= 1)
    print("PASS: default spot is left 73.5% / top 18.4% of the game (within 1 pt; AppKit aligns window frames), \(Int(ReconnectButtonCanvas.baseSize.width))×\(Int(ReconnectButtonCanvas.baseSize.height)) at scale 1")

    let keyBefore = NSApp.keyWindow
    click(panel)
    precondition(clicks == 1)
    precondition(!panel.isKeyWindow && NSApp.keyWindow === keyBefore)
    pressThenRelease(panel, canvas: canvas, releaseOutside: true)
    precondition(clicks == 1)
    precondition(canvas.accessibilityPerformPress() && clicks == 2)
    print("PASS: click → onReconnect once, key window unchanged (\(keyBefore === gameWindow ? "fake game stays key" : "no key window to compare")), release outside cancels, accessibility press")

    let phases: [ReconnectButtonPhase] = [.ready, .unavailable, .reconnecting, .succeeded, .noGameFound, .failed, .cooldown(seconds: 4)]
    for phase in phases {
      button.render(phase)
      let appearance = ReconnectButtonModel.appearance(for: phase)
      let before = clicks
      click(panel)
      precondition(clicks == before + (appearance.isClickable ? 1 : 0))
      precondition(roughly(panel.frame.size, ReconnectButtonCanvas.baseSize))
      precondition(canvas.isSpinning == appearance.spinsIcon)
      precondition(canvas.accessibilityLabel() == appearance.title)
    }
    button.render(.ready)
    precondition(!canvas.isSpinning)
    print("PASS: every phase keeps the \(Int(ReconnectButtonCanvas.baseSize.width))×\(Int(ReconnectButtonCanvas.baseSize.height)) size; only ready/no game/failed take clicks; only reconnecting animates (\(ReconnectButtonCanvas.reducesMotion ? "Reduce Motion on: fade" : "Reduce Motion off: spin"))")

    precondition(session.begin([.reconnectButton]))
    precondition(button.isEditing && block.editor.isVisible && block.editor.frame == panel.frame)
    precondition(block.editor.level.rawValue > panel.level.rawValue)
    var before = clicks
    click(panel)
    precondition(clicks == before && !canvas.accessibilityPerformPress())
    // The editor proxy owns the button's inside, including most of the 24 pt grip under the hidden title bar.
    // Like the lobby editor (same window style), the outer ~4 pt edge and the corners stay with the window
    // frame's own resize, which `windowWillResize` keeps aspect-locked. The corner zone grows with the window:
    // at 176×60 it covers about half of the drawn grip (both resize the same way), so the grip check point
    // sits in the grip's inner half.
    func verifyEditorOwnsInside() {
      let size = block.editor.frame.size
      let root = block.editor.contentView?.superview
      for point in [NSPoint(x: size.width / 2, y: size.height / 2), NSPoint(x: size.width / 2, y: size.height - 6),
                    NSPoint(x: 20, y: size.height / 2), NSPoint(x: size.width - 18, y: 12),
                    NSPoint(x: size.width - 20, y: min(20, size.height - 6))] {
        precondition(root?.hitTest(point) === block.editSurface)
      }
      let edgeResize = block.windowWillResize(block.editor, to: NSSize(width: size.width + 40, height: size.height + 2))
      precondition(aspectLocked(edgeResize, block.baseSize))
    }
    verifyEditorOwnsInside()
    let start = panel.frame
    block.resize(delta: NSPoint(x: 1000, y: -1000), from: block.editor.frame)
    precondition(panel.frame == block.editor.frame && roughly(panel.frame.size, scaled(ReconnectButtonCanvas.baseSize, 1.5)))
    precondition(abs(panel.frame.maxY - start.maxY) < 0.01)
    block.resize(delta: NSPoint(x: -1000, y: 1000), from: block.editor.frame)
    precondition(panel.frame == block.editor.frame && roughly(panel.frame.size, scaled(ReconnectButtonCanvas.baseSize, 0.75)))
    verifyEditorOwnsInside()
    block.editSurface.keyDown(with: key(kVK_Escape, block.editor))
    precondition(!session.isActive && panel.frame == start && !block.editor.isVisible && !session.hintPanel.isVisible)
    before = clicks
    click(panel)
    precondition(clicks == before + 1)
    print("PASS: layout mode blocks clicks; editor proxy owns the button inside and the grip at 1.0 and 0.75; resize 0.75–1.5 aspect-locked; Esc restores")

    button.render(.reconnecting)
    button.isGameFrontmost = { false }
    button.updateGameWindow(frame: game)
    precondition(!panel.isVisible && !canvas.isSpinning)
    // A game frame that arrives while the game is in the background still places the (hidden) button, so a
    // layout session begun before the next frontmost poll starts from the right spot.
    let movedGame = game.offsetBy(dx: 30, dy: -20)
    let expected = panel.frame.offsetBy(dx: 30, dy: -20)
    button.updateGameWindow(frame: movedGame)
    precondition(!panel.isVisible && panel.frame == expected)
    precondition(session.begin([.reconnectButton]) && panel.frame == expected && panel.isVisible && canvas.isSpinning)
    session.finish(save: false)
    precondition(panel.frame == expected)
    button.render(.ready)
    button.isGameFrontmost = { true }
    button.updateGameWindow(frame: game)
    precondition(panel.isVisible)
    button.updateGameWindow(frame: nil)
    precondition(!panel.isVisible)
    button.updateGameWindow(frame: game)
    button.opacityPercent = 40
    precondition(abs(panel.alphaValue - 0.4) < 0.001)
    button.opacityPercent = 100
    precondition(panel.alphaValue == 1)
    print("PASS: button hides (spinner stops) when the game isn't frontmost or has no window, keeps tracking the game while hidden, shows again, follows overlay opacity")
  }

  /// The match rule: outside layout mode the button shows only in a match; layout mode shows it at any time and
  /// it hides again when the session ends; a reconnect result already on screen stays up; without a match
  /// detector it shows whenever the game is frontmost; the setting hides it.
  static func verifyMatchRule(_ button: ReconnectButtonOverlayController, gameWindow: NSWindow) {
    let session = button.layoutSession
    let panel = button.diagnosticBlock.panel
    let game = gameWindow.frame
    var inMatch = false
    var enabled = true
    var detector = true
    button.isGameFrontmost = { true }
    button.isEnabled = { enabled }
    button.isMatchDetectorAvailable = { detector }
    button.isInMatch = { inMatch }
    session.finish(save: false)
    button.render(.ready)
    button.hide()
    button.updateGameWindow(frame: game)
    precondition(!panel.isVisible)
    inMatch = true
    button.updateGameWindow(frame: game)
    precondition(panel.isVisible)
    inMatch = false
    button.updateGameWindow(frame: game)
    precondition(!panel.isVisible)
    print("PASS: hidden with no match, shown during a match, hidden after it ends")

    for save in [true, false] {
      precondition(session.begin([.reconnectButton]) && button.isEditing && panel.isVisible)
      button.updateGameWindow(frame: game)
      precondition(panel.isVisible && session.isActive)
      session.finish(save: save)
      precondition(!session.isActive && !panel.isVisible && !button.diagnosticBlock.editor.isVisible)
    }
    inMatch = true
    button.updateGameWindow(frame: game)
    precondition(session.begin([.reconnectButton]))
    session.finish(save: true)
    precondition(panel.isVisible)
    print("PASS: layout mode shows the button outside a match and hides it again when saved or cancelled; in a match it stays")

    button.render(.reconnecting)
    inMatch = false
    button.updateGameWindow(frame: game)
    precondition(panel.isVisible)
    button.render(.succeeded)
    button.updateGameWindow(frame: game)
    precondition(panel.isVisible)
    button.render(.cooldown(seconds: 4))
    button.updateGameWindow(frame: game)
    precondition(!panel.isVisible)
    button.render(.noGameFound)
    button.updateGameWindow(frame: game)
    precondition(!panel.isVisible)
    print("PASS: a reconnect result on screen outlasts the match signal; a hidden button doesn't appear for one")

    button.render(.ready)
    detector = false
    button.updateGameWindow(frame: game)
    precondition(panel.isVisible)
    var frontmost = false
    button.isGameFrontmost = { frontmost }
    button.updateGameWindow(frame: game)
    precondition(!panel.isVisible)
    frontmost = true
    button.updateGameWindow(frame: game)
    precondition(panel.isVisible)
    detector = true
    button.updateGameWindow(frame: game)
    precondition(!panel.isVisible)
    print("PASS: without a match detector the button shows whenever the game is frontmost; with one it hides outside a match")

    button.render(.ready)
    inMatch = true
    enabled = false
    button.updateGameWindow(frame: game)
    precondition(!panel.isVisible)
    enabled = true
    button.updateGameWindow(frame: game)
    precondition(panel.isVisible)
    detector = false
    enabled = false
    button.updateGameWindow(frame: game)
    precondition(!panel.isVisible)
    button.isInMatch = { true }
    button.isEnabled = { true }
    button.isMatchDetectorAvailable = { true }
    button.isGameFrontmost = { true }
    print("PASS: the setting off hides the button even in a match or without a detector")
  }

  static func verifySharedLayout(lobby: LobbyOverlayController, button: ReconnectButtonOverlayController, gameWindow: NSWindow) {
    let session = lobby.layoutSession
    precondition(session === button.layoutSession)
    let lb = lobby.diagnosticBlock
    let bb = button.diagnosticBlock
    let game = gameWindow.frame
    var clicks = 0
    button.onReconnect = { clicks += 1 }
    lobby.isGameFrontmost = { true }
    button.isGameFrontmost = { true }
    session.finish(save: false)
    session.resetLayouts()
    button.render(.ready)
    // Like the app: the sample lobby is set up, then the game-frame poll puts both blocks on screen.
    func showBoth() {
      lobby.showPreview(gameFrame: game)
      lobby.updateGameWindow(frame: game)
      button.updateGameWindow(frame: game)
    }
    showBoth()
    precondition(abs(lb.panel.frame.minX - (game.minX + 0.16 * game.width)) <= 1)
    precondition(abs(lb.panel.frame.maxY - (game.maxY - 20)) <= 1)
    precondition(abs(bb.panel.frame.minX - (game.minX + 0.735 * game.width)) <= 1)
    precondition(abs(bb.panel.frame.maxY - (game.maxY - 0.184 * game.height)) <= 1)

    precondition(session.begin([.lobby, .reconnectButton]))
    precondition(session.activeBlockIDs == [.lobby, .reconnectButton] && lobby.isEditing && button.isEditing)
    precondition(lb.editor.isVisible && bb.editor.isVisible && session.hintPanel.isVisible)
    precondition(lb.editor.firstResponder === lb.editSurface)
    precondition(lb.editor.frame == lb.panel.frame && bb.editor.frame == bb.panel.frame)
    precondition(lb.editor.styleMask == bb.editor.styleMask && lb.editor.level == bb.editor.level)
    precondition(lb.editor.collectionBehavior == bb.editor.collectionBehavior && lb.editor.canBecomeKey && bb.editor.canBecomeKey)
    precondition(roughly(bb.editor.minSize, scaled(bb.baseSize, 0.75)) && roughly(bb.editor.maxSize, scaled(bb.baseSize, 1.5)))
    precondition(roughly(lb.editor.minSize, scaled(lb.baseSize, 0.75)) && roughly(lb.editor.maxSize, scaled(lb.baseSize, 1.5)))
    click(bb.panel)
    precondition(clicks == 0)
    print("PASS: one session edits both blocks with identical editors and one hint; lobby editor takes the keys; no reconnect in layout mode")

    let lobbyStart = lb.panel.frame, buttonStart = bb.panel.frame
    editBoth(lb, bb)
    precondition(lb.panel.frame != lobbyStart && bb.panel.frame != buttonStart)
    // Esc pressed in the button's editor (not the key one) still cancels every block.
    bb.editSurface.keyDown(with: key(kVK_Escape, bb.editor))
    precondition(!session.isActive && !lobby.isEditing && !button.isEditing)
    precondition(lb.panel.frame == lobbyStart && bb.panel.frame == buttonStart)
    precondition(!lb.editor.isVisible && !bb.editor.isVisible && !session.hintPanel.isVisible)
    print("PASS: move + resize each block; Esc from either editor restores both start frames")

    showBoth()
    precondition(session.begin([.lobby, .reconnectButton]))
    editBoth(lb, bb)
    let lobbySaved = lb.panel.frame, buttonSaved = bb.panel.frame
    lb.editor.keyDown(with: key(kVK_Return, lb.editor))
    precondition(!session.isActive && !lb.editor.isVisible && !bb.editor.isVisible && !session.hintPanel.isVisible)
    precondition(abs((UserDefaults.standard.object(forKey: DefaultsKey.reconnectButtonScale) as? Double ?? 0) - 1.25) < 0.001)
    precondition(UserDefaults.standard.object(forKey: DefaultsKey.reconnectButtonOriginX) != nil)
    precondition(UserDefaults.standard.object(forKey: DefaultsKey.lobbyOriginX) != nil)
    button.hide()
    showBoth()
    precondition(nearly(lb.panel.frame, lobbySaved) && nearly(bb.panel.frame, buttonSaved))
    let movedGame = game.offsetBy(dx: 30, dy: -20)
    lobby.updateGameWindow(frame: movedGame)
    button.updateGameWindow(frame: movedGame)
    precondition(nearly(lb.panel.frame, lobbySaved.offsetBy(dx: 30, dy: -20)))
    precondition(nearly(bb.panel.frame, buttonSaved.offsetBy(dx: 30, dy: -20)))
    lobby.updateGameWindow(frame: game)
    button.updateGameWindow(frame: game)
    print("PASS: Enter saves both (button keys reconnectButton.layout.*); saved spots restore after re-show and follow the game window")

    precondition(session.toggle([.lobby, .reconnectButton]) && session.isActive)
    bb.editor.setFrame(bb.panel.frame.offsetBy(dx: -40, dy: 0), display: true)
    let toggled = bb.panel.frame
    precondition(session.toggle([.lobby, .reconnectButton]) && !session.isActive)
    button.hide()
    button.updateGameWindow(frame: game)
    precondition(nearly(bb.panel.frame, toggled))
    print("PASS: the layout shortcut toggles the session and the second press saves")

    showBoth()
    precondition(session.begin([.lobby]))
    precondition(lobby.isEditing && !button.isEditing && !bb.editor.isVisible && bb.panel.isVisible)
    click(bb.panel)
    precondition(clicks == 0)
    lb.editSurface.keyDown(with: key(kVK_Escape, lb.editor))
    precondition(!session.isActive)
    showBoth()
    precondition(session.begin([.reconnectButton]))
    precondition(button.isEditing && !lobby.isEditing && !lb.editor.isVisible)
    precondition(!session.begin([.lobby]) && session.begin([.reconnectButton]) && session.activeBlockIDs == [.reconnectButton])
    lobby.updateGameWindow(frame: game)
    lobby.cancelAndClose()
    precondition(session.isActive && button.isEditing && session.hintPanel.isVisible && bb.editor.isVisible)
    bb.editor.keyDown(with: key(kVK_Escape, bb.editor))
    precondition(!session.isActive)
    precondition(session.begin([.lobby, .reconnectButton]))
    precondition(session.activeBlockIDs == [.reconnectButton])
    session.finish(save: false)
    precondition(!session.begin([.lobby]) && !session.isActive)
    print("PASS: lobby-only and button-only sessions; a block without content is left out; lobby closing doesn't end a button session")

    showBoth()
    session.resetLayouts()
    precondition(UserDefaults.standard.object(forKey: DefaultsKey.reconnectButtonOriginX) == nil)
    precondition(UserDefaults.standard.object(forKey: DefaultsKey.lobbyOriginX) == nil)
    precondition(UserDefaults.standard.double(forKey: DefaultsKey.reconnectButtonScale) == 1)
    precondition(UserDefaults.standard.double(forKey: DefaultsKey.lobbyScale) == 1)
    precondition(abs(lb.panel.frame.minX - (game.minX + 0.16 * game.width)) <= 1)
    precondition(abs(bb.panel.frame.minX - (game.minX + 0.735 * game.width)) <= 1)
    precondition(abs(bb.panel.frame.maxY - (game.maxY - 0.184 * game.height)) <= 1)
    precondition(roughly(bb.panel.frame.size, bb.baseSize) && roughly(lb.panel.frame.size, lb.baseSize))
    precondition(session.begin([.lobby, .reconnectButton]))
    editBoth(lb, bb)
    session.resetLayouts()
    precondition(lb.editor.frame == lb.panel.frame && bb.editor.frame == bb.panel.frame)
    precondition(roughly(bb.panel.frame.size, bb.baseSize))
    session.finish(save: false)
    print("PASS: Reset Layout puts both blocks back at their defaults, also while editing")

    showBoth()
    lobby.opacityPercent = 30
    precondition(abs(lb.panel.alphaValue - 0.3) < 0.001 && abs(bb.panel.alphaValue - 0.3) < 0.001)
    button.opacityPercent = 100
    precondition(lb.panel.alphaValue == 1 && bb.panel.alphaValue == 1)
    print("PASS: overlay opacity applies to both blocks")

    precondition(session.begin([.lobby, .reconnectButton]))
    let lobbyBefore = lb.panel.frame, buttonBefore = bb.panel.frame
    editBoth(lb, bb)
    lobby.isGameFrontmost = { false }
    button.isGameFrontmost = { false }
    lobby.updateGameWindow(frame: game)
    button.updateGameWindow(frame: game)
    precondition(!session.isActive && !lb.panel.isVisible && !bb.panel.isVisible)
    precondition(!lb.editor.isVisible && !bb.editor.isVisible && !session.hintPanel.isVisible)
    precondition(lb.panel.frame == lobbyBefore && bb.panel.frame == buttonBefore)
    lobby.isGameFrontmost = { true }
    button.isGameFrontmost = { true }
    showBoth()
    precondition(lb.panel.isVisible && bb.panel.isVisible)
    // Outside layout mode the lobby shows only real match rows; `show(rows:)` puts it on screen itself.
    lobby.cancelAndClose()
    lobby.show(rows: [LobbyRatingRow(position: 0, name: "Your player", rating: .exact(9_000), rank: 1, isLocalPlayer: true)],
      summary: nil, gameFrame: game)
    precondition(lb.panel.isVisible && !session.isActive && !lb.editor.isVisible)
    lobby.cancelAndClose()
    button.hide()
    precondition(!lb.panel.isVisible && !bb.panel.isVisible && !session.hintPanel.isVisible)
    print("PASS: both blocks hide (and layout mode cancels) when the game isn't frontmost; real lobby rows show outside layout mode; cleanup")
  }

  // MARK: - Helpers

  /// Moves and resizes both blocks through their editors, the way a drag and a grip resize do.
  private static func editBoth(_ lobby: OverlayBlock, _ button: OverlayBlock) {
    lobby.editor.setFrame(lobby.panel.frame.offsetBy(dx: 40, dy: -25), display: true)
    lobby.resize(delta: NSPoint(x: 20, y: -20), from: lobby.editor.frame)
    button.editor.setFrame(button.panel.frame.offsetBy(dx: -60, dy: -30), display: true)
    button.resize(delta: NSPoint(x: button.baseSize.width * 0.25, y: 0), from: button.editor.frame)
    precondition(lobby.panel.frame == lobby.editor.frame && button.panel.frame == button.editor.frame)
    precondition(aspectLocked(button.panel.frame.size, button.baseSize) && aspectLocked(lobby.panel.frame.size, lobby.baseSize))
  }
  /// A full click at the centre of `window`, delivered through the window like a real one.
  static func click(_ window: NSWindow) {
    let point = NSPoint(x: window.frame.width / 2, y: window.frame.height / 2)
    window.sendEvent(mouse(.leftMouseDown, at: point, in: window))
    window.sendEvent(mouse(.leftMouseUp, at: point, in: window))
  }
  private static func pressThenRelease(_ window: NSWindow, canvas: ReconnectButtonCanvas, releaseOutside: Bool) {
    let inside = NSPoint(x: window.frame.width / 2, y: window.frame.height / 2)
    window.sendEvent(mouse(.leftMouseDown, at: inside, in: window))
    let outside = NSPoint(x: window.frame.width + 40, y: inside.y)
    canvas.mouseDragged(with: mouse(.leftMouseDragged, at: outside, in: window))
    canvas.mouseUp(with: mouse(.leftMouseUp, at: releaseOutside ? outside : inside, in: window))
  }
  private static func mouse(_ type: NSEvent.EventType, at point: NSPoint, in window: NSWindow) -> NSEvent {
    guard let event = NSEvent.mouseEvent(with: type, location: point, modifierFlags: [],
      timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber, context: nil,
      eventNumber: 0, clickCount: 1, pressure: type == .leftMouseUp ? 0 : 1) else {
      preconditionFailure("Couldn't create a diagnostic mouse event")
    }
    return event
  }
  private static func key(_ keyCode: Int, _ window: NSWindow) -> NSEvent {
    guard let event = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0,
      windowNumber: window.windowNumber, context: nil, characters: "", charactersIgnoringModifiers: "",
      isARepeat: false, keyCode: UInt16(keyCode)) else {
      preconditionFailure("Couldn't create a diagnostic key event")
    }
    return event
  }
  private static func scaled(_ size: NSSize, _ factor: CGFloat) -> NSSize {
    NSSize(width: size.width * factor, height: size.height * factor)
  }
  private static func aspectLocked(_ size: NSSize, _ base: NSSize) -> Bool {
    abs(size.height - size.width * base.height / base.width) <= 1
  }
  /// Within 1 pt: AppKit rounds window frames to whole points, so a 28.5 pt height becomes 29.
  private static func roughly(_ a: NSSize, _ b: NSSize) -> Bool {
    abs(a.width - b.width) <= 1 && abs(a.height - b.height) <= 1
  }
  private static func nearly(_ a: NSSize, _ b: NSSize) -> Bool {
    abs(a.width - b.width) < 0.01 && abs(a.height - b.height) < 0.01
  }
  /// Same origin; size within 1 pt (a saved scale like 229/208 restores as 229.00000000000003, which AppKit rounds up).
  private static func nearly(_ a: NSRect, _ b: NSRect) -> Bool {
    roughly(a.size, b.size) && abs(a.minX - b.minX) < 0.01 && abs(a.maxY - b.maxY) <= 1
  }

  /// Draws the game window's content and the given overlay windows (where visible) into one PNG,
  /// at the positions the real code gave them. No screen recording permission needed.
  static func writeComposite(game: NSWindow, overlays: [NSWindow], to url: URL) throws {
    let frame = game.frame
    let scale = game.backingScaleFactor
    guard let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(frame.width * scale),
      pixelsHigh: Int(frame.height * scale), bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true,
      isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0),
      let context = NSGraphicsContext(bitmapImageRep: rep) else { return }
    rep.size = frame.size
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = context
    // A bitmap context draws in pixels; scale so the points below fill the 2x bitmap.
    context.cgContext.scaleBy(x: scale, y: scale)
    if let content = game.contentView { draw(content, in: NSRect(origin: .zero, size: frame.size), alpha: 1) }
    for window in overlays where window.isVisible {
      guard let content = window.contentView else { continue }
      draw(content, in: window.frame.offsetBy(dx: -frame.minX, dy: -frame.minY), alpha: window.alphaValue)
    }
    NSGraphicsContext.restoreGraphicsState()
    try rep.representation(using: .png, properties: [:])?.write(to: url, options: .atomic)
  }
  static func writePNG(of view: NSView, to url: URL) throws {
    view.layoutSubtreeIfNeeded()
    guard let bitmap = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { return }
    view.cacheDisplay(in: view.bounds, to: bitmap)
    try bitmap.representation(using: .png, properties: [:])?.write(to: url, options: .atomic)
  }
  private static func draw(_ view: NSView, in rect: NSRect, alpha: CGFloat) {
    view.layoutSubtreeIfNeeded()
    guard let cached = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { return }
    view.cacheDisplay(in: view.bounds, to: cached)
    if let layer = view.layer, let color = layer.backgroundColor, let context = NSGraphicsContext.current?.cgContext {
      // cacheDisplay skips layer-only styling (the hint's rounded background), so paint it first.
      context.saveGState()
      context.setAlpha(alpha)
      context.addPath(CGPath(roundedRect: rect, cornerWidth: layer.cornerRadius, cornerHeight: layer.cornerRadius, transform: nil))
      context.setFillColor(color)
      context.fillPath()
      context.restoreGState()
    }
    cached.draw(in: rect, from: .zero, operation: .sourceOver, fraction: alpha, respectFlipped: true, hints: nil)
  }
}
#endif
