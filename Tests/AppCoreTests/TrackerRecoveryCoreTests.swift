import Foundation
import Testing
@testable import AppCore

// Real lines, as Hearthstone and HSTracker 3.7.x wrote them during reconnects on 29 Oct and 9 Nov 2026.
private enum Sample {
  static let unload = """
    D 13:58:54.5176040 LoadingScreen.OnScenePreUnload() - prevMode=GAMEPLAY nextMode=GAMEPLAY m_phase=INVALID
    D 13:58:54.5176040 Gameplay.Unload()
    D 13:58:54.5176040 Gameplay.OnDestroy()

    """
  static let start = """
    D 13:58:54.5587700 Gameplay.Awake()
    D 13:58:54.5587700 Gameplay.Start()

    """
  static let handleGameStart = """
    D 13:58:54.8758940 Gameplay.OnPowerHistory() - powerList=49
    D 13:58:54.8758940 MulliganManager.HandleGameStart() - IsPastBeginPhase()=True

    """
  static let heroPick = """
    D 13:58:18.0431230 MulliganManager.HandleGameStart() - IsPastBeginPhase()=False
    D 13:58:18.0431230 MulliganManager.HandleGameStart() - IsMulliganPhase()=True

    """
  static let options = "D 13:58:54.9246650 Gameplay.OnAllOptions() - id=1\n"
  static let sceneReloaded = "D 13:58:56.0597940 LoadingScreen.OnSceneLoaded() - prevMode=GAMEPLAY currMode=GAMEPLAY\n"
  static let backToMenu = "D 13:59:45.0854610 LoadingScreen.OnSceneLoaded() - prevMode=GAMEPLAY currMode=BACON\n"
  static let leaving = "D 13:59:43.3699140 LoadingScreen.OnScenePreUnload() - prevMode=GAMEPLAY nextMode=BACON m_phase=INVALID\n"

  static let trackerStuck = """
    23:47:53.185 VERBOSE Game.reset():1721 - Reseting Game
    23:47:53.458 INFO Game.handleGameReconnect():2143 - Joined after mulligan, assuming reconnect.
    23:47:54.680 INFO LoadingScreenHandler.handle():47 - Game mode from gameplay to gameplay

    """
  static let trackerGameStarted = """
    23:48:53.176 INFO LoadingScreenHandler.handle():47 - Game mode from bacon to gameplay
    23:48:53.211 INFO Game.gameStart():2042 - ----- Game Started -----

    """
  static let trackerPlayers = "23:48:53.208 INFO Game.updatePlayers():1997 - someone#1234 [PlayerId=5] vs Boss [PlayerId=13]\n"
}

@Suite("Tracker recovery: reading Hearthstone's loading log")
struct LoadingScreenProgressTests {
  @Test("follows a reconnect's reload step by step")
  func stages() {
    var text = Sample.unload
    #expect(LoadingScreenProgress.scan(text) == LoadingScreenProgress())
    text += Sample.start
    #expect(LoadingScreenProgress.scan(text).gameplayStarted)
    #expect(!LoadingScreenProgress.scan(text).handledGameStart)
    text += Sample.handleGameStart
    #expect(LoadingScreenProgress.scan(text).handledGameStart)
    #expect(!LoadingScreenProgress.scan(text).sceneReloaded)
    text += Sample.options + Sample.sceneReloaded
    let done = LoadingScreenProgress.scan(text)
    #expect(done.gameplayStarted && done.handledGameStart && done.sceneReloaded && !done.leftMatch)
  }

  @Test("a reconnect during hero selection counts too")
  func heroPick() {
    #expect(LoadingScreenProgress.scan(Sample.start + Sample.heroPick).handledGameStart)
  }

  @Test("a line still being written is not read yet")
  func partialLine() {
    let partial = "D 13:58:54.8758940 MulliganManager.HandleGameStart() - IsPastBeginPh"
    #expect(!LoadingScreenProgress.scan(Sample.start + partial).handledGameStart)
    #expect(LoadingScreenProgress.scan(Sample.start + partial).gameplayStarted)
    #expect(LoadingScreenProgress.scan(partial) == LoadingScreenProgress())
    #expect(LoadingScreenProgress.scan("") == LoadingScreenProgress())
  }

  @Test("leaving the match is noticed, on the way out or once out")
  func leftMatch() {
    #expect(LoadingScreenProgress.scan(Sample.leaving).leftMatch)
    #expect(LoadingScreenProgress.scan(Sample.backToMenu).leftMatch)
    #expect(!LoadingScreenProgress.scan(Sample.unload + Sample.sceneReloaded).leftMatch)
  }

