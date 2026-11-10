import Foundation
import Testing
@testable import AppCore

@Suite("Lobby info core")
struct LobbyInfoCoreTests {
  let now = Date(timeIntervalSince1970: 1_800_000_000)
  func player(_ position: Int, _ name: String, low: Int64? = nil) -> LobbyPlayer {
    LobbyPlayer(position: position, accountID: LobbyAccountID(high: 2, low: low ?? Int64(position)), name: name)
  }
  @Test("missing names use below-cutoff while collisions choose highest rating")
  func matching() {
    let snapshot = LeaderboardSnapshot(seasonID: 20, region: "EU", generatedAt: now,
      players: [LeaderboardPlayer(name: "ALICE#111", rating: 8100, rank: 9),
                LeaderboardPlayer(name: "alice", rating: 8200, rank: 5)])
    let rows = LobbyRatingResolver.resolve(players: [player(0, "Alice"), player(1, "Missing")],
      ownAccountID: nil, ownBattleTag: nil, ownRating: nil, snapshot: snapshot, now: now, region: "EU")
    #expect(rows[0].rating == .exact(8200)); #expect(rows[0].rank == 5)
    #expect(rows[1].rating == .belowCutoff(8000))
  }
  @Test("average requires seven ratings and keeps estimates stable by position")
  func average() {
    var estimator = LobbyAverageEstimator()
    var rows = (0..<7).map { LobbyRatingRow(position: $0, name: "P\($0)", rating: .belowCutoff(8000), rank: nil, isLocalPlayer: false) }
    rows[0] = LobbyRatingRow(position: 0, name: "Me", rating: .exact(8000), rank: nil, isLocalPlayer: true)
    var next = 7490
    let first = estimator.summary(rows: rows) { next += 20; return next }
    let second = estimator.summary(rows: rows) { 7999 }
    #expect(first == second); #expect(first != nil)
    #expect(LobbyAverageEstimator.estimateRange.contains(first!.average))
    #expect(estimator.summary(rows: Array(rows.prefix(6))) == nil)
  }
  @Test("geometry clamps scale and recovers fully onscreen")
  func geometry() {
    let frame = LobbyOverlayGeometry.restoredFrame(origin: CGPoint(x: 9, y: -9), scale: 4,
      baseSize: CGSize(width: 200, height: 100), gameFrame: CGRect(x: 0, y: 0, width: 1000, height: 700),
      visibleFrame: CGRect(x: 0, y: 0, width: 1000, height: 700))
    #expect(frame.width == 300); #expect(frame.minX >= 0); #expect(frame.maxX <= 1000)
    #expect(frame.minY >= 0); #expect(frame.maxY <= 700)
  }
  @Test("corner resizing grows and shrinks proportionally without moving the top-left corner")
  func cornerResize() {
    let base = CGSize(width: 208, height: 233)
    let frame = CGRect(x: -900, y: 120, width: 208, height: 233)
    for delta in [CGPoint(x: 52, y: -58.25), CGPoint(x: -52, y: 58.25), CGPoint(x: 0, y: 40)] {
      let result = LobbyOverlayGeometry.resizedFrame(from: frame, delta: delta, baseSize: base)
      #expect(result.minX == frame.minX)
      #expect(result.maxY == frame.maxY)
      #expect(abs(result.width / result.height - base.width / base.height) < 0.00001)
    }
    let smaller = LobbyOverlayGeometry.resizedFrame(from: frame, delta: CGPoint(x: -52, y: 58.25), baseSize: base)
    #expect(smaller.width == 156)
  }
  @Test("layout snaps only nearby edges and relative coordinates survive a display change")
  func layoutSnappingAndRestoration() {
    let game = CGRect(x: -1440, y: 0, width: 1440, height: 900)
    let near = CGRect(x: -1435, y: 6, width: 208, height: 233)
    let snapped = LobbyOverlayGeometry.snappedFrame(near, to: game)
    #expect(snapped.minX == game.minX)
    #expect(snapped.minY == game.minY)
    let far = CGRect(x: -1200, y: 100, width: 208, height: 233)
    #expect(LobbyOverlayGeometry.snappedFrame(far, to: game) == far)
    let origin = LobbyOverlayGeometry.normalizedOrigin(frame: far, gameFrame: game)
    let movedGame = game.offsetBy(dx: 1440, dy: 100)
    let restored = LobbyOverlayGeometry.restoredFrame(origin: origin, scale: 1,
      baseSize: far.size, gameFrame: movedGame, visibleFrame: movedGame)
    #expect(abs(restored.minX - (far.minX + 1440)) < 0.001)
    #expect(abs(restored.minY - (far.minY + 100)) < 0.001)
  }
  @Test("corrupt and wrong-region cache metadata is rejected")
  func validation() {
    let empty = LeaderboardSnapshot(seasonID: 20, region: "EU", generatedAt: now, players: [])
    #expect(!empty.isUsable(at: now, expectedRegion: "EU"))
    let good = LeaderboardSnapshot(seasonID: 20, region: "EU", generatedAt: now,
      players: [LeaderboardPlayer(name: "A", rating: 8000, rank: 1)])
    #expect(!good.isUsable(at: now, expectedRegion: "US"))
    #expect(!good.isUsable(at: now.addingTimeInterval(86_401), expectedRegion: "EU"))
  }
  @Test("page validation rejects partial and mixed-season refreshes")
  func pages() throws {
    func page(season: Int, pageCount: Int, size: Int, rows: [[String: Any]]) -> [String: Any] {
      ["seasonId": season, "leaderboard": ["pagination": ["totalPages": pageCount, "totalSize": size], "rows": rows]]
    }
    let first = page(season: 20, pageCount: 2, size: 2, rows: [["rank": 1, "accountid": "A", "rating": 9000]])
    let second = page(season: 20, pageCount: 2, size: 2, rows: [["rank": 2, "accountid": "B", "rating": 8000]])
    #expect(throws: Never.self) { _ = try LeaderboardPageValidator.snapshot(pages: [first, second], region: "EU", now: now) }
    #expect(throws: LeaderboardValidationError.self) { _ = try LeaderboardPageValidator.snapshot(pages: [first], region: "EU", now: now) }
    let mixed = page(season: 21, pageCount: 2, size: 2, rows: [["rank": 2, "accountid": "B", "rating": 8000]])
    #expect(throws: LeaderboardValidationError.self) { _ = try LeaderboardPageValidator.snapshot(pages: [first, mixed], region: "EU", now: now) }
  }
  @Test("Retry-After honors seconds and HTTP dates")
  func retryAfter() {
    #expect(RetryAfterPolicy.date(header: "120", now: now) == now.addingTimeInterval(120))
    #expect(RetryAfterPolicy.date(header: "Wed, 21 Oct 2015 07:28:00 GMT", now: now)
      == Date(timeIntervalSince1970: 1_445_412_480))
    #expect(RetryAfterPolicy.date(header: "bad", now: now) == nil)
  }
  @Test("cancellation invalidates older refresh completions")
  func callbackGeneration() {
    var generation = LobbyCallbackGeneration()
    let first = generation.begin()
    #expect(generation.accepts(first))
    generation.cancel()
    #expect(!generation.accepts(first))
    let second = generation.begin()
    #expect(generation.accepts(second))
  }
  @Test("match lifecycle rejects callbacks after exit and replacement")
  func lifecycle() {
    var state = LobbyLifecycleState()
    let firstActivated = state.activate("first")
    #expect(firstActivated)
    let firstGeneration = state.generation
    #expect(state.accepts(uuid: "first", generation: firstGeneration))
    state.deactivate()
    #expect(state.activeUUID == nil)
    #expect(!state.accepts(uuid: "first", generation: firstGeneration))
    let secondActivated = state.activate("second")
    #expect(secondActivated)
    #expect(!state.accepts(uuid: "first", generation: state.generation))
  }
  @Test("repeated menu ticks preserve only a deliberate pre-match editor")
  func menuTicksDuringPreview() {
    var state = LobbyLifecycleState()
    let initialGeneration = state.generation
    let firstMenuTick = state.handleMenuTick(isEditingPreview: true, hasGameWindow: true)
    let secondMenuTick = state.handleMenuTick(isEditingPreview: true, hasGameWindow: true)
    #expect(firstMenuTick)
    #expect(secondMenuTick)
    #expect(state.generation == initialGeneration)
    let missingWindowTick = state.handleMenuTick(isEditingPreview: true, hasGameWindow: false)
    #expect(!missingWindowTick)
    #expect(state.generation == initialGeneration + 1)

    let activated = state.activate("live-match")
    #expect(activated)
    let matchGeneration = state.generation
    let matchEndTick = state.handleMenuTick(isEditingPreview: true, hasGameWindow: true)
    #expect(!matchEndTick)
    #expect(state.activeUUID == nil)
    #expect(state.generation == matchGeneration + 1)
  }
  @Test("editing shortcut saves on second press without reopening preview")
  func editingCommand() {
    #expect(LobbyOverlayEditCommand.next(isEditing: false) == .previewThenBegin)
    #expect(LobbyOverlayEditCommand.next(isEditing: true) == .save)
  }
  @Test("hotkey event IDs route reconnect and lobby independently")
  func hotKeyRouting() {
    #expect(HotKeyActionID(rawValue: 1) == .reconnect)
    #expect(HotKeyActionID(rawValue: 2) == .lobbyLayout)
    #expect(HotKeyActionID.reconnect.rawValue != HotKeyActionID.lobbyLayout.rawValue)
  }
  @Test("reconnect detection restores only a live Solo Battlegrounds session")
  func reconnectDetection() {
    #expect(LobbyReconnectPolicy.sessionLogSaysReconnect(
      "reconnecting=False\nreconnecting=True\n"))
    #expect(!LobbyReconnectPolicy.sessionLogSaysReconnect(
      "reconnecting=True\nreconnecting=False\n"))
    #expect(LobbyReconnectPolicy.phase(gameUUIDPresent: true, gameType: 0, mode: "solo",
      sessionLogSaysReconnect: false, secondsSinceAttachment: 0) == .live)
    #expect(LobbyReconnectPolicy.phase(gameUUIDPresent: false, gameType: 23, mode: "solo",
      sessionLogSaysReconnect: false, secondsSinceAttachment: 90) == .idle)
    #expect(LobbyReconnectPolicy.phase(gameUUIDPresent: false, gameType: 23, mode: "solo",
      sessionLogSaysReconnect: true, secondsSinceAttachment: 10) == .resuming)
    #expect(LobbyReconnectPolicy.phase(gameUUIDPresent: false, gameType: 0, mode: "solo",
      sessionLogSaysReconnect: true, secondsSinceAttachment: 10) == .resuming)
    #expect(LobbyReconnectPolicy.phase(gameUUIDPresent: false, gameType: 0, mode: "solo",
      sessionLogSaysReconnect: true, secondsSinceAttachment: 31) == .idle)
    #expect(LobbyReconnectPolicy.phase(gameUUIDPresent: false, gameType: 0, mode: "unknown",
      sessionLogSaysReconnect: false, secondsSinceAttachment: 2) == .probing)
    #expect(LobbyReconnectPolicy.phase(gameUUIDPresent: false, gameType: 0, mode: "unknown",
      sessionLogSaysReconnect: false, secondsSinceAttachment: 29) == .probing)
    #expect(LobbyReconnectPolicy.phase(gameUUIDPresent: false, gameType: 0, mode: "unknown",
      sessionLogSaysReconnect: false, secondsSinceAttachment: 30) == .idle)
    #expect(LobbyReconnectPolicy.phase(gameUUIDPresent: false, gameType: 0, mode: "unknown",
      sessionLogSaysReconnect: true, secondsSinceAttachment: 6) == .resuming)
    #expect(LobbyReconnectPolicy.phase(gameUUIDPresent: false, gameType: 23, mode: "duos",
      sessionLogSaysReconnect: true, secondsSinceAttachment: 1) == .idle)
    #expect(LobbyReconnectPolicy.liveCaptureDisposition(mode: "solo") == .publish)
    #expect(LobbyReconnectPolicy.liveCaptureDisposition(mode: "unknown") == .waitForMode)
    #expect(LobbyReconnectPolicy.liveCaptureDisposition(mode: "duos") == .unsupported)
  }
  @Test("resume cache accepts only a fresh complete Solo lobby")
  func resumeCachePolicy() {
    #expect(LobbyResumeCachePolicy.isUsable(savedAt: now.addingTimeInterval(-60), now: now,
      gameUUID: "game", mode: "solo", playerCount: 8, namedPlayerCount: 8,
      distinctAccountCount: 8))
    #expect(!LobbyResumeCachePolicy.isUsable(savedAt: now.addingTimeInterval(-10_801), now: now,
      gameUUID: "game", mode: "solo", playerCount: 8, namedPlayerCount: 8,
      distinctAccountCount: 8))
    #expect(!LobbyResumeCachePolicy.isUsable(savedAt: now, now: now,
      gameUUID: "game", mode: "solo", playerCount: 7, namedPlayerCount: 7,
      distinctAccountCount: 7))
    #expect(!LobbyResumeCachePolicy.isUsable(savedAt: now, now: now,
      gameUUID: "game", mode: "solo", playerCount: 8, namedPlayerCount: 7,
      distinctAccountCount: 8))
  }
  @Test("capture helper restarts only when Hearthstone launches with a new process")
  func captureHelperProcessTransition() {
    #expect(!LobbyHelperProcessPolicy.shouldRestart(previousPID: nil, currentPID: nil))
    #expect(LobbyHelperProcessPolicy.shouldRestart(previousPID: nil, currentPID: 100))
    #expect(!LobbyHelperProcessPolicy.shouldRestart(previousPID: 100, currentPID: 100))
    #expect(!LobbyHelperProcessPolicy.shouldRestart(previousPID: 100, currentPID: nil))
    #expect(LobbyHelperProcessPolicy.shouldRestart(previousPID: 100, currentPID: 200))
  }
  @Test("a game that is still starting is retried silently at a steady pace")
  func lobbyAttachRetryWhileStarting() {
    typealias Policy = LobbyAttachRetryPolicy
    func delay(_ failureCount: Int, _ kind: LobbyAttachFailureKind) -> TimeInterval? {
      let date = Policy.retryAfter(now: now, failureCount: failureCount, kind: kind)
      return date == .distantFuture ? nil : date.timeIntervalSince(now)
    }
    let slowAfter = Policy.startupRetriesBeforeSlowing
    let giveUpAfter = Policy.unreadableRetriesBeforeGivingUp
    for kind in [LobbyAttachFailureKind.gameNotReadable, .notSignedIn] {
      #expect(kind.retriesSilently)
      #expect(delay(1, kind) == Policy.startupRetryDelay)
      #expect(delay(2, kind) == Policy.startupRetryDelay)
      #expect(delay(slowAfter, kind) == Policy.startupRetryDelay)
      #expect(delay(slowAfter + 1, kind) == Policy.slowStartupRetryDelay)
      #expect(delay(giveUpAfter, kind) == Policy.slowStartupRetryDelay)
    }
    // A login screen left open keeps being checked; a game that never becomes readable is given up on.
    #expect(delay(giveUpAfter + 1, .notSignedIn) == Policy.slowStartupRetryDelay)
    #expect(delay(100_000, .notSignedIn) == Policy.slowStartupRetryDelay)
    #expect(delay(giveUpAfter + 1, .gameNotReadable) == nil)
    // The 00:47 launch on 10 Nov 2026 needed about 17 s to reach the menu: well inside the fast pace.
    #expect(Policy.startupRetryDelay * Double(slowAfter) >= 60)
    #expect(Policy.startupRetryDelay < Policy.slowStartupRetryDelay && slowAfter < giveUpAfter)
    // Anything that can show a dialog never repeats: one automatic retry, none after a rejection.
    for kind in [LobbyAttachFailureKind.mayPrompt, .permissionRejected] { #expect(!kind.retriesSilently) }
    #expect(delay(1, .mayPrompt) == Policy.automaticRetryDelay)
    for count in [2, 3, slowAfter, giveUpAfter + 1] { #expect(delay(count, .mayPrompt) == nil) }
    for count in [1, 2, slowAfter] { #expect(delay(count, .permissionRejected) == nil) }
  }
  @Test("a reader made before sign-in is thrown away instead of trusted")
  func lobbyMirrorReadiness() {
    typealias Policy = LobbyMirrorReadinessPolicy
    // Signed in: use it.
    #expect(Policy.disposition(hasLogSessionDirectory: true, signedIn: true,
                               canRetryWithoutDialog: true) == .accept)
    #expect(Policy.disposition(hasLogSessionDirectory: true, signedIn: true,
                               canRetryWithoutDialog: false) == .accept)
    // The failing launch: attached 3 s after Hearthstone opened, before sign-in.
    #expect(Policy.disposition(hasLogSessionDirectory: true, signedIn: false,
                               canRetryWithoutDialog: true) == .retryLater)
    // Making another reader could show a dialog: keep this one, as before, rather than risk a prompt loop.
    #expect(Policy.disposition(hasLogSessionDirectory: true, signedIn: false,
                               canRetryWithoutDialog: false) == .accept)
    // No log folder is still an attach failure, signed in or not.
    for signedIn in [true, false] {
      for canRetry in [true, false] {
        #expect(Policy.disposition(hasLogSessionDirectory: false, signedIn: signedIn,
                                   canRetryWithoutDialog: canRetry) == .failed)
      }
    }
    #expect(!Policy.isSignedIn(battleTag: nil, accountHigh: nil, accountLow: nil))
    #expect(!Policy.isSignedIn(battleTag: "  ", accountHigh: 0, accountLow: 0))
    #expect(!Policy.isSignedIn(battleTag: "#1234", accountHigh: nil, accountLow: nil))
    #expect(Policy.isSignedIn(battleTag: "Player#1234", accountHigh: nil, accountLow: nil))
    #expect(Policy.isSignedIn(battleTag: nil, accountHigh: 144_115_193_835_963_207, accountLow: 0))
    #expect(Policy.isSignedIn(battleTag: nil, accountHigh: 0, accountLow: 42))
  }
  @Test("the class list is re-read a few times while the menus finish loading, never during a match")
  func lobbyMirrorRefresh() {
    typealias Policy = LobbyMirrorRefreshPolicy
    let delays = Policy.refreshDelays
    #expect(!delays.isEmpty && delays.allSatisfy { $0 >= 10 })
    for (done, delay) in delays.enumerated() {
      #expect(!Policy.isDue(now: now.addingTimeInterval(delay - 1), snapshotAt: now,
                            refreshesDone: done, matchVisible: false))
      #expect(Policy.isDue(now: now.addingTimeInterval(delay), snapshotAt: now,
                           refreshesDone: done, matchVisible: false))
      // A reader that shows a match works: leave it alone.
      #expect(!Policy.isDue(now: now.addingTimeInterval(delay * 10), snapshotAt: now,
                            refreshesDone: done, matchVisible: true))
    }
    // Bounded: after the last one the helper stops re-reading for this Hearthstone process.
    #expect(!Policy.isDue(now: .distantFuture, snapshotAt: now, refreshesDone: delays.count, matchVisible: false))
    #expect(!Policy.isDue(now: .distantFuture, snapshotAt: now, refreshesDone: -1, matchVisible: false))
  }
  @Test("the launch that showed no overlays now ends with a reader made after the menu loaded")
  func recordedFailingLaunch() {
    // 10 Nov 2026, seconds after Hearthstone opened: helper attached at 3 (macOS granted access with no
    // dialog), sign-in at 9, menu at 17, match at 48. The reader made at 3 never saw the lobby.
    let signInAt: TimeInterval = 9, menuAt: TimeInterval = 17, matchAt: TimeInterval = 48
    var time: TimeInterval = 3
    var failures = 0
    var acceptedAt: TimeInterval?
    while acceptedAt == nil, failures < 100 {
      switch LobbyMirrorReadinessPolicy.disposition(hasLogSessionDirectory: true, signedIn: time >= signInAt,
                                                    canRetryWithoutDialog: true) {
      case .accept:
        acceptedAt = time
      case .retryLater:
        failures += 1
        #expect(LobbyAttachFailureKind.notSignedIn.retriesSilently)
        time = LobbyAttachRetryPolicy.retryAfter(now: now.addingTimeInterval(time), failureCount: failures,
                                                 kind: .notSignedIn).timeIntervalSince(now)
      case .failed:
        Issue.record("a readable game counted as an attach failure")
        return
      }
    }
    guard let acceptedAt else { Issue.record("never attached"); return }
    #expect(acceptedAt >= signInAt && acceptedAt < signInAt + LobbyAttachRetryPolicy.startupRetryDelay)
    // The first re-read of the class list falls after the menu loaded and before the match began.
    let firstRefresh = acceptedAt + LobbyMirrorRefreshPolicy.refreshDelays[0]
    #expect(firstRefresh > menuAt && firstRefresh < matchAt)
    #expect(LobbyMirrorRefreshPolicy.isDue(now: now.addingTimeInterval(firstRefresh),
                                           snapshotAt: now.addingTimeInterval(acceptedAt),
                                           refreshesDone: 0, matchVisible: false))
  }
  @Test("first attach failure gets one automatic retry without repeating denied prompts")
  func lobbyAttachRetry() {
    let retryAfter = LobbyAttachRetryPolicy.retryAfter(now: now, failureCount: 1, kind: .mayPrompt)
    #expect(retryAfter == now.addingTimeInterval(LobbyAttachRetryPolicy.automaticRetryDelay))
    #expect(!LobbyAttachRetryPolicy.canAttempt(
      failedPID: 100, retryAfter: retryAfter, currentPID: 100, now: now
    ))
    #expect(LobbyAttachRetryPolicy.canAttempt(
      failedPID: 100, retryAfter: retryAfter, currentPID: 100, now: retryAfter
    ))
    #expect(LobbyAttachRetryPolicy.canAttempt(
      failedPID: 100, retryAfter: retryAfter, currentPID: 200, now: now
    ))
    let afterSecondFailure = LobbyAttachRetryPolicy.retryAfter(now: now, failureCount: 2, kind: .mayPrompt)
    let afterDeniedPermission = LobbyAttachRetryPolicy.retryAfter(
      now: now, failureCount: 1, kind: .permissionRejected)
    #expect(afterSecondFailure == .distantFuture)
    #expect(afterDeniedPermission == .distantFuture)
    #expect(!LobbyAttachRetryPolicy.canAttempt(
      failedPID: 100, retryAfter: afterDeniedPermission, currentPID: 100, now: retryAfter
    ))
  }
}
