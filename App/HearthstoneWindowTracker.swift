import AppKit

/// Polls the Hearthstone window every 0.25 s and hands its frame to every overlay that follows the game.
/// One poll feeds the lobby and the Reconnect button, so neither depends on the other being enabled or running.
/// Each overlay checks that Hearthstone is frontmost itself (`HearthstoneApp.isFrontmost`).
final class HearthstoneWindowTracker {
  static let pollInterval: TimeInterval = 0.25
  private var subscribers: [(owner: ObjectIdentifier, handler: (NSRect?) -> Void)] = []
  private var timer: Timer?
  var isPolling: Bool { timer != nil }

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
  deinit { timer?.invalidate() }

  private func poll() {
    let frame = frame()
    subscribers.forEach { $0.handler(frame) }
  }

  /// The largest Hearthstone window in AppKit coordinates, or nil when the game isn't running or has no window.
  func frame(includeOffscreen: Bool = false) -> NSRect? {
    guard let app = NSWorkspace.shared.runningApplications.first(where: { $0.bundleIdentifier == HearthstoneApp.bundleIdentifier }) else { return nil }
    let options: CGWindowListOption = includeOffscreen ? [.optionAll, .excludeDesktopElements] : [.optionOnScreenOnly, .excludeDesktopElements]
    let items = CGWindowListCopyWindowInfo(options, kCGNullWindowID) as? [[String: Any]] ?? []
    for item in items.sorted(by: { windowArea($0) > windowArea($1) }) where (item[kCGWindowOwnerPID as String] as? Int32) == app.processIdentifier {
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
