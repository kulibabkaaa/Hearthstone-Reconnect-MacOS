import AppKit

final class HarnessDelegate: NSObject, NSApplicationDelegate {
  private let overlay = LobbyOverlayController()
  private var settings: SettingsWindowController!
  private var bugReport: BugReportWindowController?

  func applicationDidFinishLaunching(_ notification: Notification) {
    if ProcessInfo.processInfo.arguments.contains("--bug-report")
      || UserDefaults.standard.bool(forKey: "HarnessBugReportMode")
    {
      bugReport = BugReportWindowController()
      bugReport?.present()
      return
    }
    let scale = ProcessInfo.processInfo.arguments.compactMap { $0.hasPrefix("--scale=") ? Double($0.dropFirst(8)) : nil }.first ?? 1
    let opacity = ProcessInfo.processInfo.arguments.compactMap { $0.hasPrefix("--opacity=") ? Double($0.dropFirst(10)) : nil }.first ?? 75
    let overlayOnly = ProcessInfo.processInfo.arguments.contains("--overlay-only")
    let requestedCapturePath = ProcessInfo.processInfo.arguments.first(where: { $0.hasPrefix("--capture=") }).map { String($0.dropFirst(10)) }
    let capturePath = requestedCapturePath ?? (overlayOnly
      ? "/tmp/hs-lobby-implementation-audit-01a0b660/overlay-\(Int(scale * 100))pct-opacity\(Int(opacity))-01a0b693.png"
      : nil)
    UserDefaults.standard.register(defaults: [DefaultsKey.lobbyEnabled: true,
      DefaultsKey.lobbyOpacity: opacity, DefaultsKey.lobbyScale: scale,
      DefaultsKey.lobbyShortcutDisplay: AppConfiguration.defaultLobbyShortcutDisplay])
    UserDefaults.standard.set(scale, forKey: DefaultsKey.lobbyScale)
    UserDefaults.standard.set(opacity, forKey: DefaultsKey.lobbyOpacity)
    UserDefaults.standard.removeObject(forKey: DefaultsKey.lobbyOriginX)
    UserDefaults.standard.removeObject(forKey: DefaultsKey.lobbyOriginY)
    settings = SettingsWindowController(onReconnect: {}, onShortcutChanged: { _,_,_ in true },
      onShortcutRecordingChanged: { _ in }, onOpenWithHearthstoneChanged: { _ in .success(()) },
      onShowInDockChanged: { value, done in done(value) }, onOpenSystemSettings: {}, onUninstall: {},
      onLobbyEnabledChanged: { _ in }, onLobbyOpacityChanged: { [weak self] in self?.overlay.opacityPercent = $0 },
      onLobbyShortcutChanged: { _,_,_ in true },
      onResetLobby: { [weak self] in self?.overlay.resetLayout() }, onRetryLobbySetup: {},
      onReportBug: { [weak self] in self?.showBugReport() },
      onCheckForUpdates: {}, automaticUpdateChecksEnabled: { true },
      onAutomaticUpdateChecksChanged: { _ in })
    settings.setStatus("Diagnostic harness — reconnect actions are disabled.")
    settings.setLobbyStatus("Sample lobby preview")
    settings.showWindow(nil); settings.window?.makeKeyAndOrderFront(nil)
    NSApp.activate(ignoringOtherApps: true)
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
  private func showBugReport() {
    if bugReport == nil {
      bugReport = BugReportWindowController()
    }
    bugReport?.present()
  }
}

let app = NSApplication.shared
let delegate = HarnessDelegate()
app.setActivationPolicy(.regular)
app.delegate = delegate
app.run()
