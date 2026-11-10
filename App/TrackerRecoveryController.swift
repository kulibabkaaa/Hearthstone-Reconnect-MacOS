import AppKit
import Foundation
import OSLog

/// "Keep HSTracker working": after a reconnect, gets HSTracker to pick the match back up (why and how:
/// `TrackerRecovery` in AppCore, which also makes every decision).
///
/// This class only does the reading and writing. For the few seconds a reconnect takes it looks at Hearthstone's
/// `LoadingScreen.log` and HSTracker's own log every 20 ms, and appends a line to the first when told to. It does
/// nothing unless the option is on and HSTracker is running, and it never creates a file.
final class TrackerRecoveryController {
  /// Called on the main thread whenever the line under the switch changes.
  var onStatusChanged: ((TrackerRecoveryStatus) -> Void)?
  private(set) var status: TrackerRecoveryStatus = .off

  /// Where the two logs stood just before the reconnect, so only what came after is read.
  private struct Snapshot {
    let loadingLog: URL
    let loadingOffset: UInt64
    let trackerLog: URL
    let trackerOffset: UInt64
    let trackerBuild: String
    let takenAt: TimeInterval
  }

  /// Set on the main thread, read on the polling queue. Safe to share because the lock guards the only state.
  private final class Cancellation: @unchecked Sendable {
    private let lock = NSLock()
    private var cancelled = false
    var isCancelled: Bool { lock.withLock { cancelled } }
    func cancel() { lock.withLock { cancelled = true } }
  }

  /// One reconnect's recovery. Touched only on `queue` after it is created.
  private final class Run {
    var session: TrackerRecoverySession
    var trackerOffset: UInt64
    let snapshot: Snapshot
    let cancellation = Cancellation()
    init(session: TrackerRecoverySession, snapshot: Snapshot) {
      self.session = session
      self.snapshot = snapshot
      trackerOffset = snapshot.trackerOffset
    }
  }

  private static let pollInterval: TimeInterval = 0.02
  /// Longer than every wait in `TrackerRecoveryTiming` together; a backstop only.
  private static let hardLimit: TimeInterval = 60
  /// A snapshot older than this belongs to a reconnect that never happened.
  private static let snapshotLifetime: TimeInterval = 15
  private static let maximumReadBytes = 512 * 1024

  private let defaults: UserDefaults
  private let logger = Logger(subsystem: AppConfiguration.bundleIdentifier, category: "TrackerRecovery")
  private let queue = DispatchQueue(label: "HSReconnect.TrackerRecovery", qos: .userInitiated)
  private var health: TrackerRecoveryHealth
  private var snapshot: Snapshot?
  private var running: Cancellation?
  /// When HSTracker last restarted its game routine for us (system uptime).
  private var lastRecoveryAt: TimeInterval?
  /// How the last reconnect went; shown until HSTracker quits or the option changes.
  private var lastResult: TrackerRecoveryStatus?
  private var observers: [NSObjectProtocol] = []

  var isEnabled: Bool { defaults.bool(forKey: DefaultsKey.trackerRecoveryEnabled) }

  init(defaults: UserDefaults = .standard) {
    self.defaults = defaults
    health = TrackerRecoveryHealth(
      singleShotTrackerBuild: defaults.string(forKey: DefaultsKey.trackerRecoverySingleShotBuild),
      confirmedBrokenBuild: defaults.string(forKey: DefaultsKey.trackerRecoveryConfirmedBuild))
    let center = NSWorkspace.shared.notificationCenter
    for name in [NSWorkspace.didLaunchApplicationNotification, NSWorkspace.didTerminateApplicationNotification] {
      observers.append(center.addObserver(forName: name, object: nil, queue: .main) { [weak self] note in
        let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication
        guard app?.bundleIdentifier == TrackerRecovery.trackerBundleIdentifier else { return }
        // A tracker that just quit or started has nothing to do with how the last reconnect went.
        self?.lastResult = nil
        self?.refreshIdleStatus()
      })
    }
    refreshIdleStatus()
  }

  deinit {
    observers.forEach(NSWorkspace.shared.notificationCenter.removeObserver)
  }

  func setEnabled(_ enabled: Bool) {
    defaults.set(enabled, forKey: DefaultsKey.trackerRecoveryEnabled)
    // Switching it off and on is how the user asks for a fresh start.
    health.reset()
    persistHealth()
    lastResult = nil
    snapshot = nil
    if !enabled { cancelRunning() }
    refreshIdleStatus()
  }