  @Test("our own line is neither a reload nor a way out of the match")
  func ownLine() {
    let own = LoadingScreenProgress.scan(TrackerNudgeLine.make(now: Date(timeIntervalSince1970: 1_800_000_000)))
    #expect(own == LoadingScreenProgress())
  }
}

@Suite("Tracker recovery: reading HSTracker's log")
struct TrackerLogSignalsTests {
  @Test("a stuck tracker shows no game start and no players")
  func stuck() {
    let signals = TrackerLogSignals.scan(Sample.trackerStuck)
    #expect(signals.gameStarts == 0 && !signals.identityRestored && !signals.recoveredUnaided)
  }

  @Test("game starts are counted; re-read players are seen")
  func recovered() {
    #expect(TrackerLogSignals.scan(Sample.trackerStuck + Sample.trackerGameStarted).gameStarts == 1)
    #expect(TrackerLogSignals.scan(Sample.trackerGameStarted + Sample.trackerGameStarted).gameStarts == 2)
    #expect(TrackerLogSignals.scan(Sample.trackerPlayers).identityRestored)
    #expect(TrackerLogSignals.scan(Sample.trackerPlayers).recoveredUnaided)
    #expect(TrackerLogSignals.scan("") == TrackerLogSignals())
  }
}

@Suite("Tracker recovery: the line")
struct TrackerNudgeLineTests {
  let utc = TimeZone(identifier: "UTC")!

  @Test("is exactly as long as the line Hearthstone writes over it")
  func length() {
    let line = TrackerNudgeLine.make(now: Date(timeIntervalSince1970: 1_800_000_000), timeZone: utc)
    #expect(line.utf8.count == TrackerNudgeLine.byteCount)
    #expect(Sample.sceneReloaded.utf8.count == TrackerNudgeLine.byteCount)
    #expect(line.hasSuffix("\n") && line.filter { $0 == "\n" }.count == 1)
  }

  @Test("is stamped 50 ms in the past with its real fraction, in the given time zone")
  func stamp() {
    // 2027-01-15 08:00:00.5 UTC.
    let now = Date(timeIntervalSince1970: 1_800_000_000.5)
    #expect(TrackerNudgeLine.make(now: now, timeZone: utc).hasPrefix("D 08:00:00.4"))
    let plusTwo = TimeZone(secondsFromGMT: 7200)!
    #expect(TrackerNudgeLine.make(now: now, timeZone: plusTwo).hasPrefix("D 10:00:00.4"))
    // Just past midnight the stamp is still the day before's last second, never a time still to come.
    let midnight = Date(timeIntervalSince1970: 1_800_000_000 + 16 * 3600 + 0.02)
    #expect(TrackerNudgeLine.make(now: midnight, timeZone: utc).hasPrefix("D 23:59:59.9"))
  }

  @Test("the stamp is always seven digits after the point and never ahead of now", arguments: [
    0.0, 0.049, 0.05, 0.051, 0.5, 0.9999999, 1.0, 59.96, 3599.999,
  ])
  func stampShape(offset: Double) {
    let now = Date(timeIntervalSince1970: 1_800_000_000 + offset)
    let line = TrackerNudgeLine.make(now: now, timeZone: utc)
    #expect(line.utf8.count == TrackerNudgeLine.byteCount)
    guard let match = line.firstMatch(of: #/^D (\d\d):(\d\d):(\d\d)\.(\d{7}) /#) else {
      Issue.record("unexpected stamp in \(line)")
      return
    }
    // HSTracker compares the whole second with its clock: that second must not be later than now.
    let secondsOfDay = Int(match.1)! * 3600 + Int(match.2)! * 60 + Int(match.3)!
    let nowOfDay = Int((now.timeIntervalSince1970).rounded(.down)) % 86_400
    #expect(secondsOfDay <= nowOfDay || secondsOfDay - nowOfDay > 80_000)
    // And it sorts within a tenth of a second of now, after the lines Hearthstone wrote for this reconnect.
    let stamped = Double(secondsOfDay) + Double(Int(match.4)!) / 10_000_000
    let exact = now.timeIntervalSince1970.truncatingRemainder(dividingBy: 86_400)
    let behind = (exact - stamped + 86_400).truncatingRemainder(dividingBy: 86_400)
    #expect(behind > 0.04 && behind < 0.06)
  }

