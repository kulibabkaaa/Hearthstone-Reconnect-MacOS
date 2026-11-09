import AppKit
import Foundation

enum GameEndpointResolverError: Error {
  case appNotRunning
  case multipleInstances
  case invalidInstallation
}

struct GameReconnectContext {
  let target: ReconnectTarget
  let application: NSRunningApplication
  let logDirectory: URL?
}

struct GameEndpointResolver {
  private static let executableSuffix =
    "/Hearthstone.app/Contents/MacOS/Hearthstone"
  private static let maximumLogBytes: UInt64 = 2 * 1024 * 1024

  func reconnectTarget() throws -> ReconnectTarget {
    try reconnectContext().target
  }

  func reconnectContext() throws -> GameReconnectContext {
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

    let directory = latestLogDirectory(in: logsRoot)
    let target: ReconnectTarget
    if let directory, let endpoint = latestEndpoint(in: directory) {
      target = .exact(endpoint)
    } else {
      target = .uniquePort(ProxyConstants.gamePort)
    }
    return GameReconnectContext(target: target, application: applications[0], logDirectory: directory)
  }

  private func latestEndpoint(in directory: URL) -> GameEndpoint? {
    for name in ["GameNetLogger.log", "Hearthstone.log"] {
      let file = directory.appendingPathComponent(name)
      guard let text = try? readTail(of: file) else {
        continue
      }
      if let endpoint = GameLogEndpointParser.latestEndpoint(in: text) {
        return endpoint
      }
    }
    return nil
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
