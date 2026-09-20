import AppKit

private struct CachedLobbyCapture: Codable {
  let savedAt: Date
  let capture: LobbyCapture
}

private final class LobbyResumeCache {
  private let defaults: UserDefaults
  init(defaults: UserDefaults = .standard) { self.defaults = defaults }
  func save(_ capture: LobbyCapture, now: Date = Date()) {
    guard hasCompleteRoster(capture) else { return }
    guard let data = try? JSONEncoder().encode(CachedLobbyCapture(savedAt: now, capture: capture)) else { return }
    defaults.set(data, forKey: DefaultsKey.lobbyResumeCapture)
  }
  func load(now: Date = Date()) -> LobbyCapture? {
    guard let data = defaults.data(forKey: DefaultsKey.lobbyResumeCapture),
          let value = try? JSONDecoder().decode(CachedLobbyCapture.self, from: data),
          LobbyResumeCachePolicy.isUsable(savedAt: value.savedAt, now: now,
            gameUUID: value.capture.gameUUID, mode: value.capture.mode,
            playerCount: value.capture.players.count,
            namedPlayerCount: value.capture.players.filter {
              !$0.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            }.count,
            distinctAccountCount: Set(value.capture.players.map(\.accountID)).count) else {
      clear()
      return nil
    }
    return value.capture
  }
  func clear() { defaults.removeObject(forKey: DefaultsKey.lobbyResumeCapture) }
  private func hasCompleteRoster(_ capture: LobbyCapture) -> Bool {
    LobbyResumeCachePolicy.isUsable(savedAt: Date(), now: Date(),
      gameUUID: capture.gameUUID, mode: capture.mode,
      playerCount: capture.players.count,
      namedPlayerCount: capture.players.filter {
        !$0.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
      }.count,
      distinctAccountCount: Set(capture.players.map(\.accountID)).count)
  }
}

enum LobbyCapturePublication {
  static func latestMatching(_ capture: LobbyCapture?, gameUUID: String,
                             region: String) -> LobbyCapture? {
    guard capture?.gameUUID == gameUUID, capture?.region == region else { return nil }
    return capture
  }
}

struct LobbyLeaderboardRequest: Equatable {
  let gameUUID: String
  let region: String
  let lifecycleGeneration: Int
}

final class LobbyLeaderboardRetryLoop {
  typealias Completion = (Result<LeaderboardSnapshot, Error>) -> Void
  typealias Refresh = (String, @escaping Completion) -> Void
  typealias ResultHandler = (LobbyLeaderboardRequest,
                             Result<LeaderboardSnapshot, Error>) -> Bool

  private let refresh: Refresh
  private var activeRequest: LobbyLeaderboardRequest?
  private var resultHandler: ResultHandler?

  init(refresh: @escaping Refresh) { self.refresh = refresh }

  func start(_ request: LobbyLeaderboardRequest,
             resultHandler: @escaping ResultHandler) {
    guard activeRequest != request else { return }
    activeRequest = request
    self.resultHandler = resultHandler
    perform(request)
  }

  func cancel() {
    activeRequest = nil
    resultHandler = nil
  }

  private func perform(_ request: LobbyLeaderboardRequest) {
    refresh(request.region) { [weak self] result in
      guard let self, self.activeRequest == request,
            let resultHandler = self.resultHandler else { return }
      let shouldRetry = resultHandler(request, result)
      guard self.activeRequest == request else { return }
      if shouldRetry { self.perform(request) }
      else { self.cancel() }
    }
  }
}

final class LobbyCoordinator {
  var onStatus: ((String) -> Void)?
  var onLobbyDisplayed: (() -> Void)?
  private let reader = LobbyReader()
  private let store = LobbyLeaderboardStore()
  private let overlay = LobbyOverlayController()
  private var lifecycle = LobbyLifecycleState()
  private var snapshot: LeaderboardSnapshot?
  private var lastCapture: LobbyCapture?
  private var lastReportedGameUUID: String?
  private var estimator = LobbyAverageEstimator()
  private var windowTimer: Timer?
  private let resumeCache = LobbyResumeCache()
  private var isRunning = false
  private lazy var leaderboardRetry = LobbyLeaderboardRetryLoop { [weak self] region, completion in
    guard let self else { completion(.failure(CancellationError())); return }
    self.store.refreshIfNeeded(region: region, completion: completion)
  }