  @Test("passes everything HSTracker checks before acting on a scene line")
  func acceptedByTracker() {
    let line = String(TrackerNudgeLine.make(now: Date(), timeZone: utc).dropLast())
    // LogReader: the "D " prefix and more than 20 characters.
    #expect(line.hasPrefix("D ") && line.count > 20)
    // LogLine: the content is everything after the second space; the reader keeps lines whose content starts with
    // one of its filters.
    let content = line.split(separator: " ", maxSplits: 2, omittingEmptySubsequences: false).last.map(String.init) ?? ""
    #expect(content.hasPrefix("LoadingScreen.OnSceneLoaded"))
    // LoadingScreenHandler: prevMode=(\w+).*currMode=(\w+), and a game start needs "not gameplay" → "gameplay".
    let match = line.firstMatch(of: /prevMode=(\w+).*currMode=(\w+)/)
    #expect(match?.1 == "BACON" && match?.2 == "GAMEPLAY")
    #expect(!line.dropFirst(2).contains("D "))
  }
}

/// HSTracker's log reader (LogReader.readFile, 3.7.1) and Hearthstone's writer, reduced to what matters here:
/// Hearthstone writes at its own position rather than appending, and the reader only moves on past lines it keeps.
private struct LogFileModel {
  var bytes: [UInt8] = []
  var hearthstonePosition = 0
  var trackerOffset = 0
  var trackerSaw: [String] = []

  mutating func hearthstoneWrites(_ line: String) {
    let data = Array(line.utf8)
    let end = hearthstonePosition + data.count
    if bytes.count < end { bytes += [UInt8](repeating: 0, count: end - bytes.count) }
    bytes.replaceSubrange(hearthstonePosition..<end, with: data)
    hearthstonePosition = end
  }

  mutating func appAppends(_ line: String) { bytes += Array(line.utf8) }

  mutating func trackerReads() {
    let text = String(decoding: bytes[trackerOffset...], as: UTF8.self)
    for line in text.components(separatedBy: .newlines)
    where !line.isEmpty && line.hasPrefix("D ") && line.count > 20 {
      trackerOffset += line.utf8.count + 1
      trackerSaw.append(line)
    }
  }
}

@Suite("Tracker recovery: how the line sits in a file Hearthstone writes over")
struct TrackerNudgeFileTests {
  let nudge = TrackerNudgeLine.make(now: Date(timeIntervalSince1970: 1_800_000_000), timeZone: TimeZone(identifier: "UTC")!)
  let fadeOut = "D 13:58:56.0597940 LoadingScreen.FadeOut()\n"
  let fadeDone = "D 13:58:57.0761020 LoadingScreen.OnFadeOutComplete()\n"

  private func reloadedUpToTheQuietSlot() -> LogFileModel {
    var file = LogFileModel()
    for line in (Sample.start + Sample.handleGameStart + Sample.options).split(separator: "\n") {
      file.hearthstoneWrites(line + "\n")
    }
    file.trackerReads()
    return file
  }

  @Test("read in the quiet slot: the tracker gets it, and stays exactly in step afterwards")
  func alignedAfterTheReloadLine() {
    var file = reloadedUpToTheQuietSlot()
    file.appAppends(nudge)
    file.trackerReads()
    #expect(file.trackerSaw.last == String(nudge.dropLast()))
    // Hearthstone's next write lands on top of our line. It is the same length, so nothing is left over.
    file.hearthstoneWrites(Sample.sceneReloaded)
    file.trackerReads()
    #expect(file.trackerOffset == file.hearthstonePosition)
    #expect(file.trackerSaw.last == String(nudge.dropLast()))
    // Everything after that is read normally: no lost and no repeated lines.
    file.hearthstoneWrites(fadeOut)
    file.hearthstoneWrites(fadeDone)
    file.trackerReads()
    #expect(file.trackerOffset == file.hearthstonePosition)
    #expect(Array(file.trackerSaw.suffix(2)) == [String(fadeOut.dropLast()), String(fadeDone.dropLast())])
    #expect(String(decoding: file.bytes, as: UTF8.self).contains("prevMode=BACON") == false)
  }

  @Test("overwritten before the tracker looks: nothing is read twice or lost, and a retry still works")
  func overwrittenFirst() {
    var file = reloadedUpToTheQuietSlot()
    file.appAppends(nudge)
    // A short Hearthstone line gets there first and leaves the tail of ours behind it.
    file.hearthstoneWrites(Sample.options)
    file.trackerReads()
    #expect(file.trackerSaw.last == String(Sample.options.dropLast()))
    #expect(file.trackerOffset == file.hearthstonePosition)
    #expect(!file.trackerSaw.contains { $0.contains("prevMode=BACON") })
    // Hearthstone keeps writing over the leftover; the tracker reads every line once.
    file.hearthstoneWrites(Sample.sceneReloaded)
    file.trackerReads()
    #expect(file.trackerSaw.last == String(Sample.sceneReloaded.dropLast()))
    #expect(file.trackerOffset == file.hearthstonePosition)
    file.appAppends(nudge)
    file.trackerReads()
    #expect(file.trackerSaw.last == String(nudge.dropLast()))
  }

