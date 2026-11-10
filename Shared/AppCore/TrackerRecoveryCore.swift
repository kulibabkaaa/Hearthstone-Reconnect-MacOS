import Foundation

/// Helping HSTracker pick a match back up after a reconnect.
///
/// When Hearthstone reconnects it reloads the gameplay scene. HSTracker (seen on 3.6.1–3.7.3) answers that by
/// forgetting who the player is and what kind of match it is, and only its game-start routine fills those in again.
/// That routine runs on a menu → gameplay scene line, which a reconnect never writes. So after a reconnect the app
/// appends one such line to Hearthstone's `LoadingScreen.log`, which HSTracker is already reading.
///
/// Everything here is pure: the app feeds it what the two log files hold and does what it answers.
public enum TrackerRecovery {
  public static let trackerBundleIdentifier = "net.hearthsim.hstracker"
  public static let trackerName = "HSTracker"
}

// MARK: - What Hearthstone has written since the reconnect

/// How far Hearthstone's scene reload has got, read from the `LoadingScreen.log` text written since the reconnect.
public struct LoadingScreenProgress: Equatable, Sendable {
  /// `Gameplay.Start()`: the line HSTracker answers by resetting its game state.
  public var gameplayStarted = false
  /// `MulliganManager.HandleGameStart()`: HSTracker's own reconnect handling starts here, so the line must reach it.
  public var handledGameStart = false
  /// `OnSceneLoaded() - prevMode=GAMEPLAY currMode=GAMEPLAY`: the reload finished. About a second of silence follows.
  public var sceneReloaded = false
  /// Any scene other than gameplay: the match is over, so there is nothing to recover.
  public var leftMatch = false

  public init() {}

  public static func scan(_ text: String) -> LoadingScreenProgress {
    var progress = LoadingScreenProgress()
    // A line still being written has no newline yet; it is read on the next look.
    let complete = text.lastIndex(of: "\n").map { text[...$0] } ?? Substring()
    for line in complete.split(separator: "\n", omittingEmptySubsequences: true) {
      if line.contains("Gameplay.Start()") { progress.gameplayStarted = true }
      if line.contains("MulliganManager.HandleGameStart()") { progress.handledGameStart = true }
      if line.contains("prevMode=GAMEPLAY currMode=GAMEPLAY") { progress.sceneReloaded = true }
      for key in ["currMode=", "nextMode="] {
        if let mode = value(after: key, in: line), mode != "GAMEPLAY" { progress.leftMatch = true }
      }
    }
    return progress
  }

  private static func value(after key: String, in line: Substring) -> Substring? {
    guard let range = line.range(of: key) else { return nil }
    let value = line[range.upperBound...].prefix { $0.isLetter || $0 == "_" }
    return value.isEmpty ? nil : value
  }
}

// MARK: - What HSTracker has logged since the reconnect

/// What HSTracker's own log says since the reconnect. This is how the app tells a tracker that is stuck from one
/// that has already recovered by itself, and how it confirms that its line was read.
public struct TrackerLogSignals: Equatable, Sendable {
  /// How often HSTracker's game-start routine ran (`----- Game Started -----`).
  public var gameStarts = 0
  /// HSTracker read the players again (`[PlayerId=`): it knows whose match this is.
  public var identityRestored = false

  public init() {}

  public static func scan(_ text: String) -> TrackerLogSignals {
    var signals = TrackerLogSignals()
    var rest = Substring(text)
    while let range = rest.range(of: "----- Game Started -----") {
      signals.gameStarts += 1
      rest = rest[range.upperBound...]
    }
    signals.identityRestored = text.contains("[PlayerId=")
    return signals
  }

  /// A tracker that restarted its game routine or re-read the players without help needs none.
  public var recoveredUnaided: Bool { gameStarts > 0 || identityRestored }
}

// MARK: - The line

public enum TrackerNudgeLine {
  /// The length of Hearthstone's own `OnSceneLoaded() - prevMode=GAMEPLAY currMode=GAMEPLAY` line, newline included.
  /// Hearthstone does not append to its logs; it writes at its own position, so its next line lands on top of ours.
  /// After a reconnect that next line is the 87-byte one above. With ours the same length, the tracker's read
  /// position ends exactly where Hearthstone's line ends, and the only thing it misses is that gameplay → gameplay
  /// notice, which it does nothing with.
  public static let byteCount = 87

