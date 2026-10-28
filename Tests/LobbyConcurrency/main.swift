import AppKit
import Foundation

enum AppConfiguration {
  static let bundleIdentifier = "io.github.kulibabkaaa.HSReconnect.ConcurrencyTests"
}

enum DefaultsKey {
  static let lobbyResumeCapture = "test.lobby.resume"
  static let lobbyEnabled = "test.lobby.enabled"
}

enum HearthstoneApp {
  static let bundleIdentifier = "io.github.kulibabkaaa.HSReconnect.ConcurrencyTests.NoGame"
}

final class LobbyOverlayController {
  var onStatus: ((String) -> Void)?
  var isEditing = false
  private(set) var gameWindowUpdates = 0
  private(set) var previews = 0
  private(set) var closes = 0
  private(set) var shows = 0
  func updateGameWindow(frame: NSRect?) { gameWindowUpdates += 1 }
  func close() { closes += 1 }
  func cancelAndClose() { closes += 1 }
  func showPreview(gameFrame: NSRect) { previews += 1 }
  func show(rows: [LobbyRatingRow], summary: LobbyAverageSummary?, gameFrame: NSRect?) { shows += 1 }
}

private enum TestFailure: Error, CustomStringConvertible {
  case failed(String)
  var description: String {
    switch self { case .failed(let message): return message }
  }
}

private func require(_ condition: @autoclosure () -> Bool, _ message: String) throws {
  guard condition() else { throw TestFailure.failed(message) }
}

private func waitUntil(timeout: TimeInterval = 2, _ condition: () -> Bool) -> Bool {
  let deadline = Date().addingTimeInterval(timeout)
  while Date() < deadline {
    if condition() { return true }
    RunLoop.main.run(mode: .default, before: Date().addingTimeInterval(0.01))
  }
  return condition()
}

private final class StubURLProtocol: URLProtocol {
  enum Mode { case delayedSuccess, immediateSuccess, never }
  private static let lock = NSLock()
  private static var mode: Mode = .immediateSuccess
  private static var requests = 0

  static func reset(mode: Mode) {
    lock.lock(); defer { lock.unlock() }
    self.mode = mode
    requests = 0
  }

  static var requestCount: Int {
    lock.lock(); defer { lock.unlock() }
    return requests
  }

  override class func canInit(with request: URLRequest) -> Bool { true }
  override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

  override func startLoading() {
    Self.lock.lock()
    Self.requests += 1
    let mode = Self.mode
    Self.lock.unlock()
    guard mode != .never else { return }
    let respond = { [weak self] in
      guard let self, let url = self.request.url else { return }
      let body: [String: Any] = [
        "seasonId": 20,
        "leaderboard": [
          "pagination": ["totalPages": 1, "totalSize": 1],
          "rows": [["rank": 1, "accountid": "Alice#111", "rating": 9000]],
        ],
      ]
      let data = try! JSONSerialization.data(withJSONObject: body)
      let response = HTTPURLResponse(url: url, statusCode: 200,
                                     httpVersion: nil, headerFields: nil)!
      self.client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
      self.client?.urlProtocol(self, didLoad: data)
      self.client?.urlProtocolDidFinishLoading(self)
    }
    if mode == .delayedSuccess {
      DispatchQueue.global().asyncAfter(deadline: .now() + 0.08, execute: respond)
    } else {
      respond()
    }
  }

  override func stopLoading() {}
}

private func session() -> URLSession {
  let configuration = URLSessionConfiguration.ephemeral
  configuration.protocolClasses = [StubURLProtocol.self]
  return URLSession(configuration: configuration)
}

private func temporaryDirectory(_ name: String) throws -> URL {
  let url = FileManager.default.temporaryDirectory
    .appendingPathComponent("HSReconnect-\(name)-\(UUID().uuidString)", isDirectory: true)
  try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
  return url
}

private func capture(uuid: String, region: String, names: [String]) -> LobbyCapture {
  LobbyCapture(gameUUID: uuid, gameType: 23, region: region, mode: "solo",
               ownBattleTag: nil, ownAccountID: nil, ownRating: nil,
               players: names.enumerated().map {
                 LobbyPlayer(position: $0.offset,
                             accountID: LobbyAccountID(high: 1, low: Int64($0.offset)),
                             name: $0.element)
               })
}