  @Test("followed by a shorter line instead: the tracker misses a line or two, then settles")
  func followedByShorterLines() {
    var file = reloadedUpToTheQuietSlot()
    file.appAppends(nudge)
    file.trackerReads()
    let afterwards = ["D 23:48:54.7024890 Gameplay.OnPowerHistory() - powerList=41\n",
      "D 23:48:54.7443990 Gameplay.OnAllOptions() - id=12\n",
      "D 23:48:55.7522240 Gameplay.OnPowerHistory() - powerList=46\n",
      Sample.backToMenu]
    for line in afterwards {
      file.hearthstoneWrites(line)
      file.trackerReads()
    }
    // The first line is under ours and the second is cut by it; from the third on every line arrives.
    let seenAfter = file.trackerSaw.drop { !$0.contains("prevMode=BACON") }.dropFirst()
    #expect(Array(seenAfter) == afterwards.suffix(2).map { String($0.dropLast()) })
    // It trails by less than the shortest line HSTracker acts on ("Gameplay.Start()", 36 bytes), so with these
    // lines nothing can be read twice. Other sequences can leave it a few bytes further back; a line read twice
    // then is one HSTracker ignores or handles the same way a second time.
    #expect(file.hearthstonePosition - file.trackerOffset < 36)
  }
}

@Suite("Tracker recovery: one reconnect")
struct TrackerRecoverySessionTests {
  let t0: TimeInterval = 10_000

  /// Feeds the session a timeline and plays the app's part: every `.write` is answered at once.
  private struct Run {
    var session: TrackerRecoverySession
    var loading = ""
    var tracker: String? = ""
    var writesAt: [TimeInterval] = []
    var writeSucceeds = true
    /// What HSTracker logs once it has read a line, and how long after the write it shows up.
    var trackerAnswers = true
    var answerDelay: TimeInterval = 0.05
    /// How many of our first lines Hearthstone writes over before HSTracker reads them.
    var lostWrites = 0
    private var pendingAnswerAt: TimeInterval?

    init(_ session: TrackerRecoverySession) { self.session = session }

    mutating func step(at now: TimeInterval) -> TrackerRecoveryStep {
      if let due = pendingAnswerAt, now >= due {
        tracker = (tracker ?? "") + Sample.trackerGameStarted
        pendingAnswerAt = nil
      }
      let step = session.advance(TrackerRecoveryObservation(
        now: now, loadingText: loading, loadingSize: UInt64(loading.utf8.count), trackerText: tracker))
      if step == .write {
        writesAt.append(now)
        session.didWrite(at: now, succeeded: writeSucceeds)
        if writeSucceeds, trackerAnswers, tracker != nil, pendingAnswerAt == nil, writesAt.count > lostWrites {
          pendingAnswerAt = now + answerDelay
        }
      }
      return step
    }

    /// Steps every 20 ms, as the app does, until the session finishes or `until` passes.
    mutating func run(from start: TimeInterval, until end: TimeInterval, events: [(TimeInterval, String)] = [])
      -> TrackerRecoveryOutcome?
    {
      var pending = events.sorted { $0.0 < $1.0 }
      var now = start
      while now <= end + 0.0001 {
        while let next = pending.first, next.0 <= now + 0.0001 {
          loading += next.1
          pending.removeFirst()
        }
        if case .finish(let outcome) = step(at: now) { return outcome }
        now += 0.02
      }
      return nil
    }
  }

  /// A reconnect past hero selection, timed as Hearthstone really writes it.
  private func reloadEvents(from t: TimeInterval) -> [(TimeInterval, String)] {
    [(t + 0.20, Sample.unload), (t + 0.26, Sample.start), (t + 0.55, Sample.handleGameStart),
      (t + 0.60, Sample.options), (t + 1.74, Sample.sceneReloaded)]
  }