  /// How far behind "now" the line is stamped.
  public static let stampLag: TimeInterval = 0.05

  /// One menu → gameplay scene line, stamped just behind "now".
  ///
  /// Two rules in HSTracker decide the stamp. It reads a time later than its own clock as yesterday's and drops the
  /// line; it compares whole seconds for that, and the whole second of a moment in the past is never ahead. And it
  /// sorts the lines it picks up together by time, so a stamp a full second back could put our line in front of
  /// the reconnect's own `Gameplay.Start` or game-state dump. So: 50 ms back, with the real fraction.
  public static func make(now: Date, timeZone: TimeZone = .autoupdatingCurrent) -> String {
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = timeZone
    let moment = now.addingTimeInterval(-stampLag)
    let parts = calendar.dateComponents([.hour, .minute, .second], from: moment)
    let seconds = moment.timeIntervalSince1970
    let fraction = min(9_999_999, max(0, Int(((seconds - seconds.rounded(.down)) * 10_000_000).rounded(.down))))
    let stamp = String(
      format: "%02d:%02d:%02d.%07d", parts.hour ?? 0, parts.minute ?? 0, parts.second ?? 0, fraction)
    return "D \(stamp) LoadingScreen.OnSceneLoaded() - prevMode=BACON    currMode=GAMEPLAY\n"
  }
}

// MARK: - One reconnect

public struct TrackerRecoveryTiming: Equatable, Sendable {
  /// Give up when Hearthstone hasn't reloaded the scene by then: it wasn't in a match, or the reconnect didn't land.
  public var reloadDeadline: TimeInterval = 6
  /// Silence wanted after `HandleGameStart`. Past hero selection one short line follows it within ~110 ms, then
  /// about a second of nothing. During hero selection the gaps are shorter (40/160/8/75 ms), so the line can be
  /// written over before HSTracker reads it; that is what the confirmation and the retries are for.
  public var quietAfterGameStart: TimeInterval = 0.10
  /// The patient way, for an HSTracker build not known to need help: how long after the reload line it gets to
  /// recover by itself before anything is written.
  public var patientGrace: TimeInterval = 0.6
  /// Silence wanted after the reload line, which is written together with two more.
  public var quietAfterSceneReload: TimeInterval = 0.06
  /// Longest wait for silence before writing regardless.
  public var maximumSettle: TimeInterval = 0.6
  /// How long HSTracker gets to show that it read the line before the next try.
  public var verifyWindow: TimeInterval = 0.4
  /// Tries during the reload before falling back to the slow way.
  public var fastAttempts = 3
  /// The slow way, as first proven live: wait until Hearthstone has written nothing for this long.
  public var slowQuiet: TimeInterval = 1
  public var slowDeadline: TimeInterval = 10
  public var slowVerifyWindow: TimeInterval = 2
  /// HSTracker ignores a second game start within 5 s of the last, so a line sooner than that would be wasted.
  public var minimumGapAfterRecovery: TimeInterval = 5.3

  public init() {}
}

public enum TrackerRecoveryOutcome: Equatable, Sendable {
  /// HSTracker restarted its game routine after our line.
  case recovered(after: TimeInterval, attempts: Int)
  /// HSTracker recovered before anything was written: nothing was added. This is the fixed-tracker case.
  case recoveredUnaided
  /// Hearthstone never reloaded the scene.
  case noReload
  /// The match ended first.
  case leftMatch
  /// Lines were written and HSTracker never showed that it read one.
  case noResponse(attempts: Int)
  /// One line was written and nothing confirmed it: HSTracker's log couldn't be read, or this is a build whose
  /// log has stopped confirming.
  case unverified
  /// The line couldn't be written.
  case writeFailed

  /// Whether a line was added to Hearthstone's log.
  public var didWrite: Bool {
    switch self {
    case .recovered, .noResponse, .unverified: true
    case .recoveredUnaided, .noReload, .leftMatch, .writeFailed: false
    }
  }
}

