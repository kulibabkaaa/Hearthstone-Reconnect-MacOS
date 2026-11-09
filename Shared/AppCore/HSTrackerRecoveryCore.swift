import Darwin
import Foundation

/// HSTracker 3.7.3 clears players on Gameplay.Start but skips gameStart for a
/// GAMEPLAY -> GAMEPLAY transition. A labelled log event invokes its existing
/// initializer after the replacement board has loaded. No tracker binary changes.
public enum HSTrackerRecoveryPolicy {
  public static func needsRecovery(version: String) -> Bool { version == "3.7.3" }
  public static let timeout: TimeInterval = 20

  public static func didRecoverPlayers(in text: String) -> Bool {
    text.split(whereSeparator: \.isNewline).contains { line in
      guard line.contains("Game.updatePlayers()") else { return false }
      let expression = try? NSRegularExpression(pattern: #"\[PlayerId=([1-9][0-9]*)\]"#)
      return expression?.numberOfMatches(in: String(line),
        range: NSRange(line.startIndex..., in: line)) == 2
    }
  }

  public static func event(at date: Date) -> String {
    let formatter = DateFormatter()
    formatter.locale = Locale(identifier: "en_US_POSIX")
    formatter.dateFormat = "HH:mm:ss.SSSSSSS"
    // HSTracker filters LoadingScreen.log by this prefix. The source field
    // labels the synthetic event; a custom prefix would be silently discarded.
    return "D \(formatter.string(from: date)) LoadingScreen.OnSceneLoaded() - "
      + "prevMode=INVALID currMode=GAMEPLAY source=HSReconnect.HSTrackerRecovery\n"
  }
}

public enum HSTrackerRecoveryState: Equatable {
  case waiting, ready, cancelled
}

public struct HSTrackerRecoveryObservation {
  public private(set) var state = HSTrackerRecoveryState.waiting
  private var started = false
  private var pastBegin = false

  public init() {}

  /// Only consume bytes written after this reconnect request. An old reconnect
  /// in the same session must never cause a recovery event for a later match.
  public mutating func observe(_ text: String) {
    guard state != .cancelled else { return }
    for line in text.split(whereSeparator: \.isNewline) {
      if line.contains("LoadingScreen.OnSceneLoaded()") {
        if line.contains("prevMode=GAMEPLAY currMode=GAMEPLAY") {
          if started && pastBegin { state = .ready }
        } else if line.contains("currMode=") {
          state = .cancelled
        }
      } else if line.contains("LoadingScreen.OnScenePreUnload()") {
        if !line.contains("prevMode=GAMEPLAY nextMode=GAMEPLAY") {
          state = .cancelled
        } else if started {
          // Another reload superseded the one we were waiting for.
          state = .cancelled
        }
      } else if line.contains("Gameplay.Start()") {
        if started { state = .cancelled }
        started = true
      } else if line.contains("MulliganManager.HandleGameStart()") {
        if line.contains("IsPastBeginPhase()=True") {
          if started { pastBegin = true }
        } else if line.contains("IsPastBeginPhase()=False") {
          state = .cancelled
        }
      }
      if state == .cancelled { return }
    }
  }
}

public enum HSTrackerRecoveryLogError: Error {
  case unavailable, replaced, truncated, excessiveOutput, incompleteLine, writeFailed
}

/// Captures an existing session's offset before the proxy request. Writes are
/// append-only, to the same regular file, and never create or truncate a log.
public final class HSTrackerRecoveryLog {
  private let url: URL
  private let handle: FileHandle
  private let device: dev_t
  private let inode: ino_t
  private var offset: UInt64
  private var pending = Data()

  public init(url: URL) throws {
    self.url = url
    let fd = open(url.path, O_RDONLY | O_NONBLOCK | O_NOFOLLOW | O_CLOEXEC)
    guard fd >= 0 else { throw HSTrackerRecoveryLogError.unavailable }
    let handle = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
    var info = stat()
    guard fstat(fd, &info) == 0, (info.st_mode & S_IFMT) == S_IFREG else {
      try? handle.close()
      throw HSTrackerRecoveryLogError.unavailable
    }
    self.handle = handle
    device = info.st_dev
    inode = info.st_ino
    offset = UInt64(info.st_size)
    try handle.seek(toOffset: offset)
  }

  deinit { try? handle.close() }

  /// Verification must use tracker messages produced after the recovery event,
  /// rather than a successful initialization logged before the board reload.
  public func discardPendingLines() throws {
    var info = stat()
    guard fstat(handle.fileDescriptor, &info) == 0, info.st_size >= 0 else {
      throw HSTrackerRecoveryLogError.unavailable
    }
    let end = UInt64(info.st_size)
    try handle.seek(toOffset: end)
    offset = end
    pending.removeAll()
  }

  public func readNewLines() throws -> String {
    var info = stat()
    guard fstat(handle.fileDescriptor, &info) == 0 else {
      throw HSTrackerRecoveryLogError.unavailable
    }
    guard info.st_size >= offset else { throw HSTrackerRecoveryLogError.truncated }
    let length = UInt64(info.st_size) - offset
    guard length + UInt64(pending.count) <= 256 * 1_024 else {
      throw HSTrackerRecoveryLogError.excessiveOutput
    }
    let data = try handle.read(upToCount: Int(length)) ?? Data()
    offset += UInt64(data.count)
    pending.append(data)
    guard let newline = pending.lastIndex(of: 0x0a) else { return "" }
    let complete = pending.prefix(through: newline)
    let text = String(decoding: complete, as: UTF8.self)
    pending.removeSubrange(...newline)
    return text
  }

  /// Returns false when Hearthstone wrote more bytes since the last read. The
  /// caller must observe those events first, in case the player left the match.
  public func appendRecoveryEvent(at date: Date) throws -> Bool {
    let fd = open(url.path, O_WRONLY | O_APPEND | O_NONBLOCK | O_NOFOLLOW | O_CLOEXEC)
    guard fd >= 0 else { throw HSTrackerRecoveryLogError.unavailable }
    defer { close(fd) }
    var info = stat()
    guard fstat(fd, &info) == 0, (info.st_mode & S_IFMT) == S_IFREG,
          info.st_dev == device, info.st_ino == inode else {
      throw HSTrackerRecoveryLogError.replaced
    }
    guard info.st_size >= offset else { throw HSTrackerRecoveryLogError.truncated }
    guard UInt64(info.st_size) == offset else { return false }
    guard pending.isEmpty else { throw HSTrackerRecoveryLogError.incompleteLine }
    let data = Data(HSTrackerRecoveryPolicy.event(at: date).utf8)
    let written = data.withUnsafeBytes { bytes in
      Darwin.write(fd, bytes.baseAddress, bytes.count)
    }
    guard written == data.count else { throw HSTrackerRecoveryLogError.writeFailed }
    return true
  }
}