private func testLatestCaptureSelection() throws {
  let partial = capture(uuid: "game", region: "EU", names: ["A"])
  let complete = capture(uuid: "game", region: "EU", names: ["A", "B"])
  let selected = LobbyCapturePublication.latestMatching(
    complete, gameUUID: partial.gameUUID!, region: partial.region
  )
  try require(selected == complete, "leaderboard completion did not select the latest capture")
  try require(LobbyCapturePublication.latestMatching(
    capture(uuid: "next", region: "EU", names: ["C"]),
    gameUUID: "game", region: "EU"
  ) == nil, "leaderboard completion crossed match UUIDs")
  try require(LobbyCapturePublication.latestMatching(
    capture(uuid: "game", region: "US", names: ["C"]),
    gameUUID: "game", region: "EU"
  ) == nil, "leaderboard completion crossed regions")
}

private func testStableMatchRetriesWithoutAnotherCapture() throws {
  var attempts: [(Result<LeaderboardSnapshot, Error>) -> Void] = []
  let loop = LobbyLeaderboardRetryLoop { _, completion in attempts.append(completion) }
  let request = LobbyLeaderboardRequest(
    gameUUID: "game", region: "EU", lifecycleGeneration: 3
  )
  var handledResults = 0
  loop.start(request) { _, result in
    handledResults += 1
    if case .failure = result { return true }
    return false
  }
  try require(attempts.count == 1, "stable match did not start its first refresh")

  attempts.removeFirst()(.failure(LobbyLeaderboardError.invalidResponse))
  try require(attempts.count == 1,
              "failed refresh needed a new capture before scheduling its retry")
  let snapshot = LeaderboardSnapshot(
    seasonID: 20, region: "EU", generatedAt: Date(),
    players: [LeaderboardPlayer(name: "Alice", rating: 9000, rank: 1)]
  )
  attempts.removeFirst()(.success(snapshot))
  try require(handledResults == 2, "retry result was not delivered")

  loop.start(request) { _, _ in true }
  try require(attempts.count == 1, "completed retry loop could not start again")
  loop.cancel()
  attempts.removeFirst()(.failure(LobbyLeaderboardError.invalidResponse))
  try require(attempts.isEmpty, "cancelled match scheduled another retry")
}

private func testReaderGenerations() throws {
  let state = LobbyReaderDeliveryGeneration()
  let firstRun = state.startRun()
  let firstProcess = state.beginProcess(for: firstRun)!
  try require(state.accepts(firstProcess), "current reader process was rejected")

  state.invalidateProcess(for: firstRun)
  let secondProcess = state.beginProcess(for: firstRun)!
  try require(!state.accepts(firstProcess), "old process output survived a helper restart")
  try require(state.accepts(secondProcess), "new helper process output was rejected")

  state.stopRun()
  try require(!state.accepts(firstRun), "queued run callback survived stop")
  try require(!state.accepts(secondProcess), "queued process callback survived stop")
  let secondRun = state.startRun()
  try require(state.accepts(secondRun), "restarted reader run was rejected")
  try require(!state.accepts(firstRun), "old run callback survived stop and restart")
}

private func testRefreshCoalescing() throws {
  StubURLProtocol.reset(mode: .delayedSuccess)
  let directory = try temporaryDirectory("coalescing")
  defer { try? FileManager.default.removeItem(at: directory) }
  let store = LobbyLeaderboardStore(session: session(), cacheDirectory: directory)
  var results: [Result<LeaderboardSnapshot, Error>] = []
  store.refreshIfNeeded(region: "EU") { results.append($0) }
  store.refreshIfNeeded(region: "EU") { results.append($0) }

  try require(waitUntil { results.count == 2 }, "coalesced callers did not both complete")
  try require(StubURLProtocol.requestCount == 1, "coalesced callers started duplicate refreshes")
  try require(results.allSatisfy {
    if case .success = $0 { return true }
    return false
  }, "coalesced refresh did not return success to every caller")
}

private func testCooldownRequestRetries() throws {
  StubURLProtocol.reset(mode: .immediateSuccess)
  let unwritable = URL(fileURLWithPath: "/dev/null/HSReconnect-cache")
  let store = LobbyLeaderboardStore(session: session(), cacheDirectory: unwritable,
                                    failureRetryDelay: 0.08)
  var firstFinished = false
  store.refreshIfNeeded(region: "EU") { _ in firstFinished = true }
  try require(waitUntil { firstFinished }, "initial failed save did not complete")

  let startedAt = Date()
  var retryFinished = false
  store.refreshIfNeeded(region: "EU") { _ in retryFinished = true }
  try require(waitUntil { retryFinished }, "request made during cooldown was dropped")
  try require(Date().timeIntervalSince(startedAt) >= 0.05,
              "request made during cooldown did not wait before retrying")
  try require(StubURLProtocol.requestCount == 2, "cooldown request did not retry exactly once")
}