/// What the two logs hold right now. Both texts are only what was written since the reconnect.
public struct TrackerRecoveryObservation: Sendable {
  public var now: TimeInterval
  public var loadingText: String
  public var loadingSize: UInt64
  /// When the loading log was last written to. Hearthstone writing over our line changes this but not the size,
  /// so both are watched to tell whether the log has gone quiet.
  public var loadingModified: TimeInterval
  /// nil when HSTracker's log can't be read.
  public var trackerText: String?

  public init(
    now: TimeInterval, loadingText: String, loadingSize: UInt64, loadingModified: TimeInterval = 0,
    trackerText: String?
  ) {
    self.now = now
    self.loadingText = loadingText
    self.loadingSize = loadingSize
    self.loadingModified = loadingModified
    self.trackerText = trackerText
  }
}

public enum TrackerRecoveryStep: Equatable, Sendable {
  case wait
  /// Append `TrackerNudgeLine.make(now:)` now, then call `didWrite`.
  case write
  case finish(TrackerRecoveryOutcome)
}

/// The recovery for one reconnect: when to write, whether it worked, when to try again and when to stop.
public struct TrackerRecoverySession: Sendable {
  private enum Phase: Equatable, Sendable {
    case awaitingReload
    case settling(since: TimeInterval, quiet: TimeInterval, earliest: TimeInterval)
    case verifying(since: TimeInterval, window: TimeInterval)
    case slowSettling(since: TimeInterval)
    case finished(TrackerRecoveryOutcome)
  }

  public let startedAt: TimeInterval
  public let timing: TrackerRecoveryTiming
  /// One line and no retries: for a tracker build whose log has stopped confirming (see `TrackerRecoveryHealth`).
  public let singleShot: Bool
  /// Wait for Hearthstone's own reload line and give HSTracker time to recover by itself before writing. For a
  /// build not known to need help: writing early would get in ahead of a fix and hide it.
  public let patient: Bool
  /// When HSTracker last restarted its game routine because of an earlier reconnect's line.
  private let lastRecoveryAt: TimeInterval?
  private var phase = Phase.awaitingReload
  public private(set) var writes = 0
  private var usedSlowAttempt = false
  private var awaitingWriteResult = false
  private var gameStartsBeforeWrite = 0
  private var lastSize: UInt64?
  private var lastModified: TimeInterval?
  /// When the loading log last changed, by size or by write time.
  private var lastGrowthAt: TimeInterval

  public init(
    startedAt: TimeInterval,
    lastRecoveryAt: TimeInterval? = nil,
    singleShot: Bool = false,
    patient: Bool = false,
    timing: TrackerRecoveryTiming = .init()
  ) {
    self.startedAt = startedAt
    self.lastRecoveryAt = lastRecoveryAt
    self.singleShot = singleShot
    self.patient = patient
    self.timing = timing
    lastGrowthAt = startedAt
  }

  public var outcome: TrackerRecoveryOutcome? {
    if case .finished(let outcome) = phase { return outcome }
    return nil
  }

