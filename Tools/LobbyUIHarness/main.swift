import AppKit

final class HarnessDelegate: NSObject, NSApplicationDelegate {
  // Both blocks share one layout session, as in the app.
  private let layoutSession = OverlayLayoutSession()
  private lazy var overlay = LobbyOverlayController(layoutSession: layoutSession)
  private lazy var button = ReconnectButtonOverlayController(layoutSession: layoutSession)
  private var gameWindow: NSWindow?
  private var fullScreenObserver: NSObjectProtocol?
  private var settings: SettingsWindowController!
  private var bugReport: BugReportWindowController?
  private var whatsNew: WhatsNewPresenter?
  private var reconnectPresses = 0

  func applicationDidFinishLaunching(_ notification: Notification) {
    if let name = argument("appearance") { NSApp.appearance = NSAppearance(named: name == "dark" ? .darkAqua : .aqua) }
    if ProcessInfo.processInfo.arguments.contains("--bug-report")
      || UserDefaults.standard.bool(forKey: "HarnessBugReportMode")
    {
      bugReport = BugReportWindowController()
      bugReport?.present()
      return
    }
    let scale = ProcessInfo.processInfo.arguments.compactMap { $0.hasPrefix("--scale=") ? Double($0.dropFirst(8)) : nil }.first ?? 1
    let firstRun = ProcessInfo.processInfo.arguments.contains("--first-run")
    let windowCapturePath = ProcessInfo.processInfo.arguments.first(where: {
      $0.hasPrefix("--capture-window=")
    }).map { String($0.dropFirst("--capture-window=".count)) }
    let opacity = ProcessInfo.processInfo.arguments.compactMap { $0.hasPrefix("--opacity=") ? Double($0.dropFirst(10)) : nil }.first ?? 75
    let overlayOnly = ProcessInfo.processInfo.arguments.contains("--overlay-only")
    let requestedCapturePath = ProcessInfo.processInfo.arguments.first(where: { $0.hasPrefix("--capture=") }).map { String($0.dropFirst(10)) }
    let capturePath = requestedCapturePath ?? (overlayOnly
      ? "/tmp/hs-lobby-implementation-audit-01a0b660/overlay-\(Int(scale * 100))pct-opacity\(Int(opacity))-01a0b693.png"
      : nil)
    UserDefaults.standard.register(defaults: [DefaultsKey.lobbyEnabled: true,
      DefaultsKey.lobbyOpacity: opacity, DefaultsKey.lobbyScale: scale,
      DefaultsKey.lobbyShortcutDisplay: AppConfiguration.defaultLobbyShortcutDisplay,
      DefaultsKey.reconnectButtonEnabled: true,
      DefaultsKey.hotkeyDisplay: AppConfiguration.defaultShortcutDisplay])
    UserDefaults.standard.set(scale, forKey: DefaultsKey.lobbyScale)
    UserDefaults.standard.set(opacity, forKey: DefaultsKey.lobbyOpacity)
    UserDefaults.standard.removeObject(forKey: DefaultsKey.lobbyOriginX)
    UserDefaults.standard.removeObject(forKey: DefaultsKey.lobbyOriginY)
    UserDefaults.standard.removeObject(forKey: DefaultsKey.reconnectButtonOriginX)
    UserDefaults.standard.removeObject(forKey: DefaultsKey.reconnectButtonOriginY)
    UserDefaults.standard.set(argument("button-scale").flatMap(Double.init) ?? 1.0, forKey: DefaultsKey.reconnectButtonScale)
    settings = SettingsWindowController(onReconnect: { [weak self] in self?.reconnectPresses += 1 }, onShortcutChanged: { _,_,_ in true },
      onShortcutRecordingChanged: { _ in }, onOpenWithHearthstoneChanged: { _ in .success(()) },
      onShowInDockChanged: { value, done in done(value) }, onOpenSystemSettings: {},
      onRetrySystemExtensionApproval: {}, onRetryProxySetup: {},
      onBeginReconnectSetup: {}, onUninstall: {},
      onLobbyEnabledChanged: { _ in }, onLobbyOpacityChanged: { [weak self] in self?.overlay.opacityPercent = $0 },
      onLobbyShortcutChanged: { _,_,_ in true },
      onResetLobby: { [weak self] in self?.overlay.resetLayout() }, onRetryLobbySetup: {},
      onReportBug: { [weak self] in self?.showBugReport() },
      onCheckForUpdates: {}, automaticUpdateChecksEnabled: { true },
      onAutomaticUpdateChecksChanged: { _ in })
    if firstRun {
      settings.setStatus("Reconnect needs approval for its network extension and proxy. Choose Set Up Reconnect to begin.")
      settings.setReconnectSetupAction(.beginReconnectSetup)
      settings.setLobbyStatus("Waiting for Hearthstone")
    } else {
      settings.setStatus("Diagnostic harness — reconnect actions are disabled.")
      settings.setLobbyStatus("Sample lobby preview")
    }
    settings.showWindow(nil); settings.window?.makeKeyAndOrderFront(nil)
    NSApp.activate(ignoringOtherApps: true)
    if let windowCapturePath, let view = settings.window?.contentView {
      DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
        view.layoutSubtreeIfNeeded()
        if let image = view.bitmapImageRepForCachingDisplay(in: view.bounds) {
          view.cacheDisplay(in: view.bounds, to: image)
          try? image.representation(using: .png, properties: [:])?
            .write(to: URL(fileURLWithPath: windowCapturePath))
        }
        NSApp.terminate(nil)
      }
      return
    }
    if firstRun { return }
    if arguments.contains("--whats-new") { runWhatsNew(); return }
    if arguments.contains("--reconnect-button") || arguments.contains("--both-blocks") {
      runOverlayBlocks(withLobby: arguments.contains("--both-blocks"))
      return
    }
    guard let frame = (NSScreen.main ?? NSScreen.screens.first)?.visibleFrame else { return }
    overlay.showPreview(gameFrame: frame.insetBy(dx: 40, dy: 40))
    if capturePath == nil { overlay.toggleEditing() } else { overlay.beginDiagnosticEditing() }
    if ProcessInfo.processInfo.arguments.contains("--self-test") {
      overlay.verifyDiagnosticEditing()
      NSApp.terminate(nil)
      return
    }
    if let capturePath {
      try? overlay.writeDiagnosticPNG(to: URL(fileURLWithPath: capturePath))
      let size = overlay.diagnosticFrameSize
      try? "\(size.width)x\(size.height)\n".write(toFile: capturePath + ".frame.txt", atomically: true, encoding: .utf8)
      DispatchQueue.main.async { NSApp.terminate(nil) }
    }
  }
  private var arguments: [String] { ProcessInfo.processInfo.arguments }
  private func argument(_ name: String) -> String? {
    arguments.first { $0.hasPrefix("--\(name)=") }.map { String($0.dropFirst(name.count + 3)) }
  }

  /// `--whats-new` shows the one-time What's New spotlight over the main window, as with Reconnect ready.
  /// Options: `--appearance=<light|dark>`, `--capture=<png>` (captures the main window's area, then quits), `--self-test`.
  private func runWhatsNew() {
    guard let host = settings.window else { return }
    // What the window says once setup is done, the moment the spotlight appears.
    settings.setStatus("Ready. Start a Battlegrounds game.")
    settings.setLobbyStatus("Waiting for a Solo match")
    settings.setReconnectEnabled(true)
    if arguments.contains("--self-test") {
      DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { [self] in
        WhatsNewDiagnostics.verify(host: host, reconnectPresses: { [weak self] in self?.reconnectPresses ?? 0 },
          reopenWindow: { [weak self] in
            self?.settings.showWindow(nil); self?.settings.window?.makeKeyAndOrderFront(nil)
          })
        NSApp.terminate(nil)
      }
      return
    }
    let presenter = WhatsNewPresenter(defaults: WhatsNewDiagnostics.defaults())
    whatsNew = presenter
    DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { [self] in
      presenter.presentIfNeeded(over: host, isReconnectReady: true)
      guard let path = argument("capture") else { return }
      DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) {
        WhatsNewDiagnostics.capture(host: host, to: path)
        NSApp.terminate(nil)
      }
    }
  }

  /// `--reconnect-button` shows the button over a fake game window; `--both-blocks` adds the lobby block and
  /// opens the shared layout mode. Options: `--game-size=WxH` (default 1440x903), `--game-image=<png>`,
  /// `--phase=<ready|unavailable|reconnecting|succeeded|noGameFound|failed|cooldown>`,
  /// `--button-scale=<0.75–1.5>`, `--capture-dir=<dir>` (writes PNGs, then quits), `--self-test`, `--fullscreen-test`.
  private func runOverlayBlocks(withLobby: Bool) {
    let size = argument("game-size").flatMap { value -> NSSize? in
      let parts = value.split(separator: "x").compactMap { Double($0) }
      return parts.count == 2 ? NSSize(width: parts[0], height: parts[1]) : nil
    } ?? NSSize(width: 1440, height: 903)
    let game = makeGameWindow(size: size, image: argument("game-image").flatMap { NSImage(contentsOfFile: $0) })
    gameWindow = game
    button.isGameFrontmost = { true }
    // The fake game is in a match, so the button shows outside layout mode (`verifyMatchRule` covers the rest).
    button.isInMatch = { true }
    overlay.isGameFrontmost = { true }
    var clicks = 0
    button.onReconnect = { clicks += 1; print("Reconnect clicked (\(clicks))") }
    button.render(Self.phase(named: argument("phase") ?? "ready"))
    // Let activation settle so the fake game is the key window, as Hearthstone would be.
    DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [self] in
      button.updateGameWindow(frame: game.frame)
      // Like the app's game-frame poll, which is what puts a lobby with content on screen.
      if withLobby { overlay.showPreview(gameFrame: game.frame); overlay.updateGameWindow(frame: game.frame) }
      if arguments.contains("--self-test") {
        if withLobby {
          overlay.beginDiagnosticEditing()
          overlay.verifyDiagnosticEditing()
          OverlayLayoutDiagnostics.verifySharedLayout(lobby: overlay, button: button, gameWindow: game)
        } else {
          OverlayLayoutDiagnostics.verifyButton(button, gameWindow: game)
          OverlayLayoutDiagnostics.verifyMatchRule(button, gameWindow: game)
        }
        if !arguments.contains("--fullscreen-test") { NSApp.terminate(nil); return }
      }
      if arguments.contains("--fullscreen-test") { runFullScreenTest(game: game); return }
      if let directory = argument("capture-dir") {
        writeCaptures(to: URL(fileURLWithPath: directory, isDirectory: true), game: game, withLobby: withLobby)
        NSApp.terminate(nil)
        return
      }
      if withLobby { layoutSession.begin([.lobby, .reconnectButton]) }
    }
  }

  private func makeGameWindow(size: NSSize, image: NSImage?) -> NSWindow {
    let screen = (NSScreen.main ?? NSScreen.screens[0]).visibleFrame
    let window = NSWindow(contentRect: NSRect(x: screen.midX - size.width / 2, y: screen.midY - size.height / 2,
      width: size.width, height: size.height),
      styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView], backing: .buffered, defer: false)
    window.title = "Fake Hearthstone"
    window.titleVisibility = .hidden
    window.titlebarAppearsTransparent = true
    window.collectionBehavior = [.fullScreenPrimary]
    window.isReleasedWhenClosed = false
    let content: NSView
    if let image {
      let imageView = NSImageView(frame: NSRect(origin: .zero, size: size))
      imageView.image = image
      imageView.imageScaling = .scaleAxesIndependently
      content = imageView
    } else {
      content = HarnessBoardView(frame: NSRect(origin: .zero, size: size))
    }
    content.autoresizingMask = [.width, .height]
    window.contentView = content
    window.makeKeyAndOrderFront(nil)
    return window
  }

  private func writeCaptures(to directory: URL, game: NSWindow, withLobby: Bool) {
    try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    let block = button.diagnosticBlock
    let tag = "\(Int(game.frame.width))x\(Int(game.frame.height))"
    func save(_ name: String, _ overlays: [NSWindow]) {
      let url = directory.appendingPathComponent(name)
      do { try OverlayLayoutDiagnostics.writeComposite(game: game, overlays: overlays, to: url); print("Wrote \(url.path)") }
      catch { print("FAIL: couldn't write \(url.path): \(error)") }
    }
    if withLobby {
      let lobby = overlay.diagnosticBlock
      save("game-\(tag)-both.png", [lobby.panel, block.panel])
      layoutSession.begin([.lobby, .reconnectButton])
      save("game-\(tag)-layout-both.png", [lobby.panel, block.panel, lobby.editor, block.editor, layoutSession.hintPanel])
      layoutSession.finish(save: false)
      return
    }
    for (name, phase) in Self.phases {
      button.render(phase)
      let url = directory.appendingPathComponent("button-\(name).png")
      try? OverlayLayoutDiagnostics.writePNG(of: button.diagnosticCanvas, to: url)
      save("game-\(tag)-\(name).png", [block.panel])
    }
    button.render(.ready)
    layoutSession.begin([.reconnectButton])
    save("game-\(tag)-layout-button.png", [block.panel, block.editor, layoutSession.hintPanel])
    layoutSession.finish(save: false)
  }

  /// Puts the fake game into native full screen and checks the button is on that Space and takes a click.
  private func runFullScreenTest(game: NSWindow) {
    let panel = button.diagnosticBlock.panel
    var clicks = 0
    button.onReconnect = { clicks += 1 }
    button.render(.ready)
    DispatchQueue.main.asyncAfter(deadline: .now() + 15) {
      print("FAIL: full screen didn't finish in 15 s")
      exit(1)
    }
    fullScreenObserver = NotificationCenter.default.addObserver(forName: NSWindow.didEnterFullScreenNotification,
      object: game, queue: .main) { [self] _ in
      DispatchQueue.main.asyncAfter(deadline: .now() + 1) { [self] in
        button.updateGameWindow(frame: game.frame)
        let onScreen = (CGWindowListCopyWindowInfo([.optionOnScreenOnly], kCGNullWindowID) as? [[String: Any]] ?? [])
          .contains { ($0[kCGWindowNumber as String] as? Int) == panel.windowNumber }
        precondition(game.styleMask.contains(.fullScreen))
        precondition(panel.isVisible && panel.isOnActiveSpace && onScreen)
        let keyBefore = NSApp.keyWindow
        OverlayLayoutDiagnostics.click(panel)
        precondition(clicks == 1 && !panel.isKeyWindow && NSApp.keyWindow === keyBefore)
        if let directory = argument("capture-dir") {
          let url = URL(fileURLWithPath: directory, isDirectory: true).appendingPathComponent("game-fullscreen-ready.png")
          try? OverlayLayoutDiagnostics.writeComposite(game: game, overlays: [panel], to: url)
          print("Wrote \(url.path)")
        }
        print("PASS: native full screen — button is on the full-screen Space, on screen at \(panel.frame), takes a click, key window unchanged")
        if let fullScreenObserver { NotificationCenter.default.removeObserver(fullScreenObserver) }
        fullScreenObserver = NotificationCenter.default.addObserver(forName: NSWindow.didExitFullScreenNotification,
          object: game, queue: .main) { _ in NSApp.terminate(nil) }
        game.toggleFullScreen(nil)
      }
    }
    game.toggleFullScreen(nil)
  }

  private static let phases: [(String, ReconnectButtonPhase)] = [
    ("ready", .ready), ("unavailable", .unavailable), ("reconnecting", .reconnecting), ("succeeded", .succeeded),
    ("noGameFound", .noGameFound), ("failed", .failed), ("cooldown", .cooldown(seconds: 4)),
  ]
  private static func phase(named name: String) -> ReconnectButtonPhase {
    phases.first { $0.0 == name }?.1 ?? .ready
  }

  private func showBugReport() {
    if bugReport == nil {
      bugReport = BugReportWindowController()
    }
    bugReport?.present()
  }
}

/// Stand-in for the Hearthstone board when no `--game-image` is given.
final class HarnessBoardView: NSView {
  override func draw(_ dirtyRect: NSRect) {
    NSGradient(starting: NSColor(calibratedRed: 0.42, green: 0.27, blue: 0.16, alpha: 1),
      ending: NSColor(calibratedRed: 0.20, green: 0.12, blue: 0.22, alpha: 1))?.draw(in: bounds, angle: -90)
  }
}

// Unbuffered, so PASS lines printed before a failed precondition still reach the log.
setvbuf(stdout, nil, _IONBF, 0)
let app = NSApplication.shared
let delegate = HarnessDelegate()
app.setActivationPolicy(.regular)
app.delegate = delegate
app.run()
