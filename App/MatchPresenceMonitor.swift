import AppKit
import Darwin

/// The Reconnect button's own "in a match" signal: about once a second it reads Hearthstone's open connections and
/// the lines its logs gained since the last poll, and lets `MatchPresenceCore` decide. Needs no memory reading, no
/// permission prompt and no `log.config`; it only reads (never writes into Hearthstone's folders).
///
/// Main-thread API. The polling runs on a private utility queue that alone owns the core and the log readers.
final class MatchPresenceMonitor {
  static let pollInterval: TimeInterval = 1
  /// Called on the main thread when `detectorState` or `isInMatch` changes.
  var onChange: (() -> Void)?
  private(set) var detectorState = MatchDetectorState.connecting
  private(set) var isInMatch = false
  private(set) var isRunning = false

  private let queue = DispatchQueue(label: "\(AppConfiguration.bundleIdentifier).MatchPresence", qos: .utility)
  private var timer: DispatchSourceTimer?
  /// Main thread only: results from a poll scheduled before the latest start or stop are dropped.
  private var generation = 0
  /// Queue only.
  private var poller = Poller()

  func start() {
    guard !isRunning else { return }
    isRunning = true
    generation += 1
    let generation = generation
    let timer = DispatchSource.makeTimerSource(queue: queue)
    timer.schedule(deadline: .now(), repeating: Self.pollInterval, leeway: .milliseconds(100))
    timer.setEventHandler { [weak self] in
      guard let self else { return }
      let result = self.poller.poll(now: ProcessInfo.processInfo.systemUptime)
      DispatchQueue.main.async { [weak self] in
        guard let self, self.generation == generation else { return }
        self.publish(result)
      }
    }
    self.timer = timer
    timer.resume()
  }

  func stop() {
    guard isRunning else { return }
    isRunning = false
    generation += 1
    timer?.cancel()
    timer = nil
    queue.async { [weak self] in self?.poller = Poller() }
    publish(Poller.Result(detectorState: .connecting, isInMatch: false, summary: nil))
  }

  /// A reconnect was asked for: hold the match while the game connection closes and reopens.
  func noteReconnect() {
    let now = ProcessInfo.processInfo.systemUptime
    queue.async { [weak self] in self?.poller.core.noteReconnect(at: now) }
  }

  private func publish(_ result: Poller.Result) {
    guard result.detectorState != detectorState || result.isInMatch != isInMatch else { return }
    detectorState = result.detectorState
    isInMatch = result.isInMatch
    // Counts and states only, never addresses.
    DiagnosticLog.notice(
      .matchPresence,
      "inMatch=\(result.isInMatch) detector=\(String(describing: result.detectorState)) \(result.summary ?? "stopped")"
    )
    onChange?()
  }

  /// One Hearthstone process at a time: its connections, its session log folder and how far each log was read.
  private struct Poller {
    struct Result {
      let detectorState: MatchDetectorState
      let isInMatch: Bool
      let summary: String?
    }

    var core = MatchPresenceCore()
    private var processIdentifier: pid_t?
    private var launchDate: Date?
    private var directory: URL?
    private var nextDirectoryCheck: TimeInterval = 0
    private var tails: [LogTail] = []