  @Test("writes once in the silence after HandleGameStart and finishes when HSTracker answers")
  func fastPath() {
    var run = Run(TrackerRecoverySession(startedAt: t0))
    run.tracker = Sample.trackerStuck
    let outcome = run.run(from: t0, until: t0 + 5, events: reloadEvents(from: t0))
    #expect(run.writesAt.count == 1)
    // 0.60 s for the last line plus 0.10 s of silence: well inside the second before the reload line.
    let wroteAfter = (run.writesAt.first ?? 0) - t0
    #expect(wroteAfter > 0.69 && wroteAfter < 0.76)
    guard case .recovered(let after, let attempts) = outcome else {
      Issue.record("expected recovered, got \(String(describing: outcome))")
      return
    }
    #expect(attempts == 1 && after < 0.85)
  }

  @Test("never writes before HandleGameStart has reached HSTracker, however late it comes")
  func waitsForHandleGameStart() {
    var run = Run(TrackerRecoverySession(startedAt: t0))
    _ = run.run(from: t0, until: t0 + 0.54, events: reloadEvents(from: t0))
    #expect(run.writesAt.isEmpty)

    // Gameplay.Start and then nothing for seconds: a line now would be overwritten by HandleGameStart itself.
    var slow = Run(TrackerRecoverySession(startedAt: t0))
    #expect(slow.run(from: t0, until: t0 + 5.9, events: [(t0 + 0.26, Sample.start)]) == nil)
    #expect(slow.writesAt.isEmpty)
    // A late HandleGameStart is still picked up, and only then is the line written.
    let outcome = slow.run(from: t0 + 5.92, until: t0 + 5.99, events: [(t0 + 5.93, Sample.handleGameStart)])
    #expect(outcome == nil && slow.writesAt.isEmpty)
    var late = Run(TrackerRecoverySession(startedAt: t0))
    _ = late.run(from: t0, until: t0 + 5, events: [(t0 + 0.26, Sample.start), (t0 + 3.0, Sample.handleGameStart)])
    #expect(late.writesAt.count == 1 && (late.writesAt.first ?? 0) - t0 >= 3.1)
  }

  @Test("a tracker that recovered by itself gets nothing")
  func recoveredUnaided() {
    var run = Run(TrackerRecoverySession(startedAt: t0))
    run.tracker = Sample.trackerStuck + Sample.trackerGameStarted
    #expect(run.run(from: t0, until: t0 + 5, events: reloadEvents(from: t0)) == .recoveredUnaided)
    #expect(run.writesAt.isEmpty)

    var players = Run(TrackerRecoverySession(startedAt: t0))
    players.tracker = Sample.trackerPlayers
    #expect(players.run(from: t0, until: t0 + 5, events: reloadEvents(from: t0)) == .recoveredUnaided)
    #expect(players.writesAt.isEmpty)
  }

  @Test("tries again when HSTracker doesn't answer, then once more the slow way, then stops")
  func retriesThenGivesUp() {
    var run = Run(TrackerRecoverySession(startedAt: t0))
    run.trackerAnswers = false
    let outcome = run.run(from: t0, until: t0 + 30, events: reloadEvents(from: t0))
    #expect(outcome == .noResponse(attempts: 4))
    #expect(run.writesAt.count == 4)
    // Three quick tries about 0.4 s apart, then one after a full second of silence.
    let gaps = zip(run.writesAt.dropFirst(), run.writesAt).map { $0 - $1 }
    #expect(gaps.prefix(2).allSatisfy { $0 >= 0.4 && $0 < 0.6 })
    #expect((gaps.last ?? 0) >= 1.0)
  }

  @Test("when the first line is written over, the second one does it")
  func recoversOnRetry() {
    var run = Run(TrackerRecoverySession(startedAt: t0))
    run.lostWrites = 1
    let outcome = run.run(from: t0, until: t0 + 30, events: reloadEvents(from: t0))
    guard case .recovered(_, let attempts) = outcome else {
      Issue.record("expected recovered, got \(String(describing: outcome))")
      return
    }
    #expect(attempts == 2)
  }

  @Test("gives up quietly when Hearthstone never reloads the scene")
  func noReload() {
    var run = Run(TrackerRecoverySession(startedAt: t0))
    #expect(run.run(from: t0, until: t0 + 5.9) == nil)
    #expect(run.run(from: t0 + 5.92, until: t0 + 7) == .noReload)
    #expect(run.writesAt.isEmpty)
  }

  @Test("writes nothing once the match is over")
  func leftMatch() {
    var run = Run(TrackerRecoverySession(startedAt: t0))
    let outcome = run.run(from: t0, until: t0 + 5, events: [(t0 + 0.2, Sample.leaving), (t0 + 1.5, Sample.backToMenu)])
    #expect(outcome == .leftMatch)
    #expect(run.writesAt.isEmpty)
  }