  init() {
    overlay.onStatus = { [weak self] in self?.onStatus?($0) }
    reader.onStatus = { [weak self] text in
      guard let self, self.isRunning else { return }
      if text == "Waiting for Hearthstone" { self.suspend(status: text) }
      else { self.onStatus?(text) }
    }
    reader.onCapture = { [weak self] capture in
      guard let self, self.isRunning else { return }
      self.accept(capture)
    }
    reader.onReconnectDetected = { [weak self] in
      guard let self, self.isRunning else { return }
      self.restoreInterruptedMatch()
    }
    store.onSnapshotInvalidated = { [weak self] region in
      guard let self, self.isRunning, self.lastCapture?.region == region else { return }
      self.snapshot = nil
      if let capture = self.lastCapture { self.publish(capture) }
    }
  }
  func start() {
    isRunning = true
    _ = resumeCache.load()
    if enabled { reader.start() }
    guard windowTimer == nil else { return }
    let timer = Timer(timeInterval: 0.25, repeats: true) { [weak self] _ in
      guard let self else { return }
      self.overlay.updateGameWindow(frame: self.hearthstoneFrame())
    }
    RunLoop.main.add(timer, forMode: .common)
    windowTimer = timer
  }
  deinit { windowTimer?.invalidate() }
  func stop() {
    isRunning = false
    windowTimer?.invalidate(); windowTimer = nil
    reader.stop(); lifecycle.deactivate(); snapshot = nil; lastCapture = nil
    estimator.reset(); leaderboardRetry.cancel(); store.cancel(); overlay.close()
  }
  var enabled: Bool { UserDefaults.standard.bool(forKey: DefaultsKey.lobbyEnabled) }
  func setEnabled(_ value: Bool) {
    UserDefaults.standard.set(value, forKey: DefaultsKey.lobbyEnabled)
    if value { _ = resumeCache.load(); if isRunning { reader.start() } }
    else { deactivate(status: "Lobby info disabled"); reader.stop() }
  }
  func setOpacity(_ percent: Double) { overlay.opacityPercent = percent }
  func retrySetup() {
    guard enabled else { onStatus?("Enable lobby info first"); return }
    onStatus?("Retrying lobby setup…")
    reader.retrySetup()
  }
  func toggleEditing() {
    if LobbyOverlayEditCommand.next(isEditing: overlay.isEditing) == .save { overlay.toggleEditing(); return }
    guard enabled else { onStatus?("Enable lobby info to position the overlay"); return }
    guard let frame = hearthstoneFrame(includeOffscreen: true) else {
      overlay.cancelAndClose()
      onStatus?("Open Hearthstone to position the overlay")
      return
    }
    overlay.updateGameWindow(frame: frame)
    if lifecycle.activeUUID == nil {
      overlay.showPreview(gameFrame: frame)
    }
    overlay.toggleEditing()
  }
  func resetLayout() { overlay.resetLayout() }

  private func accept(_ capture: LobbyCapture) {
    guard enabled else { deactivate(status: "Lobby info disabled"); return }
    guard capture.gameUUID != nil else {
      if lifecycle.handleMenuTick(isEditingPreview: overlay.isEditing,
                                  hasGameWindow: hearthstoneFrame() != nil) {
        onStatus?("Positioning sample lobby overlay")
      } else {
        clearAfterLifecycleChange(status: "Waiting for a Solo match")
      }
      return
    }
    switch LobbyReconnectPolicy.liveCaptureDisposition(mode: capture.mode) {
    case .publish:
      break
    case .waitForMode:
      suspend(status: "Waiting for lobby details…")
      return
    case .unsupported:
      deactivate(status: "Lobby info supports Solo")
      return
    }
    lastCapture = capture
    resumeCache.save(capture)
    guard let uuid = capture.gameUUID else { return }
    if lifecycle.activate(uuid) {
      leaderboardRetry.cancel()
      estimator.reset()
      snapshot = store.cached(region: capture.region)
    }
    let generation = lifecycle.generation
    publish(capture)
    if lastReportedGameUUID != uuid {
      lastReportedGameUUID = uuid
      onLobbyDisplayed?()
    }
    guard ["EU", "US", "AP"].contains(capture.region) else { onStatus?("Ratings unavailable for this region"); return }
    onStatus?(snapshot == nil ? "Loading ratings…" : "Cached ratings")
    let region = capture.region
    let request = LobbyLeaderboardRequest(
      gameUUID: uuid, region: region, lifecycleGeneration: generation
    )
    leaderboardRetry.start(request) { [weak self] request, result in
      guard let self, self.isRunning,
            self.lifecycle.accepts(uuid: request.gameUUID,
                                   generation: request.lifecycleGeneration) else { return false }
      if case .success(let value) = result {
        guard let latest = LobbyCapturePublication.latestMatching(
          self.lastCapture, gameUUID: request.gameUUID, region: request.region
        ) else { return false }
        self.snapshot = value
        self.onStatus?("Lobby ratings ready")
        self.publish(latest)
        return false
      }
      if self.snapshot == nil { self.onStatus?("Current ratings unavailable; retrying…") }
      return true
    }
  }
  private func deactivate(status: String) {
    lifecycle.deactivate(); clearAfterLifecycleChange(status: status)
  }
  private func suspend(status: String) {
    lifecycle.deactivate(); snapshot = nil; lastCapture = nil; estimator.reset()
    leaderboardRetry.cancel(); store.cancel(); overlay.cancelAndClose(); onStatus?(status)
  }
  private func restoreInterruptedMatch() {
    guard enabled, let capture = resumeCache.load() else {
      onStatus?("Lobby names unavailable after reconnect")
      return
    }
    accept(capture)
    onStatus?("Lobby info restored")
  }
  private func clearAfterLifecycleChange(status: String) {
    snapshot = nil; lastCapture = nil; estimator.reset(); leaderboardRetry.cancel()
    store.cancel(); overlay.cancelAndClose()
    resumeCache.clear()
    onStatus?(status)
  }
  private func publish(_ capture: LobbyCapture) {
    let rows = LobbyRatingResolver.resolve(players: capture.players, ownAccountID: capture.ownAccountID,
      ownBattleTag: capture.ownBattleTag, ownRating: capture.ownRating, snapshot: snapshot,
      now: Date(), region: capture.region)
    let summary = estimator.summary(rows: rows)
    overlay.show(rows: rows, summary: summary, gameFrame: hearthstoneFrame())
  }
  private func windowArea(_ item: [String: Any]) -> CGFloat {
    guard let bounds = item[kCGWindowBounds as String] as? NSDictionary,
          let rect = CGRect(dictionaryRepresentation: bounds) else { return 0 }
    return rect.width * rect.height
  }
  private func hearthstoneFrame(includeOffscreen: Bool = false) -> NSRect? {
    guard let app = NSWorkspace.shared.runningApplications.first(where: { $0.bundleIdentifier == "unity.Blizzard Entertainment.Hearthstone" }) else { return nil }
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
}