    mutating func poll(now: TimeInterval) -> Result {
      let running = NSRunningApplication.runningApplications(withBundleIdentifier: HearthstoneApp.bundleIdentifier)
        .filter { !$0.isTerminated && $0.processIdentifier > 0 }
      // No game (or two copies, which the reconnect refuses too): nothing to show the button over.
      guard running.count == 1, let game = running.first else {
        if processIdentifier != nil { self = Poller() }
        return Result(detectorState: .connecting, isInMatch: false, summary: "hearthstone=\(running.count)")
      }
      if game.processIdentifier != processIdentifier {
        self = Poller()
        processIdentifier = game.processIdentifier
        launchDate = Self.startDate(of: game.processIdentifier) ?? game.launchDate
      }
      // Looked up again now and then: a folder picked too early would otherwise stick for the whole session.
      if now >= nextDirectoryCheck {
        nextDirectoryCheck = now + (directory == nil ? 2 : 10)
        if let found = currentSessionDirectory(), found != directory {
          if directory != nil { core = MatchPresenceCore() }
          directory = found
          tails = ["GameNetLogger.log", "Hearthstone.log", "LoadingScreen.log"].map {
            LogTail(url: found.appendingPathComponent($0))
          }
        }
      }
      for index in tails.indices {
        let historical = !tails[index].hasRead
        core.ingest(tails[index].readNewLines().compactMap(MatchLogParser.parse), now: now, historical: historical)
      }
      let connections = HearthstoneConnections.openTCPRemoteEndpoints(pid: game.processIdentifier)?
        .map { "\($0.host):\($0.port)" }
      let presence = core.evaluate(openConnections: connections, now: now)
      let summary = "gamePort=\(core.lastGamePortConnections) loggedServer=\(core.lastSawLoggedGameServer) "
        + "phase=\(core.phase) kind=\(core.kind) logs=\(directory != nil)"
      return Result(detectorState: core.detectorState, isInMatch: presence == .inMatch, summary: summary)
    }

    /// The running game's session folder, but only once Hearthstone has made it: until then the newest folder is
    /// the previous session's, whose last match would be read as this one.
    private func currentSessionDirectory() -> URL? {
      guard let url = GameEndpointResolver().currentLogDirectory() else { return nil }
      guard let launchDate else { return url }
      let created = (try? url.resourceValues(forKeys: [.creationDateKey]).creationDate) ?? .distantPast
      return created >= launchDate.addingTimeInterval(-5) ? url : nil
    }

    /// When the process started, from the kernel. `NSRunningApplication.launchDate` is nil for apps that weren't
    /// launched through Launch Services, which may be how Battle.net starts Hearthstone.
    private static func startDate(of pid: pid_t) -> Date? {
      var info = proc_bsdinfo()
      let size = Int32(MemoryLayout<proc_bsdinfo>.stride)
      guard proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &info, size) == size else { return nil }
      return Date(timeIntervalSince1970: TimeInterval(info.pbi_start_tvsec) + TimeInterval(info.pbi_start_tvusec) / 1_000_000)
    }
  }

  /// Reads what a log gained since the last call, whole lines only. Starts from the last `initialBytes` of the file;
  /// starts over when the file got shorter.
  private struct LogTail {
    static let initialBytes: UInt64 = 2 * 1024 * 1024
    /// More than this in one poll is a burst of noise; skip to its last part (events are time stamped).
    static let maximumBytesPerRead: UInt64 = 4 * 1024 * 1024
    let url: URL
    private var offset: UInt64?
    /// False until the first read that reached the file: what that read returns was written before monitoring.
    private(set) var hasRead = false
    private var remainder = Data()

    init(url: URL) { self.url = url }

    mutating func readNewLines() -> [Substring] {
      guard let handle = try? FileHandle(forReadingFrom: url) else { return [] }
      defer { try? handle.close() }
      guard let length = try? handle.seekToEnd() else { return [] }
      defer { hasRead = true }
      var start: UInt64
      if let offset, offset <= length {
        start = offset
      } else {
        start = offset == nil && length > Self.initialBytes ? length - Self.initialBytes : 0
        remainder = Data()
      }
      if length - start > Self.maximumBytesPerRead {
        start = length - Self.maximumBytesPerRead
        remainder = Data()
      }
      guard start < length else { offset = length; return [] }
      guard (try? handle.seek(toOffset: start)) != nil, let data = try? handle.read(upToCount: Int(length - start))
      else { return [] }
      offset = start + UInt64(data.count)
      var bytes = remainder + data
      // Keep a line that isn't finished yet for the next read.
      if let lastNewline = bytes.lastIndex(of: UInt8(ascii: "\n")) {
        remainder = bytes[bytes.index(after: lastNewline)...]
        bytes = bytes[..<lastNewline]
      } else {
        // A "line" this long is no log line Hearthstone writes; drop it rather than grow without end.
        remainder = bytes.count > 64 * 1024 ? Data() : bytes
        return []
      }
      return String(decoding: bytes, as: UTF8.self).split(whereSeparator: \.isNewline)
    }
  }
}