  /// Call just before the reconnect request goes out, with the running game's log folder.
  func reconnectWillBegin(logDirectory: URL?) {
    snapshot = nil
    guard isEnabled, let logDirectory, let trackerBuild = Self.runningTrackerBuild() else { return }
    let loadingLog = logDirectory.appendingPathComponent("LoadingScreen.log")
    guard Self.isHearthstoneLoadingLog(loadingLog), let loadingSize = Self.size(of: loadingLog) else { return }
    let trackerLog = FileManager.default.homeDirectoryForCurrentUser
      .appendingPathComponent("Library/Logs/HSTracker/hstracker.log")
    snapshot = Snapshot(
      loadingLog: loadingLog, loadingOffset: loadingSize, trackerLog: trackerLog,
      trackerOffset: Self.size(of: trackerLog) ?? 0, trackerBuild: trackerBuild,
      takenAt: ProcessInfo.processInfo.systemUptime)
  }

  /// Call once the extension has closed the game's connection: Hearthstone is about to reload the scene.
  func reconnectDidCloseFlow() {
    let now = ProcessInfo.processInfo.systemUptime
    guard isEnabled, let snapshot, now - snapshot.takenAt < Self.snapshotLifetime else { return }
    self.snapshot = nil
    cancelRunning()
    let run = Run(
      session: TrackerRecoverySession(
        startedAt: now, lastRecoveryAt: lastRecoveryAt,
        singleShot: health.usesSingleShot(trackerBuild: snapshot.trackerBuild),
        patient: health.usesPatientPath(trackerBuild: snapshot.trackerBuild)),
      snapshot: snapshot)
    running = run.cancellation
    setStatus(.working)
    queue.async { [weak self] in self?.poll(run) }
  }

  func stop() {
    cancelRunning()
    snapshot = nil
  }

  // MARK: - Polling (on `queue`)

  private func poll(_ run: Run) {
    guard !run.cancellation.isCancelled else { return }
    let now = ProcessInfo.processInfo.systemUptime
    guard now - run.session.startedAt < Self.hardLimit,
      let loading = Self.read(run.snapshot.loadingLog, from: run.snapshot.loadingOffset)
    else {
      // The log vanished or was emptied (Hearthstone quit), or the backstop was reached. If a line already went
      // in, nothing confirmed it; otherwise there was no match to recover.
      finish(run, run.session.outcome ?? (run.session.writes > 0 ? .unverified : .noReload))
      return
    }
    let step = run.session.advance(TrackerRecoveryObservation(
      now: now, loadingText: loading.text, loadingSize: loading.size, loadingModified: loading.modified,
      trackerText: readTrackerLog(run)))
    switch step {
    case .wait:
      break
    case .write:
      // Checked again right here: the option may have been switched off, or a newer reconnect started, since
      // the top of this pass.
      if run.cancellation.isCancelled {
        return
      } else if loading.endsWithNewline {
        let succeeded = Self.append(TrackerNudgeLine.make(now: Date()), to: run.snapshot.loadingLog)
        run.session.didWrite(at: ProcessInfo.processInfo.systemUptime, succeeded: succeeded)
      } else {
        run.session.writePostponed()
      }
    case .finish(let outcome):
      finish(run, outcome)
      return
    }
    queue.asyncAfter(deadline: .now() + Self.pollInterval) { [weak self] in self?.poll(run) }
  }

  /// HSTracker's log since the reconnect; nil when it can't be read. It rotates at about 2 MB, which shows as the
  /// file being shorter than where we started: then everything in the new file is new.
  private func readTrackerLog(_ run: Run) -> String? {
    if let size = Self.size(of: run.snapshot.trackerLog), size < run.trackerOffset { run.trackerOffset = 0 }
    return Self.read(run.snapshot.trackerLog, from: run.trackerOffset)?.text
  }

  private func finish(_ run: Run, _ outcome: TrackerRecoveryOutcome) {
    DispatchQueue.main.async { [weak self] in
      guard let self, self.running === run.cancellation else { return }
      self.running = nil
      self.health.record(outcome, trackerBuild: run.snapshot.trackerBuild)
      self.persistHealth()
      switch outcome {
      case .recovered, .unverified, .noResponse, .recoveredUnaided:
        // HSTracker ignores a game start within 5 s of its last. An unconfirmed line may have been read all the
        // same, and a tracker that recovered by itself just ran one, so each counts as its last game start.
        self.lastRecoveryAt = ProcessInfo.processInfo.systemUptime
      case .noReload, .leftMatch, .writeFailed:
        break
      }
      let result = TrackerRecoveryStatus.after(outcome)
      self.lastResult = result == .ready ? nil : result
      // `notice`, not `info`: macOS keeps notices on disk, and this line is how a field problem gets diagnosed.
      self.logger.notice(
        "Recovery for HSTracker build \(run.snapshot.trackerBuild, privacy: .public): \(String(describing: outcome), privacy: .public)"
      )
      self.refreshIdleStatus()
    }
  }

