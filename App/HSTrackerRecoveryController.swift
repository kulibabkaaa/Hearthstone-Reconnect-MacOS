import AppKit
import Foundation

/// All recovery work belongs to HS Reconnect. HSTracker's app and preferences
/// are never edited, and its process is neither stopped nor relaunched.
final class HSTrackerRecoveryController {
  final class Request {
    let game: NSRunningApplication
    let tracker: NSRunningApplication
    let loadingLog: HSTrackerRecoveryLog
    let trackerLog: HSTrackerRecoveryLog?
    var observation = HSTrackerRecoveryObservation()
    var verificationDeadline: Date?
    var deadline = Date()
    var earliestRecoveryAt = Date()

    init(game: NSRunningApplication, tracker: NSRunningApplication,
         loadingLog: HSTrackerRecoveryLog, trackerLog: HSTrackerRecoveryLog?) {
      self.game = game
      self.tracker = tracker
      self.loadingLog = loadingLog
      self.trackerLog = trackerLog
    }
  }

  var onStatus: ((String, Bool) -> Void)?
  private let queue = DispatchQueue(label: "HSReconnect.HSTrackerRecovery")
  private var timer: DispatchSourceTimer?
  private var active: Request?

  /// Capture offsets before disconnecting so an earlier reconnect cannot be
  /// mistaken for completion of the request about to be sent to the extension.
  func prepare(for context: GameReconnectContext) -> Request? {
    let trackers = NSRunningApplication.runningApplications(
      withBundleIdentifier: "net.hearthsim.hstracker"
    ).filter { !$0.isTerminated }
    guard trackers.count == 1, let tracker = trackers.first,
          let bundleURL = tracker.bundleURL,
          let version = Bundle(url: bundleURL)?.object(
            forInfoDictionaryKey: "CFBundleShortVersionString") as? String,
          HSTrackerRecoveryPolicy.needsRecovery(version: version),
          let directory = context.logDirectory else { return nil }
    do {
      let loadingLog = try HSTrackerRecoveryLog(
        url: directory.appendingPathComponent("LoadingScreen.log"))
      let trackerLogURL = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Library/Logs/HSTracker/hstracker.log")
      return Request(game: context.application, tracker: tracker, loadingLog: loadingLog,
        trackerLog: try? HSTrackerRecoveryLog(url: trackerLogURL))
    } catch {
      NSLog("HSTracker recovery could not read the game log: %@", error as NSError)
      return nil
    }
  }

  /// Called only when the extension confirms it closed the selected game flow.
  func recover(_ request: Request?) {
    guard let request else { return }
    queue.async { [self] in
      self.finish()
      self.active = request
      request.deadline = Date().addingTimeInterval(HSTrackerRecoveryPolicy.timeout)
      // HSTracker ignores gameStart calls within five seconds of the previous
      // one. This also covers reconnecting immediately after entering a match.
      request.earliestRecoveryAt = Date().addingTimeInterval(5.5)
      let timer = DispatchSource.makeTimerSource(queue: self.queue)
      timer.schedule(deadline: .now(), repeating: .milliseconds(250))
      timer.setEventHandler { [weak self] in self?.poll() }
      self.timer = timer
      timer.resume()
    }
  }

  func cancel() { queue.async { self.finish() } }

  private func poll() {
    guard let request = active else { return }
    guard !request.game.isTerminated, !request.tracker.isTerminated else {
      finish()
      return
    }
    do {
      if let deadline = request.verificationDeadline {
        let text = try request.trackerLog?.readNewLines() ?? ""
        if HSTrackerRecoveryPolicy.didRecoverPlayers(in: text) {
          report("HSTracker match data resumed.", isError: false)
          finish()
        } else if Date() >= deadline {
          report("Game reconnected; HSTracker recovery could not be verified.", isError: true)
          finish()
        }
        return
      }
      guard Date() < request.deadline else {
        report("Game reconnect sent; HSTracker recovery timed out.", isError: true)
        finish()
        return
      }
      request.observation.observe(try request.loadingLog.readNewLines())
      switch request.observation.state {
      case .waiting:
        break
      case .cancelled:
        finish()
      case .ready:
        guard Date() >= request.earliestRecoveryAt else { return }
        // A tracker initialization that preceded this reload is not evidence
        // that the event below worked. Verification failure must not prevent
        // attempting to restore the current match.
        try? request.trackerLog?.discardPendingLines()
        if try request.loadingLog.appendRecoveryEvent(at: Date()) {
          report("Game reconnected. Restoring HSTracker match data…", isError: false)
          request.verificationDeadline = Date().addingTimeInterval(40)
        }
      }
    } catch {
      NSLog("HSTracker recovery stopped: %@", error as NSError)
      report("Game reconnect sent; HSTracker recovery could not finish.", isError: true)
      finish()
    }
  }

  private func report(_ status: String, isError: Bool) {
    DispatchQueue.main.async { [weak self] in self?.onStatus?(status, isError) }
  }

  private func finish() {
    timer?.cancel()
    timer = nil
    active = nil
  }
}
