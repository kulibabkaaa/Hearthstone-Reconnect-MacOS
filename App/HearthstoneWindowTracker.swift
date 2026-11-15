import AppKit

/// Polls the Hearthstone window every 0.25 s and hands its frame to every overlay that follows the game.
/// One poll feeds the lobby and the Reconnect button, so neither depends on the other being enabled or running.
/// Each overlay checks that Hearthstone is frontmost itself (`HearthstoneApp.isFrontmost`).
///
/// The Hearthstone process is found once and reused while it runs (`ProcessLookupCache`): finding it means asking
/// Launch Services about every running app, which at four polls a second was most of the app's idle CPU.
final class HearthstoneWindowTracker {
  static let pollInterval: TimeInterval = 0.25
  private var subscribers: [(owner: ObjectIdentifier, handler: (NSRect?) -> Void)] = []
  private var timer: Timer?
  private var lookupCache = ProcessLookupCache()
  private var cachedApp: NSRunningApplication?
  private var workspaceObservers: [NSObjectProtocol] = []
  var isPolling: Bool { timer != nil }

  init() {
    // Any launch or quit may be Hearthstone's (or a second copy of it): look it up again on the next poll.
    let center = NSWorkspace.shared.notificationCenter
    for name in [NSWorkspace.didLaunchApplicationNotification, NSWorkspace.didTerminateApplicationNotification] {
      workspaceObservers.append(center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
        self?.lookupCache.invalidate()
      })
    }
  }

  /// Calls `handler` on every poll until `unsubscribe(owner)`. Subscribing again replaces the handler.
  /// The timer runs only while someone is subscribed.
  func subscribe(_ owner: AnyObject, _ handler: @escaping (NSRect?) -> Void) {
    let id = ObjectIdentifier(owner)
    if let index = subscribers.firstIndex(where: { $0.owner == id }) {
      subscribers[index].handler = handler
    } else {
      subscribers.append((id, handler))
    }
    guard timer == nil else { return }
    let timer = Timer(timeInterval: Self.pollInterval, repeats: true) { [weak self] _ in self?.poll() }
    RunLoop.main.add(timer, forMode: .common)
    self.timer = timer
  }
  func unsubscribe(_ owner: AnyObject) {
    let id = ObjectIdentifier(owner)
    subscribers.removeAll { $0.owner == id }
    if subscribers.isEmpty { timer?.invalidate(); timer = nil }
  }
  deinit {
    timer?.invalidate()
    workspaceObservers.forEach(NSWorkspace.shared.notificationCenter.removeObserver)
  }

  private func poll() {
    let frame = frame()
    subscribers.forEach { $0.handler(frame) }
  }

  /// The running Hearthstone, found again only when `ProcessLookupCache` says so.
  private func hearthstone() -> NSRunningApplication? {
    let now = ProcessInfo.processInfo.systemUptime
    let cachedIsRunning = cachedApp.map { !$0.isTerminated } ?? false
    if lookupCache.needsLookup(now: now, cachedIsRunning: cachedIsRunning) {
      cachedApp = NSRunningApplication.runningApplications(withBundleIdentifier: HearthstoneApp.bundleIdentifier)
        .first { !$0.isTerminated }
      lookupCache.didLookUp(now: now, found: cachedApp != nil)
    }
    return cachedApp
  }

  /// The largest Hearthstone window in AppKit coordinates, or nil when the game isn't running or has no window.
  func frame(includeOffscreen: Bool = false) -> NSRect? {
    guard let app = hearthstone() else { return nil }
    let pid = app.processIdentifier
    let options: CGWindowListOption = includeOffscreen ? [.optionAll, .excludeDesktopElements] : [.optionOnScreenOnly, .excludeDesktopElements]
    let items = CGWindowListCopyWindowInfo(options, kCGNullWindowID) as? [[String: Any]] ?? []
    // Only the game's own windows are measured and sorted, largest first.
    let windows = items.filter { ($0[kCGWindowOwnerPID as String] as? Int32) == pid }
    for item in windows.sorted(by: { windowArea($0) > windowArea($1) }) {
      if let dict = item[kCGWindowBounds as String] as? NSDictionary,
         let quartz = CGRect(dictionaryRepresentation: dict), quartz.width > 500, quartz.height > 300 {
        let primaryTop = NSScreen.screens.first?.frame.maxY ?? quartz.maxY
        return NSRect(x: quartz.minX, y: primaryTop - quartz.maxY,
                      width: quartz.width, height: quartz.height)
      }
    }
    return nil
  }
  private func windowArea(_ item: [String: Any]) -> CGFloat {
    guard let bounds = item[kCGWindowBounds as String] as? NSDictionary,
          let rect = CGRect(dictionaryRepresentation: bounds) else { return 0 }
    return rect.width * rect.height
  }
}
