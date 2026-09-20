import Foundation
import CoreGraphics

public enum HotKeyActionID: UInt32, Sendable {
  case reconnect = 1
  case lobbyLayout = 2
}

public enum LobbyOverlayEditCommand: Equatable, Sendable {
  case previewThenBegin
  case save

  public static func next(isEditing: Bool) -> Self {
    isEditing ? .save : .previewThenBegin
  }
}

public struct LobbyCallbackGeneration: Equatable, Sendable {
  public private(set) var value = 0
  public init() {}
  public mutating func begin() -> Int { value += 1; return value }
  public mutating func cancel() { value += 1 }
  public func accepts(_ candidate: Int) -> Bool { candidate == value }
}

public struct LobbyLifecycleState: Equatable, Sendable {
  public private(set) var activeUUID: String?
  public private(set) var generation = 0
  public init() {}
  @discardableResult public mutating func activate(_ uuid: String) -> Bool {
    guard activeUUID != uuid else { return false }
    activeUUID = uuid; generation += 1; return true
  }
  public mutating func deactivate() { activeUUID = nil; generation += 1 }
  public mutating func handleMenuTick(isEditingPreview: Bool, hasGameWindow: Bool) -> Bool {
    if activeUUID == nil && isEditingPreview && hasGameWindow { return true }
    deactivate()
    return false
  }
  public func accepts(uuid: String, generation candidate: Int) -> Bool {
    activeUUID == uuid && generation == candidate
  }
}

public struct LobbyAccountID: Codable, Hashable, Sendable {
  public let high: Int64
  public let low: Int64
  public init(high: Int64, low: Int64) { self.high = high; self.low = low }
}

public struct LobbyPlayer: Codable, Equatable, Sendable {
  public let position: Int
  public let accountID: LobbyAccountID
  public let name: String
  public init(position: Int, accountID: LobbyAccountID, name: String) {
    self.position = position; self.accountID = accountID; self.name = name
  }
}

public struct LeaderboardPlayer: Codable, Equatable, Sendable {
  public let name: String
  public let rating: Int
  public let rank: Int
  public init(name: String, rating: Int, rank: Int) {
    self.name = name; self.rating = rating; self.rank = rank
  }
}

public struct LeaderboardSnapshot: Codable, Equatable, Sendable {
  public let schemaVersion: Int
  public let seasonID: Int
  public let region: String
  public let mode: String
  public let generatedAt: Date
  public let cutoffRating: Int
  public let players: [LeaderboardPlayer]

  enum CodingKeys: String, CodingKey {
    case schemaVersion, region, mode, generatedAt, cutoffRating, players
    case seasonID = "seasonId"
  }

  public init(schemaVersion: Int = 1, seasonID: Int, region: String,
              mode: String = "battlegrounds", generatedAt: Date,
              cutoffRating: Int = 8000, players: [LeaderboardPlayer]) {
    self.schemaVersion = schemaVersion; self.seasonID = seasonID
    self.region = region; self.mode = mode; self.generatedAt = generatedAt
    self.cutoffRating = cutoffRating; self.players = players
  }

  public func isUsable(at date: Date, expectedRegion: String,
                       maximumAge: TimeInterval = 86_400) -> Bool {
    let age = date.timeIntervalSince(generatedAt)
    let validRegions = ["EU", "US", "AP"]
    return schemaVersion == 1 && seasonID > 0 && validRegions.contains(region)
      && region == expectedRegion && mode == "battlegrounds"
      && cutoffRating == 8000 && age >= -300 && age <= maximumAge
      && !players.isEmpty
      && players.allSatisfy { !$0.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        && $0.rating >= cutoffRating && $0.rank > 0 }
  }
}

public enum LeaderboardValidationError: Error { case invalidMetadata, mixedMetadata, invalidRow, incomplete }

