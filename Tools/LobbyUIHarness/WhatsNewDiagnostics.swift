import AppKit

/// Self-test and captures for `--whats-new`. Uses its own defaults suite, never the app's settings.
enum WhatsNewDiagnostics {
  static let suite = "io.github.kulibabkaaa.HSReconnect.WhatsNewHarness"

  /// A clean suite, optionally with a stored "seen version" value.
  static func defaults(seen: Any? = nil) -> UserDefaults {
    let defaults = UserDefaults(suiteName: suite)!
    defaults.removePersistentDomain(forName: suite)
    if let seen { defaults.set(seen, forKey: DefaultsKey.whatsNewSeenVersion) }
    return defaults
  }

  static func verify(host: NSWindow, reconnectPresses: () -> Int, reopenWindow: () -> Void) {
    func check(_ condition: Bool, _ message: String) {
      guard condition else { print("FAIL: \(message)"); exit(1) }
    }
    func seen(_ defaults: UserDefaults) -> Bool {
      defaults.integer(forKey: DefaultsKey.whatsNewSeenVersion) == WhatsNewPolicy.currentVersion
    }
    func present(_ presenter: WhatsNewPresenter, ready: Bool = true) {
      presenter.presentIfNeeded(over: host, isReconnectReady: ready)
      spin(0.4)
    }

    // The text names the user's own shortcuts, as the main window does, with the defaults as fallback.
    let custom = Self.defaults()
    custom.set("Cmd+1", forKey: DefaultsKey.hotkeyDisplay)
    custom.set("Cmd+Option+P", forKey: DefaultsKey.lobbyShortcutDisplay)
    let customText = WhatsNewContent.current(defaults: custom).rows.map(\.detail).joined(separator: " ")
    check(customText.contains("Works like Cmd+1.") && customText.contains("Press Cmd+Option+P,")
      && !customText.contains("Cmd+Shift"), "the text must use the user's own shortcuts: \(customText)")
    custom.set("  ", forKey: DefaultsKey.hotkeyDisplay)
    custom.set("", forKey: DefaultsKey.lobbyShortcutDisplay)
    let fallbackText = WhatsNewContent.current(defaults: custom).rows.map(\.detail).joined(separator: " ")
    check(fallbackText.contains("Works like the Reconnect shortcut.") && fallbackText.contains("Press the position shortcut,"),
      "missing shortcuts must fall back: \(fallbackText)")
    print("PASS: the text names the user's own shortcuts (Cmd+1 here) and falls back when one is missing")

    // Waits for setup, then shows once; Return = Done; never again after that.
    var defaults = Self.defaults()
    var presenter = WhatsNewPresenter(defaults: defaults)
    present(presenter, ready: false)
    check(!presenter.isShowing && !seen(defaults), "it must wait while Reconnect isn't ready")
    present(presenter)
    check(presenter.isShowing, "it must show once Reconnect is ready")
    present(presenter)
    check(host.contentView?.subviews.filter { $0 is WhatsNewSpotlightView }.count == 1, "it must never stack")
    checkSpotlight(presenter, host: host, check: check)
    press(36, "\r", host, release: false)
    check(!presenter.isShowing && seen(defaults), "Return must work as Done and mark it seen")
    check(reconnectPresses() == 0, "Return must not also press Reconnect Now under the spotlight")
    press(36, "\r", host, repeat: true, release: false)
    check(reconnectPresses() == 0, "a held Return must not repeat into Reconnect Now")
    press(36, "\r", host, release: false)
    check(reconnectPresses() == 1 && !presenter.diagnosticIsWatchingKeys,
      "a fresh Return after a missed release must work normally")
    press(36, "\r", host, keyUp: true)
    check(!presenter.diagnosticIsWatchingKeys, "it must stop watching keys once Return is released")
    press(36, "\r", host)
    check(reconnectPresses() == 2, "after release Return must reach Reconnect Now again")
    presenter = WhatsNewPresenter(defaults: defaults)
    present(presenter)
    check(!presenter.isShowing, "it must never show twice")
    print("PASS: waits for setup, shows once, Return closes it (without reconnecting) and marks it seen, then works "
      + "normally again; a later launch shows nothing")

    // Readiness dropping takes it down without marking it seen; it comes back when ready again.
    defaults = Self.defaults()
    presenter = WhatsNewPresenter(defaults: defaults)
    present(presenter)
    present(presenter, ready: false)
    check(!presenter.isShowing && !seen(defaults), "losing readiness must hide it without marking it seen")
    present(presenter)
    check(presenter.isShowing, "it must come back once Reconnect is ready again")
    // Reopening the window while it's up gives it the keyboard back.
    host.makeFirstResponder(nil)
    present(presenter)
    check(host.firstResponder === presenter.diagnosticSpotlight, "reopening must give the spotlight the keyboard back")
    print("PASS: losing readiness hides it unseen and it returns when ready; reopening refocuses it")
    press(53, "\u{1b}", host)
    check(!presenter.isShowing && seen(defaults), "Esc must close it and mark it seen")
    print("PASS: Esc closes it and marks it seen")

    defaults = Self.defaults()
    presenter = WhatsNewPresenter(defaults: defaults)
    present(presenter)
    presenter.diagnosticSpotlight?.doneButton.performClick(nil)
    spin(0.3)
    check(!presenter.isShowing && seen(defaults), "Done must close it and mark it seen")
    print("PASS: Done closes it and marks it seen")

    defaults = Self.defaults()
    presenter = WhatsNewPresenter(defaults: defaults)
    present(presenter)
    host.close()
    spin(0.3)
    check(!presenter.isShowing && seen(defaults), "closing the main window must mark it seen")
    present(presenter)
    check(!presenter.isShowing, "it must not show on a hidden window")
    reopenWindow()
    spin(0.3)
    print("PASS: closing the main window marks it seen; nothing shows on a hidden window")

    // Never over the Settings page: with the switch off screen it waits.
    defaults = Self.defaults()
    presenter = WhatsNewPresenter(defaults: defaults)
    let target = WhatsNewSpotlightView.findTarget(in: host.contentView)
    target?.isHidden = true
    present(presenter)
    check(!presenter.isShowing && !seen(defaults), "it must wait while the switch isn't on screen")
    target?.isHidden = false
    present(presenter)
    check(presenter.isShowing, "it must show once the switch is on screen")
    presenter.dismiss()
    print("PASS: it waits while the Reconnect button switch isn't on screen (e.g. the Settings page)")

    defaults = Self.defaults(seen: "garbage")
    presenter = WhatsNewPresenter(defaults: defaults)
    present(presenter)
    check(presenter.isShowing, "an unreadable stored value must count as not seen")
    presenter.dismiss()
    check(seen(defaults), "dismissing must replace the odd value")
    check(!(host.contentView?.subviews.contains { $0 is WhatsNewSpotlightView } ?? true),
      "nothing may stay over the main window after dismissal")
    print("PASS: an odd stored value counts as not seen and is replaced; nothing stays over the window")
  }