private func testCancellationCompletesWaiters() throws {
  StubURLProtocol.reset(mode: .never)
  let directory = try temporaryDirectory("cancellation")
  defer { try? FileManager.default.removeItem(at: directory) }
  let store = LobbyLeaderboardStore(session: session(), cacheDirectory: directory)
  var errors: [Error] = []
  store.refreshIfNeeded(region: "EU") {
    if case .failure(let error) = $0 { errors.append(error) }
  }
  store.refreshIfNeeded(region: "EU") {
    if case .failure(let error) = $0 { errors.append(error) }
  }
  try require(waitUntil { StubURLProtocol.requestCount == 1 }, "refresh did not start")
  store.cancel()
  try require(waitUntil { errors.count == 2 }, "cancellation dropped coalesced callers")
  try require(errors.allSatisfy { $0 is CancellationError },
              "cancellation returned the wrong error")
}

private func testSharedWindowTracker() throws {
  let tracker = HearthstoneWindowTracker()
  let overlay = LobbyOverlayController()
  let lobby = LobbyCoordinator(overlay: overlay, windowTracker: tracker)
  let button = NSObject()
  var buttonFrames: [NSRect?] = []
  try require(!tracker.isPolling, "tracker polled with no subscribers")
  lobby.start()
  tracker.subscribe(button) { buttonFrames.append($0) }
  tracker.subscribe(button) { buttonFrames.append($0) }  // replaces, doesn't double up
  try require(tracker.isPolling, "tracker didn't start polling")
  try require(waitUntil { overlay.gameWindowUpdates >= 2 && buttonFrames.count >= 2 },
              "one poll didn't feed both overlays")
  try require(buttonFrames.allSatisfy { $0 == nil }, "found a game window that doesn't exist")
  lobby.stop()
  try require(tracker.isPolling, "stopping the lobby stopped the button's poll")
  let lobbyUpdates = overlay.gameWindowUpdates
  let buttonUpdates = buttonFrames.count
  try require(waitUntil { buttonFrames.count >= buttonUpdates + 2 }, "button poll stopped with the lobby")
  try require(overlay.gameWindowUpdates == lobbyUpdates, "stopped lobby still got frames")
  tracker.unsubscribe(button)
  try require(!tracker.isPolling, "tracker kept polling with no subscribers")
}

private func testLayoutPreparation() throws {
  let overlay = LobbyOverlayController()
  let lobby = LobbyCoordinator(overlay: overlay, windowTracker: HearthstoneWindowTracker())
  lobby.prepareForLayout(gameFrame: NSRect(x: 0, y: 0, width: 1440, height: 900))
  try require(overlay.gameWindowUpdates == 1 && overlay.previews == 1,
              "layout mode without a match didn't place and preview the lobby")
  lobby.closeOverlayForMissingGame()
  try require(overlay.closes == 1, "missing game didn't close the lobby overlay")
}

private func capture(_ uuid: String?, mode: String = "solo") -> LobbyCapture {
  // Region CN skips the ratings request; no players keeps the resume cache empty.
  LobbyCapture(gameUUID: uuid, gameType: 0, region: "CN", mode: mode, ownBattleTag: nil,
               ownAccountID: nil, ownRating: nil, players: [])
}

/// Lobby info on: the Reconnect button's match signal is on with real Solo rows, a Duos match or a match being
/// resumed; off when the match ends, the mode is unknown, the game is missing, the reader detaches or stops.
private func testMatchSignal() throws {
  UserDefaults.standard.register(defaults: [DefaultsKey.lobbyEnabled: true])
  // Later tests expect lobby info off, so they don't start the real reader.
  defer { UserDefaults.standard.register(defaults: [DefaultsKey.lobbyEnabled: false]) }
  let overlay = LobbyOverlayController()
  let lobby = LobbyCoordinator(overlay: overlay, windowTracker: HearthstoneWindowTracker())
  var changes = 0
  lobby.onMatchStateChanged = { changes += 1 }
  try require(!lobby.isInMatch && !lobby.isMatchDetectorAvailable, "a new coordinator reported a match")
  lobby.start()
  defer { lobby.stop() }
  try require(lobby.diagnosticReaderMode == .lobby, "lobby info on didn't run the lobby reader")
  lobby.diagnosticAttachment(true)
  try require(lobby.isMatchDetectorAvailable, "attaching didn't make the detector available")
  lobby.prepareForLayout(gameFrame: NSRect(x: 0, y: 0, width: 1440, height: 900))
  try require(!lobby.isInMatch, "the layout sample counted as a match")
  lobby.diagnosticCapture(capture("solo-1"))
  try require(lobby.isInMatch && overlay.shows == 1, "real Solo rows didn't start a match")
  let afterStart = changes
  lobby.diagnosticCapture(capture("solo-1"))
  try require(changes == afterStart, "the same match reported a change")
  lobby.diagnosticCapture(capture(nil))
  try require(!lobby.isInMatch, "the match end didn't end the match")
  lobby.diagnosticCapture(capture("duos-1", mode: "duos"))
  try require(lobby.isInMatch, "a Duos match didn't count")
  let afterDuos = changes
  lobby.diagnosticCapture(capture("duos-1", mode: "duos"))
  lobby.diagnosticCapture(capture("solo-2"))
  try require(lobby.isInMatch && changes == afterDuos, "the Duos match blipped off")
  lobby.diagnosticCapture(capture("unknown-1", mode: "unknown"))
  try require(!lobby.isInMatch, "an unknown mode counted as a match")
  lobby.diagnosticCapture(capture("solo-3"))
  lobby.closeOverlayForMissingGame()
  try require(lobby.isInMatch, "a missing game window ended the match")
  lobby.diagnosticCapture(capture(nil))
  lobby.diagnosticReconnectDetected()
  try require(lobby.isInMatch, "a match being resumed didn't count")
  lobby.diagnosticAttachment(false)
  try require(!lobby.isInMatch && !lobby.isMatchDetectorAvailable, "detaching kept the match")
  lobby.diagnosticAttachment(true)
  lobby.diagnosticCapture(capture("solo-4"))
  lobby.stop()
  try require(!lobby.isInMatch && !lobby.isMatchDetectorAvailable, "stopping kept the match")
}