  // MARK: - Main thread

  private func cancelRunning() {
    running?.cancel()
    running = nil
  }

  private func persistHealth() {
    for (key, build) in [
      (DefaultsKey.trackerRecoverySingleShotBuild, health.singleShotTrackerBuild),
      (DefaultsKey.trackerRecoveryConfirmedBuild, health.confirmedBrokenBuild),
    ] {
      if let build { defaults.set(build, forKey: key) } else { defaults.removeObject(forKey: key) }
    }
  }

  private func refreshIdleStatus() {
    guard running == nil else { return }
    if !isEnabled {
      setStatus(.off)
    } else if Self.runningTrackerBuild() == nil {
      setStatus(.trackerNotRunning)
    } else {
      setStatus(lastResult ?? .ready)
    }
  }

  private func setStatus(_ new: TrackerRecoveryStatus) {
    guard new != status else { return }
    status = new
    onStatusChanged?(new)
  }

  // MARK: - Files

  /// The build number of the running HSTracker, read from disk each time: it updates itself often, and a cached
  /// bundle would keep reporting the build that was there at launch.
  private static func runningTrackerBuild() -> String? {
    let apps = NSRunningApplication.runningApplications(
      withBundleIdentifier: TrackerRecovery.trackerBundleIdentifier
    ).filter { !$0.isTerminated }
    guard let app = apps.first else { return nil }
    let info = app.bundleURL.flatMap {
      NSDictionary(contentsOf: $0.appendingPathComponent("Contents/Info.plist"))
    }
    return (info?["CFBundleVersion"] as? String) ?? "unknown"
  }

  /// Only ever `…/Hearthstone_<date>/LoadingScreen.log`.
  private static func isHearthstoneLoadingLog(_ url: URL) -> Bool {
    url.lastPathComponent == "LoadingScreen.log"
      && url.deletingLastPathComponent().lastPathComponent.hasPrefix("Hearthstone_")
  }

  private static func size(of url: URL) -> UInt64? {
    (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? NSNumber)?.uint64Value
  }

  /// Everything from `offset` to the end. nil when the file is missing or shorter than `offset`.
  private static func read(_ url: URL, from offset: UInt64)
    -> (text: String, size: UInt64, modified: TimeInterval, endsWithNewline: Bool)?
  {
    guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
    defer { try? handle.close() }
    var info = stat()
    let modified = fstat(handle.fileDescriptor, &info) == 0
      ? TimeInterval(info.st_mtimespec.tv_sec) + TimeInterval(info.st_mtimespec.tv_nsec) / 1_000_000_000 : 0
    guard let size = try? handle.seekToEnd(), size >= offset else { return nil }
    // Far more than a reconnect ever writes; if something does, the newest part is the part that matters.
    let start = max(offset, size > UInt64(maximumReadBytes) ? size - UInt64(maximumReadBytes) : 0)
    guard (try? handle.seek(toOffset: start)) != nil, let data = try? handle.readToEnd() ?? Data() else {
      return nil
    }
    var endsWithNewline = data.last == UInt8(ascii: "\n")
    if data.isEmpty, size > 0, (try? handle.seek(toOffset: size - 1)) != nil {
      endsWithNewline = (try? handle.read(upToCount: 1))?.first == UInt8(ascii: "\n")
    }
    return (String(decoding: data, as: UTF8.self), size, modified, endsWithNewline || size == 0)
  }

  /// One write at the end of an existing, ordinary file. Never creates it: if Hearthstone's log isn't there,
  /// nothing is. Never follows a link: the Logs folder is writable by anyone on the Mac, and a link planted in
  /// place of the log must not send our line to some other file.
  private static func append(_ line: String, to url: URL) -> Bool {
    guard isHearthstoneLoadingLog(url) else { return false }
    let descriptor = open(url.path, O_WRONLY | O_APPEND | O_NOFOLLOW)
    guard descriptor >= 0 else { return false }
    defer { close(descriptor) }
    var info = stat()
    guard fstat(descriptor, &info) == 0, (info.st_mode & S_IFMT) == S_IFREG else { return false }
    let bytes = Array(line.utf8)
    return bytes.withUnsafeBytes { write(descriptor, $0.baseAddress, $0.count) } == bytes.count
  }
}