  @Test("with no HandleGameStart at all it goes ahead on the reload line, or gives up")
  func fallbackTriggers() {
    var startOnly = Run(TrackerRecoverySession(startedAt: t0))
    #expect(startOnly.run(from: t0, until: t0 + 7, events: [(t0 + 0.26, Sample.start)]) == .noReload)
    #expect(startOnly.writesAt.isEmpty)

    var reloadOnly = Run(TrackerRecoverySession(startedAt: t0))
    _ = reloadOnly.run(from: t0, until: t0 + 5, events: [(t0 + 0.30, Sample.sceneReloaded)])
    let wroteAfterReload = (reloadOnly.writesAt.first ?? 0) - t0
    #expect(wroteAfterReload > 0.35 && wroteAfterReload < 0.46)
  }

  @Test("a match that ends after the line went in is unconfirmed, not a failure")
  func leftMatchAfterWriting() {
    var run = Run(TrackerRecoverySession(startedAt: t0))
    run.trackerAnswers = false
    let outcome = run.run(from: t0, until: t0 + 5, events: reloadEvents(from: t0) + [(t0 + 0.9, Sample.leaving)])
    #expect(outcome == .unverified)
    #expect(run.writesAt.count == 1 && run.session.writes == 1)
  }

  @Test("patient: waits for Hearthstone's reload line and gives HSTracker time before writing")
  func patientPath() {
    var run = Run(TrackerRecoverySession(startedAt: t0, patient: true))
    run.tracker = Sample.trackerStuck
    let outcome = run.run(from: t0, until: t0 + 6, events: reloadEvents(from: t0))
    // The reload line lands at 1.74 s; 0.6 s later the line goes in.
    let wrote = (run.writesAt.first ?? 0) - t0
    #expect(run.writesAt.count == 1 && wrote >= 2.34 && wrote < 2.45)
    guard case .recovered = outcome else {
      Issue.record("expected recovered, got \(String(describing: outcome))")
      return
    }
  }

  @Test("patient: a tracker that recovers by itself in that time gets nothing")
  func patientSeesTheFix() {
    var run = Run(TrackerRecoverySession(startedAt: t0, patient: true))
    run.tracker = Sample.trackerStuck
    var events = reloadEvents(from: t0)
    events.append((t0 + 2.0, ""))
    var now = t0
    var outcome: TrackerRecoveryOutcome?
    while now <= t0 + 6 && outcome == nil {
      // HSTracker's own fix answers the reload line 0.2 s after it.
      if now >= t0 + 1.94, run.tracker == Sample.trackerStuck { run.tracker = Sample.trackerStuck + Sample.trackerPlayers }
      outcome = run.run(from: now, until: now, events: events.filter { $0.0 > now - 0.02 && $0.0 <= now })
      now += 0.02
    }
    #expect(outcome == .recoveredUnaided)
    #expect(run.writesAt.isEmpty)
  }

  @Test("with HSTracker's log unreadable it writes one line and says it can't confirm")
  func unverified() {
    var run = Run(TrackerRecoverySession(startedAt: t0))
    run.tracker = nil
    #expect(run.run(from: t0, until: t0 + 10, events: reloadEvents(from: t0)) == .unverified)
    #expect(run.writesAt.count == 1)
  }

  @Test("single shot: one line, no retries, still notices an answer")
  func singleShot() {
    var silent = Run(TrackerRecoverySession(startedAt: t0, singleShot: true))
    silent.trackerAnswers = false
    #expect(silent.run(from: t0, until: t0 + 30, events: reloadEvents(from: t0)) == .unverified)
    #expect(silent.writesAt.count == 1)

    var answering = Run(TrackerRecoverySession(startedAt: t0, singleShot: true))
    answering.answerDelay = 1.2
    guard case .recovered(_, 1) = answering.run(from: t0, until: t0 + 30, events: reloadEvents(from: t0)) else {
      Issue.record("a single shot must still see HSTracker answer")
      return
    }
  }

  @Test("holds the line back until HSTracker would accept another game start")
  func minimumGap() {
    // The last recovery was 4.2 s before this reconnect: HSTracker ignores a game start within 5 s of it.
    var run = Run(TrackerRecoverySession(startedAt: t0, lastRecoveryAt: t0 - 4.2))
    _ = run.run(from: t0, until: t0 + 5, events: reloadEvents(from: t0))
    let wrote = (run.writesAt.first ?? 0) - t0
    #expect(wrote >= 1.1 && wrote < 1.2)

    var later = Run(TrackerRecoverySession(startedAt: t0, lastRecoveryAt: t0 - 60))
    _ = later.run(from: t0, until: t0 + 5, events: reloadEvents(from: t0))
    #expect(((later.writesAt.first ?? 0) - t0) < 0.76)
  }