  private static func checkSpotlight(_ presenter: WhatsNewPresenter, host: NSWindow, check: (Bool, String) -> Void) {
    guard let spotlight = presenter.diagnosticSpotlight, let root = host.contentView else {
      return check(false, "no spotlight")
    }
    check(spotlight.doneButton.title == "Done", "Done must exist")
    check(host.firstResponder === spotlight, "the spotlight must take the keyboard so Return/Esc reach it")
    check(spotlight.accessibilityLabel()?.hasPrefix("What's New") == true, "the spotlight needs a VoiceOver label")
    let pictures = allViews(in: spotlight).compactMap { $0 as? WhatsNewButtonPicture }
    check(pictures.count == 1 && pictures.allSatisfy {
      $0.isAccessibilityElement() && $0.accessibilityRole() == .image && !($0.accessibilityLabel() ?? "").isEmpty
        && !$0.subviews.contains { $0.isAccessibilityElement() }
    }, "the button picture must be one labelled image for VoiceOver, with the live button hidden from it")
    guard let spot = spotlight.spotlightRect else { return check(false, "the spotlight didn't find the switch") }
    let card = allViews(in: spotlight).first { $0 is WhatsNewCalloutView }
    check(spotlight.isCardAboveSpotlight && (card.map { $0.frame.maxY < spot.minY } ?? false),
      "the card must leave the highlighted row fully visible")
    check(allViews(in: spotlight).contains { ($0 as? NSTextField)?.stringValue == WhatsNewContent.switchBelow },
      "with the card above the row, the last line must say the switch is below")
    let hit = root.hitTest(root.convert(NSPoint(x: spot.maxX - 30, y: spot.midY), from: spotlight))
    check(hit is NSSwitch, "the highlighted switch must stay clickable (hit \(String(describing: hit)))")
    let outside = root.hitTest(root.convert(NSPoint(x: spot.midX, y: spot.maxY + 40), from: spotlight))
    check(outside === spotlight, "controls outside the spotlight must be blocked (hit \(String(describing: outside)))")
    print("PASS: spotlight finds the Reconnect button switch and leaves only it clickable; VoiceOver labels present")
  }

  /// A key press as the window would get it: keyDown (optionally an auto-repeat), then keyUp unless `release` is false.
  private static func press(_ keyCode: UInt16, _ characters: String, _ window: NSWindow, repeat isRepeat: Bool = false,
    release: Bool = true, keyUp onlyUp: Bool = false) {
    window.makeKeyAndOrderFront(nil)
    spin(0.2)
    func send(_ type: NSEvent.EventType, repeat flag: Bool) {
      guard let event = NSEvent.keyEvent(with: type, location: .zero, modifierFlags: [], timestamp: 0,
        windowNumber: window.windowNumber, context: nil, characters: characters,
        charactersIgnoringModifiers: characters, isARepeat: flag, keyCode: keyCode) else { return }
      NSApp.sendEvent(event)
      spin(0.15)
    }
    if !onlyUp { send(.keyDown, repeat: isRepeat) }
    if release || onlyUp { send(.keyUp, repeat: false) }
    spin(0.15)
  }

  private static func spin(_ seconds: TimeInterval) { RunLoop.current.run(until: Date().addingTimeInterval(seconds)) }

  private static func allViews(in view: NSView) -> [NSView] { [view] + view.subviews.flatMap(allViews) }

  /// Captures the screen area of the main window only. The harness is frontmost, so nothing else is in that area.
  static func capture(host: NSWindow, to path: String) {
    let screenHeight = NSScreen.screens.first?.frame.height ?? 0
    let frame = host.frame
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture")
    process.arguments = ["-x", "-R\(Int(frame.minX)),\(Int(screenHeight - frame.maxY)),\(Int(frame.width)),\(Int(frame.height))",
      path]
    try? process.run()
    process.waitUntilExit()
    print(FileManager.default.fileExists(atPath: path) ? "Wrote \(path)" : "FAIL: couldn't capture \(path)")
  }
}