  public mutating func advance(_ observation: TrackerRecoveryObservation) -> TrackerRecoveryStep {
    if case .finished(let outcome) = phase { return .finish(outcome) }
    // The app owes `didWrite` for the last `.write` before anything else can be decided.
    if awaitingWriteResult { return .wait }
    let now = observation.now
    let progress = LoadingScreenProgress.scan(observation.loadingText)
    let signals = observation.trackerText.map(TrackerLogSignals.scan)
    if observation.loadingSize != lastSize || observation.loadingModified != lastModified {
      lastSize = observation.loadingSize
      lastModified = observation.loadingModified
      lastGrowthAt = now
    }
    let quietFor = now - lastGrowthAt

    if writes > 0, let signals, signals.gameStarts > gameStartsBeforeWrite {
      return finish(.recovered(after: now - startedAt, attempts: writes))
    }
    if writes == 0, let signals, signals.recoveredUnaided { return finish(.recoveredUnaided) }
    // A match that ends after a line went in says nothing about whether HSTracker reads our lines.
    if progress.leftMatch { return finish(writes > 0 ? .unverified : .leftMatch) }

    switch phase {
    case .awaitingReload:
      // Never on `Gameplay.Start()` alone: a line written before `HandleGameStart` would be overwritten by it,
      // and HSTracker would then miss the line its own reconnect handling starts from.
      if progress.sceneReloaded {
        let earliest = patient ? now + timing.patientGrace : now
        phase = .settling(since: earliest, quiet: timing.quietAfterSceneReload, earliest: earliest)
      } else if progress.handledGameStart, !patient {
        phase = .settling(since: now, quiet: timing.quietAfterGameStart, earliest: now)
      } else if now - startedAt >= timing.reloadDeadline {
        return finish(.noReload)
      }
      return .wait

    case .settling(let since, var quiet, let earliest):
      // Once the reload line is there, the long silence after it is the better slot and needs less waiting.
      if progress.sceneReloaded, quiet > timing.quietAfterSceneReload {
        quiet = timing.quietAfterSceneReload
        phase = .settling(since: since, quiet: quiet, earliest: earliest)
      }
      guard now >= earliest, quietFor >= quiet || now - since >= timing.maximumSettle else { return .wait }
      return write(signals: signals, now: now)

    case .verifying(let since, let window):
      // Without HSTracker's log there is no way to tell whether it read the line; one line is all it gets.
      guard signals != nil else { return finish(.unverified) }
      guard now - since >= window else { return .wait }
      if singleShot { return finish(.unverified) }
      if writes < timing.fastAttempts {
        phase = .settling(since: now, quiet: timing.quietAfterGameStart, earliest: now)
      } else if !usedSlowAttempt {
        phase = .slowSettling(since: now)
      } else {
        return finish(.noResponse(attempts: writes))
      }
      return .wait

    case .slowSettling(let since):
      guard quietFor >= timing.slowQuiet || now - since >= timing.slowDeadline else { return .wait }
      usedSlowAttempt = true
      return write(signals: signals, now: now)

    case .finished(let outcome):
      return .finish(outcome)
    }
  }

  /// Report how the write for the last `.write` step went.
  public mutating func didWrite(at now: TimeInterval, succeeded: Bool) {
    guard awaitingWriteResult else { return }
    awaitingWriteResult = false
    guard succeeded else {
      phase = .finished(.writeFailed)
      return
    }
    writes += 1
    // A single shot or the slow last try gets the long window; there is nothing after it to hurry to.
    phase = .verifying(
      since: now, window: usedSlowAttempt || singleShot ? timing.slowVerifyWindow : timing.verifyWindow)
  }

  /// The app chose not to write for the last `.write` step (the log didn't end on a line break, so appending
  /// would have glued our line onto a half-written one). The session decides again on the next look.
  public mutating func writePostponed() {
    awaitingWriteResult = false
  }

  private mutating func write(signals: TrackerLogSignals?, now: TimeInterval) -> TrackerRecoveryStep {
    if let last = lastRecoveryAt, now - last < timing.minimumGapAfterRecovery { return .wait }
    gameStartsBeforeWrite = signals?.gameStarts ?? 0
    awaitingWriteResult = true
    return .write
  }

  private mutating func finish(_ outcome: TrackerRecoveryOutcome) -> TrackerRecoveryStep {
    phase = .finished(outcome)
    return .finish(outcome)
  }
}

// MARK: - Across reconnects

/// What to do about an HSTracker build whose log never confirms the line. That can mean HSTracker ignores it, or
/// only that a new build words its log differently while still acting on it. So the app doesn't stop: it stops
/// retrying, and writes one line per reconnect for that build. A confirmation, a different build, or switching the
/// option off and on brings the retries back.
///
/// It also decides who gets the fast way. Builds up to `lastKnownBrokenBuild` are known to need help. A newer build
/// might carry HSTracker's own fix, so its first reconnect is handled patiently: if HSTracker recovers by itself
/// nothing is ever written for it, and if it needed our line after all, that build gets the fast way from then on.
public struct TrackerRecoveryHealth: Equatable, Sendable {
  public static let singleShotAfter = 3
  /// HSTracker 3.7.3. Seen needing help on 3.6.1 (3558) through 3.7.3 (4000).
  public static let lastKnownBrokenBuild = 4000
  public private(set) var consecutiveNoResponse = 0
  public private(set) var singleShotTrackerBuild: String?
  /// A build newer than `lastKnownBrokenBuild` that was given time to recover by itself and didn't.
  public private(set) var confirmedBrokenBuild: String?