  @Test("a failed write ends it; a pending write blocks every other decision")
  func writeResults() {
    var failing = Run(TrackerRecoverySession(startedAt: t0))
    failing.writeSucceeds = false
    #expect(failing.run(from: t0, until: t0 + 5, events: reloadEvents(from: t0)) == .writeFailed)

    var session = TrackerRecoverySession(startedAt: t0)
    let loading = Sample.start + Sample.handleGameStart
    func observe(_ now: TimeInterval) -> TrackerRecoveryObservation {
      TrackerRecoveryObservation(now: now, loadingText: loading, loadingSize: 200, trackerText: "")
    }
    #expect(session.advance(observe(t0)) == .wait)
    #expect(session.advance(observe(t0 + 0.2)) == .write)
    // Until the app reports the write, nothing else is decided, however long it takes.
    #expect(session.advance(observe(t0 + 0.3)) == .wait)
    #expect(session.advance(observe(t0 + 20)) == .wait)
    session.didWrite(at: t0 + 20, succeeded: true)
    #expect(session.advance(observe(t0 + 20.1)) == .wait)
    #expect(session.outcome == nil)
    // A second report for the same write changes nothing.
    session.didWrite(at: t0 + 21, succeeded: false)
    #expect(session.outcome == nil)
  }

  @Test("Hearthstone writing over our line is not silence, though the file doesn't grow")
  func overwriteIsActivity() {
    var session = TrackerRecoverySession(startedAt: t0)
    let loading = Sample.start + Sample.handleGameStart
    func observe(_ now: TimeInterval, modified: TimeInterval) -> TrackerRecoveryObservation {
      TrackerRecoveryObservation(
        now: now, loadingText: loading, loadingSize: 500, loadingModified: modified, trackerText: "")
    }
    #expect(session.advance(observe(t0, modified: 1)) == .wait)
    // Same size, but the file keeps being written: no write while that goes on.
    #expect(session.advance(observe(t0 + 0.08, modified: 2)) == .wait)
    #expect(session.advance(observe(t0 + 0.16, modified: 3)) == .wait)
    #expect(session.advance(observe(t0 + 0.24, modified: 4)) == .wait)
    // 100 ms after the last write to it, the slot is free.
    #expect(session.advance(observe(t0 + 0.30, modified: 4)) == .wait)
    #expect(session.advance(observe(t0 + 0.35, modified: 4)) == .write)
  }

  @Test("once finished it stays finished")
  func staysFinished() {
    var run = Run(TrackerRecoverySession(startedAt: t0))
    let outcome = run.run(from: t0, until: t0 + 5, events: reloadEvents(from: t0))
    #expect(run.session.outcome == outcome)
    #expect(run.step(at: t0 + 50) == .finish(outcome ?? .noReload))
    #expect(run.writesAt.count == 1)
  }
}

@Suite("Tracker recovery: across reconnects")
struct TrackerRecoveryHealthTests {
  @Test("three silent reconnects in a row switch that HSTracker build to single shots")
  func degrades() {
    var health = TrackerRecoveryHealth()
    health.record(.noResponse(attempts: 4), trackerBuild: "4000")
    health.record(.noResponse(attempts: 4), trackerBuild: "4000")
    #expect(!health.usesSingleShot(trackerBuild: "4000"))
    health.record(.noResponse(attempts: 4), trackerBuild: "4000")
    #expect(health.usesSingleShot(trackerBuild: "4000"))
    #expect(!health.usesSingleShot(trackerBuild: "4001"))
  }

  @Test("an answer, a new build or a reset brings the retries back")
  func recovers() {
    var health = TrackerRecoveryHealth(singleShotTrackerBuild: "4000")
    health.record(.unverified, trackerBuild: "4000")
    #expect(health.usesSingleShot(trackerBuild: "4000"))
    health.record(.recovered(after: 0.8, attempts: 1), trackerBuild: "4000")
    #expect(!health.usesSingleShot(trackerBuild: "4000"))

    health = TrackerRecoveryHealth(singleShotTrackerBuild: "4000")
    health.record(.noReload, trackerBuild: "4001")
    #expect(health.singleShotTrackerBuild == nil)

    health = TrackerRecoveryHealth(singleShotTrackerBuild: "4000")
    health.reset()
    #expect(health == TrackerRecoveryHealth())
  }

