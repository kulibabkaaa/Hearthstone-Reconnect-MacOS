import Foundation

public enum ProxyConstants {
  public static let hearthstoneSigningIdentifier =
    "unity.Blizzard Entertainment.Hearthstone"
  public static let gamePort: UInt16 = 3724
  public static let cooldownSeconds: TimeInterval = 5
}

public struct FlowDescriptor: Equatable, Sendable {
  public let sourceSigningIdentifier: String
  public let remoteHost: String
  public let remotePort: UInt16

  public init(
    sourceSigningIdentifier: String,
    remoteHost: String,
    remotePort: UInt16
  ) {
    self.sourceSigningIdentifier = sourceSigningIdentifier
    self.remoteHost = remoteHost
    self.remotePort = remotePort
  }
}

public struct HearthstoneFlowMatcher: Sendable {
  public init() {}

  public func matches(_ descriptor: FlowDescriptor) -> Bool {
    descriptor.sourceSigningIdentifier
      == ProxyConstants.hearthstoneSigningIdentifier
  }
}

public struct GameEndpoint: Codable, Equatable, Sendable {
  public let host: String
  public let port: UInt16

  public init(host: String, port: UInt16) {
    self.host = host
    self.port = port
  }
}

public enum ReconnectTarget: Codable, Equatable, Sendable {
  case exact(GameEndpoint)
  case uniquePort(UInt16)
}

public enum ProviderCommand: Codable, Equatable, Sendable {
  case reconnect(target: ReconnectTarget)

  public static func decode(_ data: Data) -> ProviderCommand? {
    try? JSONDecoder().decode(ProviderCommand.self, from: data)
  }

  public var encoded: Data {
    (try? JSONEncoder().encode(self)) ?? Data()
  }
}

public enum ReconnectTargetSelector {
  public static func indices(
    in flows: [FlowDescriptor],
    target: ReconnectTarget
  ) -> [Int] {
    let matcher = HearthstoneFlowMatcher()
    let matching: [Int]

    switch target {
    case .exact(let endpoint):
      matching = flows.indices.filter {
        matcher.matches(flows[$0])
          && flows[$0].remoteHost == endpoint.host
          && flows[$0].remotePort == endpoint.port
      }
    case .uniquePort(let port):
      matching = flows.indices.filter {
        matcher.matches(flows[$0])
          && flows[$0].remotePort == port
      }
    }

    return matching.count == 1 ? matching : []
  }
}

public enum GameLogEndpointParser {
  private static let marker =
    "Network.GotoGameServe() - address="

  public static func latestEndpoint(
    in text: String
  ) -> GameEndpoint? {
    for line in text.split(whereSeparator: \.isNewline).reversed() {
      if let endpoint = endpoint(inLine: line) { return endpoint }
    }
    return nil
  }

  /// Every valid logged game endpoint, newest first, each listed once.
  public static func recentEndpoints(
    in text: String
  ) -> [GameEndpoint] {
    var endpoints: [GameEndpoint] = []
    for line in text.split(whereSeparator: \.isNewline).reversed() {
      guard let endpoint = endpoint(inLine: line), !endpoints.contains(endpoint) else { continue }
      endpoints.append(endpoint)
    }
    return endpoints
  }

  private static func endpoint(inLine line: Substring) -> GameEndpoint? {
    guard let range = line.range(of: marker) else { return nil }
    let value = line[range.upperBound...]
      .trimmingCharacters(in: .whitespacesAndNewlines)
    guard let address = value.split(
      separator: ",",
      maxSplits: 1,
      omittingEmptySubsequences: false
    ).first else {
      return nil
    }
    let parts = address.split(
      separator: ":",
      maxSplits: 1,
      omittingEmptySubsequences: false
    )
    guard
      parts.count == 2,
      isPublicIPv4(String(parts[0])),
      let port = UInt16(parts[1]),
      port > 0
    else {
      return nil
    }
    return GameEndpoint(host: String(parts[0]), port: port)
  }

  static func isPublicIPv4(_ value: String) -> Bool {
    let pieces = value.split(
      separator: ".",
      omittingEmptySubsequences: false
    )
    guard pieces.count == 4 else { return false }
    let octets = pieces.compactMap { UInt8($0) }
    guard octets.count == pieces.count else { return false }

    let first = octets[0]
    let second = octets[1]
    if first == 0 || first == 10 || first == 127 || first >= 224 {
      return false
    }
    if first == 169, second == 254 {
      return false
    }
    if first == 172, (16...31).contains(second) {
      return false
    }
    if first == 192, second == 168 {
      return false
    }
    return true
  }
}

public struct ReconnectResponse: Codable, Equatable, Sendable {
  public let closedFlowCount: Int

  public init(closedFlowCount: Int) {
    self.closedFlowCount = closedFlowCount
  }

  public var didCloseFlow: Bool {
    closedFlowCount > 0
  }
}

public enum ReconnectCooldown {
  public static func remaining(
    lastReconnectAt: TimeInterval,
    now: TimeInterval,
    duration: TimeInterval = ProxyConstants.cooldownSeconds
  ) -> TimeInterval {
    max(0, lastReconnectAt + duration - now)
  }
}