public enum LeaderboardPageValidator {
  public static func snapshot(pages: [[String: Any]], region: String, now: Date) throws -> LeaderboardSnapshot {
    guard let first = pages.first else { throw LeaderboardValidationError.invalidMetadata }
    let expected = try metadata(first)
    guard pages.count == expected.pages else { throw LeaderboardValidationError.incomplete }
    var players: [LeaderboardPlayer] = []; var ranks = Set<Int>(); var rowCount = 0
    for page in pages {
      guard try metadata(page) == expected,
            let board = page["leaderboard"] as? [String: Any],
            let rows = board["rows"] as? [[String: Any]] else { throw LeaderboardValidationError.mixedMetadata }
      for row in rows {
        guard let rank = integer(row["rank"]), let rating = integer(row["rating"]),
              rank > 0, rank <= expected.size, rating >= 8000, ranks.insert(rank).inserted else {
          throw LeaderboardValidationError.invalidRow
        }
        rowCount += 1
        let name = (row["accountid"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if !name.isEmpty { players.append(LeaderboardPlayer(name: name, rating: rating, rank: rank)) }
      }
    }
    guard rowCount == expected.size && ranks.count == expected.size else { throw LeaderboardValidationError.incomplete }
    return LeaderboardSnapshot(seasonID: expected.season, region: region, generatedAt: now,
      players: players.sorted { $0.rank < $1.rank })
  }
  private struct Metadata: Equatable { let season: Int; let pages: Int; let size: Int }
  private static func metadata(_ object: [String: Any]) throws -> Metadata {
    guard let season = integer(object["seasonId"]), let board = object["leaderboard"] as? [String: Any],
          let pagination = board["pagination"] as? [String: Any], let pages = integer(pagination["totalPages"]),
          let size = integer(pagination["totalSize"]), season > 0, pages > 0, size > 0 else {
      throw LeaderboardValidationError.invalidMetadata
    }
    return Metadata(season: season, pages: pages, size: size)
  }
  private static func integer(_ value: Any?) -> Int? {
    if let x = value as? Int { return x }; if let x = value as? NSNumber { return x.intValue }
    if let x = value as? String { return Int(x) }; return nil
  }
}

public enum RetryAfterPolicy {
  public static func date(header: String?, now: Date) -> Date? {
    guard let header else { return nil }
    if let seconds = TimeInterval(header.trimmingCharacters(in: .whitespaces)), seconds >= 0 {
      return now.addingTimeInterval(seconds)
    }
    let formatter = DateFormatter(); formatter.locale = Locale(identifier: "en_US_POSIX")
    formatter.timeZone = TimeZone(secondsFromGMT: 0); formatter.dateFormat = "EEE',' dd MMM yyyy HH':'mm':'ss z"
    return formatter.date(from: header)
  }
}

public enum LobbyRating: Equatable, Sendable {
  case exact(Int)
  case belowCutoff(Int)
  case unavailable
}

public struct LobbyRatingRow: Equatable, Sendable {
  public let position: Int
  public let name: String
  public let rating: LobbyRating
  public let rank: Int?
  public let isLocalPlayer: Bool
}

public enum LobbyRatingResolver {
  public static func displayName(_ name: String) -> String {
    var result = name.trimmingCharacters(in: .whitespacesAndNewlines)
    if let hash = result.lastIndex(of: "#") {
      let suffix = result[result.index(after: hash)...]
      if !suffix.isEmpty && suffix.allSatisfy(\.isNumber) { result = String(result[..<hash]) }
    }
    return result
  }

  public static func normalizedName(_ name: String) -> String {
    displayName(name).precomposedStringWithCanonicalMapping
      .folding(options: [.caseInsensitive], locale: Locale(identifier: "en_US_POSIX"))
  }

  public static func resolve(players: [LobbyPlayer], ownAccountID: LobbyAccountID?,
                             ownBattleTag: String?, ownRating: Int?,
                             snapshot: LeaderboardSnapshot?, now: Date,
                             region: String) -> [LobbyRatingRow] {
    let valid = snapshot?.isUsable(at: now, expectedRegion: region) == true ? snapshot : nil
    var byName: [String: LeaderboardPlayer] = [:]
    for player in valid?.players ?? [] {
      let key = normalizedName(player.name)
      if let current = byName[key], current.rating > player.rating
        || current.rating == player.rating && current.rank <= player.rank { continue }
      byName[key] = player
    }
    var seen = Set<LobbyAccountID>()
    let ownName = ownBattleTag.map(normalizedName)
    return players.compactMap { player -> LobbyRatingRow? in
      let display = displayName(player.name)
      guard !display.isEmpty, seen.insert(player.accountID).inserted else { return nil }
      let key = normalizedName(display)
      let own = player.accountID == ownAccountID || (ownAccountID == nil && key == ownName)
      if own, let ownRating {
        return LobbyRatingRow(position: player.position, name: display,
          rating: .exact(ownRating), rank: byName[key]?.rank, isLocalPlayer: true)
      }
      if let valid {
        if let exact = byName[key] {
          return LobbyRatingRow(position: player.position, name: display,
            rating: .exact(exact.rating), rank: exact.rank, isLocalPlayer: own)
        }
        return LobbyRatingRow(position: player.position, name: display,
          rating: .belowCutoff(valid.cutoffRating), rank: nil, isLocalPlayer: own)
      }
      return LobbyRatingRow(position: player.position, name: display,
        rating: .unavailable, rank: nil, isLocalPlayer: own)
    }.sorted {
      func value(_ rating: LobbyRating) -> Int? {
        switch rating { case .exact(let x): return x; case .belowCutoff(let x): return x - 1; case .unavailable: return nil }
      }
      let lv = value($0.rating), rv = value($1.rating)
      if lv != rv { return (lv ?? Int.min) > (rv ?? Int.min) }
      return $0.position < $1.position
    }
  }
}

public struct LobbyAverageSummary: Equatable, Sendable {
  public let average: Int
  public let difference: Int
}

public struct LobbyAverageEstimator: Sendable {
  public static let estimateRange = 7500...7999
  public static let minimumUsableRatings = 7
  private var estimates: [Int: Int] = [:]
  public init() {}
  public mutating func reset() { estimates.removeAll() }
  public mutating func summary(rows: [LobbyRatingRow], estimate: () -> Int = {
    Int.random(in: LobbyAverageEstimator.estimateRange)
  }) -> LobbyAverageSummary? {
    guard let own = rows.first(where: \.isLocalPlayer), case .exact(let ownRating) = own.rating else { return nil }
    let values = rows.compactMap { row -> Int? in
      switch row.rating {
      case .exact(let value): return value
      case .belowCutoff:
        if let value = estimates[row.position] { return value }
        let value = min(max(estimate(), Self.estimateRange.lowerBound), Self.estimateRange.upperBound)
        estimates[row.position] = value; return value
      case .unavailable: return nil
      }
    }
    guard values.count >= Self.minimumUsableRatings else { return nil }
    let average = Int((Double(values.reduce(0, +)) / Double(values.count)).rounded())
    return LobbyAverageSummary(average: average, difference: ownRating - average)
  }
}

public enum LobbyOverlayGeometry {
  public static let scaleRange: ClosedRange<Double> = 0.75...1.5
  public static func clampScale(_ value: Double) -> Double {
    min(max(value.isFinite ? value : 1, scaleRange.lowerBound), scaleRange.upperBound)
  }
  public static func reachableFrame(_ frame: CGRect, in screen: CGRect) -> CGRect {
    var result = frame
    let strip: CGFloat = 32
    result.origin.x = min(max(frame.minX, screen.minX - frame.width + strip), screen.maxX - strip)
    result.origin.y = min(max(frame.minY, screen.minY - frame.height + strip), screen.maxY - strip)
    return result
  }
  public static func snappedFrame(_ frame: CGRect, to target: CGRect, threshold: CGFloat = 10) -> CGRect {
    var result = frame
    let dx = [target.minX - frame.minX, target.maxX - frame.maxX].min(by: { abs($0) < abs($1) }) ?? 0
    let dy = [target.minY - frame.minY, target.maxY - frame.maxY].min(by: { abs($0) < abs($1) }) ?? 0
    if abs(dx) <= threshold { result.origin.x += dx }
    if abs(dy) <= threshold { result.origin.y += dy }
    return result
  }
  /// Bottom-right resize keeps the opposite (top-left) corner fixed.
  public static func resizedFrame(from frame: CGRect, delta: CGPoint, baseSize: CGSize) -> CGRect {
    let horizontal = delta.x / baseSize.width
    let vertical = -delta.y / baseSize.height
    let change = abs(horizontal) >= abs(vertical) ? horizontal : vertical
    let scale = clampScale(frame.width / baseSize.width + change)
    let size = CGSize(width: baseSize.width * scale, height: baseSize.height * scale)
    return CGRect(x: frame.minX, y: frame.maxY - size.height, width: size.width, height: size.height)
  }
  public static func normalizedOrigin(frame: CGRect, gameFrame: CGRect) -> CGPoint {
    guard gameFrame.width > 0, gameFrame.height > 0 else { return .zero }
    return CGPoint(x: (frame.minX - gameFrame.minX) / gameFrame.width,
                   y: (frame.minY - gameFrame.minY) / gameFrame.height)
  }
  public static func restoredFrame(origin: CGPoint, scale: Double, baseSize: CGSize,
                                   gameFrame: CGRect, visibleFrame: CGRect) -> CGRect {
    let safeScale = clampScale(scale)
    let size = CGSize(width: baseSize.width * safeScale, height: baseSize.height * safeScale)
    var result = CGRect(x: gameFrame.minX + origin.x * gameFrame.width,
                        y: gameFrame.minY + origin.y * gameFrame.height,
                        width: size.width, height: size.height)
    if result.width <= visibleFrame.width {
      result.origin.x = min(max(result.minX, visibleFrame.minX), visibleFrame.maxX - result.width)
    }
    if result.height <= visibleFrame.height {
      result.origin.y = min(max(result.minY, visibleFrame.minY), visibleFrame.maxY - result.height)
    }
    return result
  }
}