  @Test("builds known to need help get the fast way; newer ones are watched first")
  func patientBuilds() {
    var health = TrackerRecoveryHealth()
    #expect(!health.usesPatientPath(trackerBuild: "3558"))
    #expect(!health.usesPatientPath(trackerBuild: "4000"))
    #expect(health.usesPatientPath(trackerBuild: "4001"))
    #expect(health.usesPatientPath(trackerBuild: "unknown"))
    // It was given time and still needed our line: fast from now on.
    health.record(.recovered(after: 2.4, attempts: 1), trackerBuild: "4001")
    #expect(!health.usesPatientPath(trackerBuild: "4001"))
    #expect(health.confirmedBrokenBuild == "4001")
    // The next build is watched afresh.
    #expect(health.usesPatientPath(trackerBuild: "4002"))
    health.record(.noReload, trackerBuild: "4002")
    #expect(health.confirmedBrokenBuild == nil)
    // A build that recovers by itself is never marked, and a known-broken build is never recorded.
    health.record(.recoveredUnaided, trackerBuild: "4002")
    #expect(health.usesPatientPath(trackerBuild: "4002"))
    health.record(.recovered(after: 0.9, attempts: 1), trackerBuild: "4000")
    #expect(health.confirmedBrokenBuild == nil)
    #expect(TrackerRecoveryHealth(confirmedBrokenBuild: "4100").usesPatientPath(trackerBuild: "4100") == false)
  }

  @Test("an answer in between breaks the streak; reconnects that wrote nothing don't count")
  func streak() {
    var health = TrackerRecoveryHealth()
    health.record(.noResponse(attempts: 4), trackerBuild: "4000")
    health.record(.noResponse(attempts: 4), trackerBuild: "4000")
    health.record(.recoveredUnaided, trackerBuild: "4000")
    health.record(.noResponse(attempts: 4), trackerBuild: "4000")
    #expect(!health.usesSingleShot(trackerBuild: "4000"))
    health.record(.noReload, trackerBuild: "4000")
    health.record(.leftMatch, trackerBuild: "4000")
    health.record(.noResponse(attempts: 4), trackerBuild: "4000")
    #expect(!health.usesSingleShot(trackerBuild: "4000"))
    health.record(.noResponse(attempts: 4), trackerBuild: "4000")
    #expect(health.usesSingleShot(trackerBuild: "4000"))
  }
}

@Suite("Tracker recovery: status line")
struct TrackerRecoveryStatusTests {
  @Test("off shows nothing; every other state has a line")
  func texts() {
    #expect(TrackerRecoveryStatus.off.text == nil)
    let shown: [TrackerRecoveryStatus] = [.trackerNotRunning, .ready, .working, .recovered(seconds: 0.84),
      .recoveredUnaided, .noResponse, .unverified, .writeFailed]
    #expect(shown.allSatisfy { !($0.text ?? "").isEmpty })
    #expect(TrackerRecoveryStatus.recovered(seconds: 0.84).text == "Last reconnect: HSTracker was back in 0.8 s.")
    #expect(TrackerRecoveryStatus.recovered(seconds: .infinity).text?.contains("0.0 s") == true)
    #expect(TrackerRecoveryStatus.recovered(seconds: 4_000).text?.contains("99.9 s") == true)
    #expect(TrackerRecoveryStatus.noResponse.isProblem && !TrackerRecoveryStatus.ready.isProblem)
  }

  @Test("each outcome maps to what the user should read", arguments: [
    (TrackerRecoveryOutcome.recovered(after: 0.7, attempts: 1), TrackerRecoveryStatus.recovered(seconds: 0.7)),
    (.recoveredUnaided, .recoveredUnaided), (.noResponse(attempts: 4), .noResponse), (.unverified, .unverified),
    (.writeFailed, .writeFailed), (.noReload, .ready), (.leftMatch, .ready),
  ])
  func afterOutcome(_ outcome: TrackerRecoveryOutcome, _ status: TrackerRecoveryStatus) {
    #expect(TrackerRecoveryStatus.after(outcome) == status)
  }

  @Test("only outcomes that added a line say so")
  func didWrite() {
    #expect(TrackerRecoveryOutcome.recovered(after: 1, attempts: 1).didWrite)
    #expect(TrackerRecoveryOutcome.noResponse(attempts: 4).didWrite && TrackerRecoveryOutcome.unverified.didWrite)
    #expect(!TrackerRecoveryOutcome.recoveredUnaided.didWrite && !TrackerRecoveryOutcome.noReload.didWrite)
    #expect(!TrackerRecoveryOutcome.leftMatch.didWrite && !TrackerRecoveryOutcome.writeFailed.didWrite)
  }
}