/// Lobby info off, Reconnect button on: the reader runs for match detection only while Hearthstone runs, and
/// draws, reports and says nothing.
private func testMatchDetectionOnly() throws {
  UserDefaults.standard.register(defaults: [DefaultsKey.lobbyEnabled: false])
  defer { UserDefaults.standard.register(defaults: [DefaultsKey.lobbyEnabled: false]) }
  let overlay = LobbyOverlayController()
  let lobby = LobbyCoordinator(overlay: overlay, windowTracker: HearthstoneWindowTracker())
  var inputs = (buttonEnabled: true, hearthstoneRunning: false)
  lobby.matchDetectionInputs = { inputs }
  var statuses: [String] = []
  var displayed = 0
  lobby.onStatus = { statuses.append($0) }
  lobby.onLobbyDisplayed = { displayed += 1 }
  lobby.start()
  defer { lobby.stop() }
  try require(lobby.diagnosticReaderMode == .off, "the detector ran without Hearthstone")
  inputs.hearthstoneRunning = true
  lobby.refreshReaderMode()
  try require(lobby.diagnosticReaderMode == .matchDetectionOnly, "the detector didn't start with Hearthstone")
  lobby.diagnosticAttachment(true)
  lobby.diagnosticCapture(capture("solo-1"))
  try require(lobby.isInMatch && lobby.isMatchDetectorAvailable, "match detection missed a Solo match")
  lobby.diagnosticCapture(capture(nil))
  try require(!lobby.isInMatch, "match detection missed the match end")
  lobby.diagnosticCapture(capture("duos-1", mode: "duos"))
  try require(lobby.isInMatch, "match detection missed a Duos match")
  lobby.diagnosticStatus("Waiting for Hearthstone")
  try require(!lobby.isInMatch, "Hearthstone leaving kept the match")
  lobby.diagnosticStatus("Lobby access needs approval")
  lobby.diagnosticReconnectDetected()
  try require(lobby.isInMatch, "match detection missed a match being resumed")
  try require(overlay.shows == 0 && overlay.previews == 0 && displayed == 0 && statuses.isEmpty,
              "match detection drew, reported or said something")
  inputs.buttonEnabled = false
  lobby.refreshReaderMode()
  try require(lobby.diagnosticReaderMode == .off && !lobby.isInMatch && !lobby.isMatchDetectorAvailable,
              "turning the button off left the detector running")
  inputs.buttonEnabled = true
  lobby.refreshReaderMode()
  UserDefaults.standard.register(defaults: [DefaultsKey.lobbyEnabled: true])
  lobby.refreshReaderMode()
  try require(lobby.diagnosticReaderMode == .lobby, "lobby info on didn't switch to the lobby reader")
}

do {
  try testMatchSignal()
  try testMatchDetectionOnly()
  try testSharedWindowTracker()
  try testLayoutPreparation()
  try testLatestCaptureSelection()
  try testStableMatchRetriesWithoutAnotherCapture()
  try testReaderGenerations()
  try testRefreshCoalescing()
  try testCooldownRequestRetries()
  try testCancellationCompletesWaiters()
  print("Lobby concurrency tests passed.")
} catch {
  fputs("FAIL: \(error)\n", stderr)
  exit(1)
}
