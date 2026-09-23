import Foundation

enum LobbyLeaderboardError: Error { case unsupportedRegion, invalidResponse, incompleteSnapshot, retryAfter(Date) }

final class LobbyLeaderboardStore: @unchecked Sendable {
  private typealias Completion = (Result<LeaderboardSnapshot, Error>) -> Void

  var onSnapshotInvalidated: ((String) -> Void)?
  private let session: URLSession
  private let cacheDirectory: URL?
  private let failureRetryDelay: TimeInterval
  private let queue = DispatchQueue(label: "HSReconnect.Leaderboard")
  private var activeTask: Task<Void, Never>?
  private var activeRegion: String?
  private var pendingCompletions: [String: [Completion]] = [:]
  private var pendingRegions: [String] = []
  private var retryWorkItem: DispatchWorkItem?
  private var lastRefresh: [String: Date] = [:]
  private var retryNotBefore: [String: Date] = [:]
  private var generation = LobbyCallbackGeneration()

  init(session: URLSession = .shared, cacheDirectory: URL? = nil,
       failureRetryDelay: TimeInterval = 60) {
    self.session = session
    self.cacheDirectory = cacheDirectory
    self.failureRetryDelay = failureRetryDelay
  }

  func cached(region: String, now: Date = Date()) -> LeaderboardSnapshot? {
    guard let data = try? Data(contentsOf: cacheURL(region: region)),
          let value = try? Self.makeDecoder().decode(LeaderboardSnapshot.self, from: data),
          value.isUsable(at: now, expectedRegion: region) else { return nil }
    return value
  }

  func refreshIfNeeded(region: String, completion: @escaping (Result<LeaderboardSnapshot, Error>) -> Void) {
    queue.async { [weak self] in
      guard let self else { return }
      if self.pendingCompletions[region] == nil { self.pendingRegions.append(region) }
      self.pendingCompletions[region, default: []].append(completion)
      self.startNextIfPossible()
    }
  }

  func cancel() {
    queue.async {
      self.generation.cancel()
      self.retryWorkItem?.cancel()
      self.retryWorkItem = nil
      self.activeTask?.cancel()
      self.activeTask = nil
      self.activeRegion = nil
      let completions = self.pendingCompletions.values.flatMap { $0 }
      self.pendingCompletions.removeAll()
      self.pendingRegions.removeAll()
      guard !completions.isEmpty else { return }
      DispatchQueue.main.async {
        completions.forEach { $0(.failure(CancellationError())) }
      }
    }
  }

  private func startNextIfPossible() {
    guard activeTask == nil, retryWorkItem == nil, !pendingRegions.isEmpty else { return }
    let now = Date()
    if let region = pendingRegions.first(where: { (retryNotBefore[$0] ?? .distantPast) <= now }) {
      start(region: region, now: now)
      return
    }
    guard let retry = pendingRegions.compactMap({ retryNotBefore[$0] }).min() else { return }
    let workItem = DispatchWorkItem { [weak self] in
      guard let self else { return }
      self.retryWorkItem = nil
      self.startNextIfPossible()
    }
    retryWorkItem = workItem
    queue.asyncAfter(deadline: .now() + max(retry.timeIntervalSince(now), 0), execute: workItem)
  }

  private func start(region: String, now: Date) {
    if let cached = cached(region: region),
       now.timeIntervalSince(max(lastRefresh[region] ?? .distantPast, cached.generatedAt)) < 900 {
      completePending(region: region, result: .success(cached))
      startNextIfPossible()
      return
    }
    activeRegion = region
    let generation = generation.begin()
    activeTask = Task { [weak self] in
      guard let self else { return }
      do {
        let snapshot = try await self.fetch(region: region)
        self.finish(generation: generation, region: region, result: .success(snapshot))
      } catch {
        self.finish(generation: generation, region: region, result: .failure(error))
      }
    }
  }

  private func finish(generation: Int, region: String,
                      result: Result<LeaderboardSnapshot, Error>) {
    queue.async {
      guard self.generation.accepts(generation), self.activeRegion == region else { return }
      self.activeTask = nil
      self.activeRegion = nil
      var deliveredResult = result
      switch deliveredResult {
      case .success(let snapshot):
        do { try self.save(snapshot) } catch {
          self.retryNotBefore[region] = Date().addingTimeInterval(self.failureRetryDelay)
          deliveredResult = .failure(error)
          break
        }
        self.lastRefresh[region] = Date(); self.retryNotBefore[region] = nil
      case .failure(let error):
        if error is CancellationError { break }
        if case LobbyLeaderboardError.retryAfter(let date) = error {
          self.retryNotBefore[region] = date
        } else {
          self.retryNotBefore[region] = Date().addingTimeInterval(self.failureRetryDelay)
        }
      }
      self.completePending(region: region, result: deliveredResult)
      self.startNextIfPossible()
    }
  }

  private func completePending(region: String, result: Result<LeaderboardSnapshot, Error>) {
    let completions = pendingCompletions.removeValue(forKey: region) ?? []
    pendingRegions.removeAll { $0 == region }
    guard !completions.isEmpty else { return }
    DispatchQueue.main.async { completions.forEach { $0(result) } }
  }

