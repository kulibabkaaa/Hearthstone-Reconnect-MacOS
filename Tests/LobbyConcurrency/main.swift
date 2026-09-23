import AppKit
import Foundation

enum AppConfiguration {
  static let bundleIdentifier = "io.github.kulibabkaaa.HSReconnect.ConcurrencyTests"
}

enum DefaultsKey {
  static let lobbyResumeCapture = "test.lobby.resume"
  static let lobbyEnabled = "test.lobby.enabled"
}

final class LobbyOverlayController {
  var onStatus: ((String) -> Void)?
  var opacityPercent = 100.0
  var isEditing = false
  func updateGameWindow(frame: NSRect?) {}
  func close() {}
  func cancelAndClose() {}
  func toggleEditing() { isEditing.toggle() }
  func resetLayout() {}
  func showPreview(gameFrame: NSRect) {}
  func show(rows: [LobbyRatingRow], summary: LobbyAverageSummary?, gameFrame: NSRect?) {}
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

do {
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