  public init(singleShotTrackerBuild: String? = nil, confirmedBrokenBuild: String? = nil) {
    self.singleShotTrackerBuild = singleShotTrackerBuild
    self.confirmedBrokenBuild = confirmedBrokenBuild
  }

  public func usesPatientPath(trackerBuild: String) -> Bool {
    if let number = Int(trackerBuild), number <= Self.lastKnownBrokenBuild { return false }
    return confirmedBrokenBuild != trackerBuild
  }

  public func usesSingleShot(trackerBuild: String) -> Bool {
    singleShotTrackerBuild == trackerBuild
  }

  public mutating func record(_ outcome: TrackerRecoveryOutcome, trackerBuild: String) {
    if let build = singleShotTrackerBuild, build != trackerBuild {
      singleShotTrackerBuild = nil
      consecutiveNoResponse = 0
    }
    if let build = confirmedBrokenBuild, build != trackerBuild { confirmedBrokenBuild = nil }
    switch outcome {
    case .noResponse:
      consecutiveNoResponse += 1
      if consecutiveNoResponse >= Self.singleShotAfter { singleShotTrackerBuild = trackerBuild }
    case .recovered:
      consecutiveNoResponse = 0
      singleShotTrackerBuild = nil
      // It needed our line: no reason to keep it waiting next time.
      if usesPatientPath(trackerBuild: trackerBuild) { confirmedBrokenBuild = trackerBuild }
    case .recoveredUnaided:
      consecutiveNoResponse = 0
      singleShotTrackerBuild = nil
      confirmedBrokenBuild = nil
    case .noReload, .leftMatch, .unverified, .writeFailed:
      break
    }
  }

  public mutating func reset() {
    consecutiveNoResponse = 0
    singleShotTrackerBuild = nil
    confirmedBrokenBuild = nil
  }
}

// MARK: - What the main window says

public enum TrackerRecoveryStatus: Equatable, Sendable {
  case off
  case trackerNotRunning
  case ready
  case working
  case recovered(seconds: TimeInterval)
  case recoveredUnaided
  case noResponse
  case unverified
  case writeFailed

  /// The line under the switch; nil hides it.
  public var text: String? {
    switch self {
    case .off: nil
    case .trackerNotRunning: "\(TrackerRecovery.trackerName) isn't running."
    case .ready: "Ready for your next reconnect."
    case .working: "Bringing \(TrackerRecovery.trackerName) back…"
    case .recovered(let seconds):
      "Last reconnect: \(TrackerRecovery.trackerName) was back in \(Self.format(seconds)) s."
    case .recoveredUnaided:
      "\(TrackerRecovery.trackerName) handled the last reconnect itself. Nothing was added."
    case .noResponse: "\(TrackerRecovery.trackerName) didn't respond after the last reconnect."
    case .unverified: "Line added, but \(TrackerRecovery.trackerName) didn't confirm it."
    case .writeFailed: "Couldn't write to Hearthstone's log."
    }
  }

  public var isProblem: Bool {
    switch self {
    case .noResponse, .writeFailed: true
    default: false
    }
  }

  /// What to show once a reconnect's recovery ends.
  public static func after(_ outcome: TrackerRecoveryOutcome) -> TrackerRecoveryStatus {
    switch outcome {
    case .recovered(let seconds, _): return .recovered(seconds: seconds)
    case .recoveredUnaided: return .recoveredUnaided
    case .noResponse: return .noResponse
    case .unverified: return .unverified
    case .writeFailed: return .writeFailed
    case .noReload, .leftMatch: return .ready
    }
  }

  private static func format(_ seconds: TimeInterval) -> String {
    guard seconds.isFinite else { return "0.0" }
    return String(format: "%.1f", min(max(seconds, 0), 99.9))
  }
}