  private func fetch(region: String) async throws -> LeaderboardSnapshot {
    guard ["EU", "US", "AP"].contains(region) else { throw LobbyLeaderboardError.unsupportedRegion }
    let first = try await fetchPage(1, region: region)
    let metadata = try Self.metadata(first)
    if let data = try? Data(contentsOf: cacheURL(region: region)),
       let old = try? Self.makeDecoder().decode(LeaderboardSnapshot.self, from: data),
       old.seasonID != metadata.season {
      try? FileManager.default.removeItem(at: cacheURL(region: region))
      await MainActor.run { self.onSnapshotInvalidated?(region) }
    }
    var pages = Array<Any?>(repeating: nil, count: metadata.pages)
    pages[0] = first
    try await withThrowingTaskGroup(of: (Int, Any).self) { group in
      var next = 2
      let initial = min(4, metadata.pages - 1)
      for _ in 0..<initial { let page = next; next += 1; group.addTask { (page, try await self.fetchPage(page, region: region)) } }
      while let (page, value) = try await group.next() {
        pages[page - 1] = value
        if next <= metadata.pages { let page = next; next += 1; group.addTask { (page, try await self.fetchPage(page, region: region)) } }
      }
    }
    return try LeaderboardPageValidator.snapshot(pages: pages.compactMap { $0 as? [String: Any] }, region: region, now: Date())
  }

  private func fetchPage(_ page: Int, region: String) async throws -> [String: Any] {
    var components = URLComponents(string: "https://hearthstone.blizzard.com/en-us/api/community/leaderboardsData")!
    components.queryItems = [URLQueryItem(name: "region", value: region),
      URLQueryItem(name: "leaderboardId", value: "battlegrounds"), URLQueryItem(name: "page", value: String(page))]
    var request = URLRequest(url: components.url!); request.timeoutInterval = 30
    request.setValue("HS-Reconnect/1.1", forHTTPHeaderField: "User-Agent")
    var delay: UInt64 = 1
    for attempt in 0...3 {
      do {
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw LobbyLeaderboardError.invalidResponse }
        if http.statusCode == 429 || (500...599).contains(http.statusCode)
            && http.value(forHTTPHeaderField: "Retry-After") != nil {
          let now = Date(); let retryDate = RetryAfterPolicy.date(header: http.value(forHTTPHeaderField: "Retry-After"), now: now)
            ?? now.addingTimeInterval(TimeInterval(delay))
          if attempt == 3 { throw LobbyLeaderboardError.retryAfter(retryDate) }
          let wait = retryDate.timeIntervalSince(now)
          if wait > 60 { throw LobbyLeaderboardError.retryAfter(retryDate) }
          try await Task.sleep(nanoseconds: UInt64(max(wait, 0) * 1_000_000_000)); delay *= 2; continue
        }
        if (500...599).contains(http.statusCode) {
          if attempt == 3 { throw LobbyLeaderboardError.invalidResponse }
          try await Task.sleep(nanoseconds: delay * 1_000_000_000); delay *= 2; continue
        }
        guard http.statusCode == 200,
              let value = try JSONSerialization.jsonObject(with: data) as? [String: Any] else { throw LobbyLeaderboardError.invalidResponse }
        return value
      } catch {
        if case LobbyLeaderboardError.retryAfter = error { throw error }
        if attempt == 3 || Task.isCancelled { throw error }
        try await Task.sleep(nanoseconds: delay * 1_000_000_000); delay *= 2
      }
    }
    throw LobbyLeaderboardError.invalidResponse
  }

  private struct Metadata: Equatable { let season: Int; let pages: Int; let size: Int }
  private static func metadata(_ object: [String: Any]) throws -> Metadata {
    guard let season = integer(object["seasonId"]), let board = object["leaderboard"] as? [String: Any],
          let pagination = board["pagination"] as? [String: Any], let pages = integer(pagination["totalPages"]),
          let size = integer(pagination["totalSize"]), season > 0, pages > 0, size > 0 else { throw LobbyLeaderboardError.invalidResponse }
    return Metadata(season: season, pages: pages, size: size)
  }
  private static func integer(_ value: Any?) -> Int? {
    if let value = value as? Int { return value }; if let value = value as? NSNumber { return value.intValue }
    if let value = value as? String { return Int(value) }; return nil
  }
  private func cacheURL(region: String) -> URL {
    let base = cacheDirectory ?? FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
      .appendingPathComponent(AppConfiguration.bundleIdentifier, isDirectory: true)
    try? FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
    return base.appendingPathComponent("leaderboard-\(region)-battlegrounds.json")
  }
  private func save(_ value: LeaderboardSnapshot) throws {
    let data = try Self.makeEncoder().encode(value); let url = cacheURL(region: value.region)
    try data.write(to: url, options: .atomic)
  }

  private static func makeDecoder() -> JSONDecoder {
    let decoder = JSONDecoder()
    decoder.dateDecodingStrategy = .iso8601
    return decoder
  }

  private static func makeEncoder() -> JSONEncoder {
    let encoder = JSONEncoder()
    encoder.dateEncodingStrategy = .iso8601
    encoder.outputFormatting = [.sortedKeys]
    return encoder
  }
}
