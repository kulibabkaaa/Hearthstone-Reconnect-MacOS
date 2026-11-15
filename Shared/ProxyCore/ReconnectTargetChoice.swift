import Foundation

/// How the app picked the game connection to close, and why.
///
/// Hearthstone usually logs the game server's address (`Network.GotoGameServe() - address=`) when a match starts, but
/// not always: a reporter's later matches had no such line, so the newest logged address belonged to an earlier match
/// and the reconnect closed nothing. So the logged addresses are checked against Hearthstone's open connections first.
public enum ReconnectTargetChoice: Equatable, Sendable {
  /// The newest logged game address, and Hearthstone has it open right now.
  case loggedAndOpen(GameEndpoint)
  /// The newest logged address isn't open, but of the two connections on the game port exactly one is in the same /24
  /// as a game server Hearthstone logged earlier, and the other isn't near it.
  case openGameConnection(GameEndpoint)
  /// Hearthstone's connections couldn't be read, or nothing better was found: the newest logged address, unchecked
  /// (what every version before this one sent).
  case loggedUnchecked(GameEndpoint)
  /// No address to try.
  case none

  public var endpoint: GameEndpoint? {
    switch self {
    case .loggedAndOpen(let endpoint), .openGameConnection(let endpoint), .loggedUnchecked(let endpoint): endpoint
    case .none: nil
    }
  }

  /// Short, address-free name for the local log.
  public var logName: String {
    switch self {
    case .loggedAndOpen: "loggedAndOpen"
    case .openGameConnection: "openGameConnection"
    case .loggedUnchecked: "loggedUnchecked"
    case .none: "none"
    }
  }
}

public enum ReconnectTargetChooser {
  /// Picks the game connection to close.
  ///
  /// - Parameters:
  ///   - logged: logged game addresses, newest first.
  ///   - openConnections: Hearthstone's open TCP connections; nil (or empty, which never happens in a running game)
  ///     when they couldn't be read.
  ///
  /// If the newest logged address is open, it's used (the old behaviour, now checked). Otherwise the current match's
  /// server is recognized by its network. During a match Hearthstone has exactly two connections on the game port: the
  /// game server and Battle.net's own. The pick must be the only one of the two that shares its first three address
  /// numbers with a game server logged this session (158.115.204.x for the reporter, 5.42.177.x for Illia), and the
  /// other must not share its first two (EU Battle.net 35.204.x sat next to a cloud game server).
  ///
  /// Battle.net can't be recognized by name (its host rotates addresses on almost every DNS lookup), so one gap
  /// remains: if Battle.net's address happens to share a /24 with a game server logged earlier in the session while
  /// the current match is in a different range, Battle.net is picked. That needs cloud game servers in the player's
  /// region and is roughly a 1-in-3,000 coincidence per such server; the reporter's region (Blizzard-owned game
  /// servers, cloud Battle.net) can't hit it.
  ///
  /// Whenever it can't be sure, it falls back to the newest logged address, unchecked (what every version before sent).
  public static func choose(
    logged: [GameEndpoint],
    openConnections: [GameEndpoint]?
  ) -> ReconnectTargetChoice {
    guard let newest = logged.first else { return .none }
    let unchecked = ReconnectTargetChoice.loggedUnchecked(newest)
    guard let openConnections, !openConnections.isEmpty else { return unchecked }

    if openConnections.contains(newest) {
      return .loggedAndOpen(newest)
    }

    let gameNetworks = Set(logged.compactMap { network(of: $0.host, octets: 3) })
    var onPort: [GameEndpoint] = []
    for endpoint in openConnections
    where endpoint.port == newest.port && GameLogEndpointParser.isPublicIPv4(endpoint.host) && !onPort.contains(endpoint)
    {
      onPort.append(endpoint)
    }
    // In a match: the game server and Battle.net. One alone is most likely Battle.net (menus); three or more is unclear.
    guard onPort.count == 2 else { return unchecked }
    let candidates = onPort.filter { network(of: $0.host, octets: 3).map(gameNetworks.contains) ?? false }
    guard candidates.count == 1, let pick = candidates.first else { return unchecked }
    // The other connection must not be near the pick: that could be Battle.net in the same cloud range.
    let other = onPort.first { $0 != pick }
    guard let other, network(of: other.host, octets: 2) != network(of: pick.host, octets: 2) else { return unchecked }
    return .openGameConnection(pick)
  }

  /// The first `octets` numbers of an IPv4 address ("158.115.204" for 158.115.204.233 with 3), or nil when it isn't one.
  static func network(of host: String, octets: Int) -> String? {
    let parts = host.split(separator: ".", omittingEmptySubsequences: false)
    guard parts.count == 4, parts.allSatisfy({ UInt8($0) != nil }) else { return nil }
    return parts.prefix(octets).joined(separator: ".")
  }
}
