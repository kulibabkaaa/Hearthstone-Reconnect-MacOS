import AppKit
import Foundation
import OSLog

enum GameEndpointResolverError: Error {
  case appNotRunning
  case multipleInstances
  case invalidInstallation
}

struct GameEndpointResolver {
  private static let executableSuffix =
    "/Hearthstone.app/Contents/MacOS/Hearthstone"
  private static let maximumLogBytes: UInt64 = 2 * 1024 * 1024
  private static let logger = Logger(subsystem: AppConfiguration.bundleIdentifier, category: "ReconnectTarget")

  /// Which game connection to close. Reads Hearthstone's logs and its sockets: call off the main thread.
  func reconnectChoice() throws -> ReconnectTargetChoice {
    let game = try runningGame()
    let directory = latestLogDirectory(in: game.logsRoot)
    let logged = directory.map(loggedEndpoints(in:)) ?? []
    let open = HearthstoneConnections.openTCPRemoteEndpoints(pid: game.pid)
    let choice = ReconnectTargetChooser.choose(logged: logged, openConnections: open)
    // The kind of choice and counts only, never addresses.
    Self.logger.notice(
      "choice=\(choice.logName, privacy: .public) logged=\(logged.count, privacy: .public) open=\(open?.count ?? -1, privacy: .public)"
    )
    return choice
  }

  /// The running game's current `Hearthstone_<date>` log folder, or nil when there is none to be sure of.
  func currentLogDirectory() -> URL? {
    (try? runningGame()).flatMap { latestLogDirectory(in: $0.logsRoot) }
  }

  private func runningGame() throws -> (pid: pid_t, logsRoot: URL) {
    let applications = NSRunningApplication.runningApplications(
      withBundleIdentifier:
        ProxyConstants.hearthstoneSigningIdentifier
    ).filter {
      !$0.isTerminated && $0.processIdentifier > 0
    }

    guard !applications.isEmpty else {
      throw GameEndpointResolverError.appNotRunning
    }
    guard applications.count == 1 else {
      throw GameEndpointResolverError.multipleInstances
    }
    guard
      let executableURL = applications[0].executableURL,
      executableURL.standardizedFileURL.path.hasSuffix(
        Self.executableSuffix
      )
    else {
      throw GameEndpointResolverError.invalidInstallation
    }

    let appBundle =
      executableURL
      .deletingLastPathComponent()
      .deletingLastPathComponent()
      .deletingLastPathComponent()
    let logsRoot =
      appBundle
      .deletingLastPathComponent()
      .appendingPathComponent("Logs", isDirectory: true)
    return (applications[0].processIdentifier, logsRoot)
  }

  /// Logged game addresses from both logs, GameNetLogger.log's first, each newest first and listed once.
  /// The two files don't always mirror each other, so both are read.
  private func loggedEndpoints(in directory: URL) -> [GameEndpoint] {
    var endpoints: [GameEndpoint] = []
    for name in ["GameNetLogger.log", "Hearthstone.log"] {
      guard let text = try? readTail(of: directory.appendingPathComponent(name)) else { continue }
      for endpoint in GameLogEndpointParser.recentEndpoints(in: text) where !endpoints.contains(endpoint) {
        endpoints.append(endpoint)
      }
    }
    return endpoints
  }

  private func latestLogDirectory(in root: URL) -> URL? {
    let keys: Set<URLResourceKey> = [
      .contentModificationDateKey,
      .isDirectoryKey,
    ]
    guard
      let candidates = try? FileManager.default.contentsOfDirectory(
        at: root,
        includingPropertiesForKeys: Array(keys),
        options: [.skipsHiddenFiles]
      )
    else {
      return nil
    }

    return
      candidates
      .filter {
        guard $0.lastPathComponent.hasPrefix("Hearthstone_") else {
          return false
        }
        return
          (try? $0.resourceValues(forKeys: keys).isDirectory)
          == true
      }
      .max {
        let left =
          (try? $0.resourceValues(forKeys: keys).contentModificationDate)
          ?? .distantPast
        let right =
          (try? $1.resourceValues(forKeys: keys).contentModificationDate)
          ?? .distantPast
        return left < right
      }
  }

  private func readTail(of file: URL) throws -> String {
    let handle = try FileHandle(forReadingFrom: file)
    defer { try? handle.close() }
    let length = try handle.seekToEnd()
    let start =
      length > Self.maximumLogBytes
      ? length - Self.maximumLogBytes
      : 0
    try handle.seek(toOffset: start)
    let data = try handle.readToEnd() ?? Data()
    return String(decoding: data, as: UTF8.self)
  }
}
