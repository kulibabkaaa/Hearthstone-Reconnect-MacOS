import Foundation

/// Log categories that may appear in a bug report's diagnostics. Raw values are the os_log category names.
public enum DiagnosticLogCategory: String, CaseIterable, Sendable {
  case reconnectTarget = "ReconnectTarget"
  case trackerRecovery = "TrackerRecovery"
  case loginItem = "LoginItem"
  case analytics = "Analytics"
}

public enum DiagnosticLogLevel: String, Sendable {
  case notice
  case error
}

/// One line per entry: `<ISO 8601 time with ms>\t<category>\t<level>\t<message>\n`. Messages are redacted and
/// flattened to a single line before they are written, so nothing personal is ever stored.
public enum DiagnosticLogFormat {
  public static func line(
    date: Date,
    category: DiagnosticLogCategory,
    level: DiagnosticLogLevel,
    message: String
  ) -> String {
    "\(date.formatted(timeStyle))\t\(category.rawValue)\t\(level.rawValue)\t\(clean(message))\n"
  }

  /// The message exactly as it is stored and sent to os_log: one line, redacted, length-capped.
  public static func clean(_ message: String) -> String {
    let flat = message.components(separatedBy: .newlines).joined(separator: " ")
      .replacingOccurrences(of: "\t", with: " ")
    return BugReportDiagnostics.cleanLine(flat)
  }

  /// Entries from a file's text. Malformed lines, unknown categories and a last line without its newline (one
  /// cut short by a crash, wherever the cut fell) are skipped.
  public static func parse(_ text: String) -> [BugReportAppLogEntry] {
    var lines = text.split(separator: "\n", omittingEmptySubsequences: false)
    lines.removeLast()  // Empty when the text ends with a newline, otherwise an unfinished line.
    return lines.compactMap { line in
      let fields = line.split(separator: "\t", maxSplits: 3, omittingEmptySubsequences: false)
      guard
        fields.count == 4,
        let date = try? Date(String(fields[0]), strategy: timeStyle),
        DiagnosticLogCategory(rawValue: String(fields[1])) != nil,
        DiagnosticLogLevel(rawValue: String(fields[2])) != nil
      else {
        return nil
      }
      return BugReportAppLogEntry(
        date: date,
        category: String(fields[1]),
        level: String(fields[2]),
        message: String(fields[3])
      )
    }
  }

  /// The lines of `text` that are well formed and no older than `retention`, re-serialised.
  public static func retained(_ text: String, now: Date, retention: TimeInterval) -> String {
    let earliest = now.addingTimeInterval(-retention)
    return parse(text)
      .filter { $0.date >= earliest }
      .compactMap { entry -> String? in
        guard
          let category = DiagnosticLogCategory(rawValue: entry.category),
          let level = DiagnosticLogLevel(rawValue: entry.level)
        else { return nil }
        return line(date: entry.date, category: category, level: level, message: entry.message)
      }
      .joined()
  }

  private static let timeStyle = Date.ISO8601FormatStyle(includingFractionalSeconds: true)
}

/// HS Reconnect's own small diagnostics log on disk, so a bug report can include what happened before the last
/// restart. Two files of at most `maximumFileBytes` each (current + previous); lines older than `retention`
/// are dropped when the store opens and are never read back.
///
/// `@unchecked Sendable` is safe here: every mutable property is only touched on `queue`, a serial queue.
public final class DiagnosticLogStore: @unchecked Sendable {
  public static let maximumFileBytes = 256 * 1_024
  public static let retention: TimeInterval = 3 * 24 * 60 * 60
  public static let currentFileName = "diagnostics.log"
  public static let previousFileName = "diagnostics.1.log"

  public let directory: URL
  private let now: @Sendable () -> Date
  private let queue = DispatchQueue(label: "io.github.kulibabkaaa.HSReconnect.DiagnosticLog", qos: .utility)
  private var handle: FileHandle?
  private var currentSize = 0
  private var isPrepared = false
  private var isBroken = false

  private var currentURL: URL { directory.appendingPathComponent(Self.currentFileName) }
  private var previousURL: URL { directory.appendingPathComponent(Self.previousFileName) }

  public init(directory: URL, now: @escaping @Sendable () -> Date = { Date() }) {
    self.directory = directory
    self.now = now
  }

  deinit {
    try? handle?.close()
  }

  /// Drops old lines in the background. Logging also does this on first use.
  public func prepare() {
    queue.async { self.prepareIfNeeded() }
  }

  /// Appends one entry in the background. The message is redacted before it reaches the disk.
  public func append(_ category: DiagnosticLogCategory, _ level: DiagnosticLogLevel, _ message: String) {
    let date = now()
    queue.async {
      self.write(DiagnosticLogFormat.line(date: date, category: category, level: level, message: message))
    }
  }

  /// Everything still kept, oldest first. Waits for earlier appends; call it off the main thread.
  public func entries() -> [BugReportAppLogEntry] {
    queue.sync {
      prepareIfNeeded()
      let earliest = now().addingTimeInterval(-Self.retention)
      return [previousURL, currentURL]
        .compactMap { try? Data(contentsOf: $0) }
        .map { String(decoding: $0, as: UTF8.self) }
        .flatMap(DiagnosticLogFormat.parse)
        .filter { $0.date >= earliest }
    }
  }

  // MARK: - Queue only

  private func prepareIfNeeded() {
    guard !isPrepared else { return }
    isPrepared = true
    let fileManager = FileManager.default
    do {
      try fileManager.createDirectory(
        at: directory,
        withIntermediateDirectories: true,
        attributes: [.posixPermissions: 0o700]
      )
      let currentTime = now()
      for url in [previousURL, currentURL] where fileManager.fileExists(atPath: url.path) {
        // Lenient decoding: one damaged byte must not cost the whole file.
        let text = (try? Data(contentsOf: url)).map { String(decoding: $0, as: UTF8.self) } ?? ""
        let kept = DiagnosticLogFormat.retained(text, now: currentTime, retention: Self.retention)
        // Untouched unless something was trimmed: another running copy may have this file open.
        guard kept != text else { continue }
        if kept.isEmpty {
          try? fileManager.removeItem(at: url)
        } else {
          // Also repairs a last line left unfinished by a crash.
          try Data(kept.utf8).write(to: url, options: .atomic)
        }
      }
      try openCurrentFile()
    } catch {
      isBroken = true
    }
  }

  private func openCurrentFile() throws {
    // Append mode, so two running copies of the app (say a Debug build next to the installed one) add lines
    // after each other instead of writing over each other.
    let descriptor = open(currentURL.path, O_WRONLY | O_APPEND | O_CREAT | O_CLOEXEC, 0o600)
    guard descriptor >= 0 else {
      throw CocoaError(.fileWriteUnknown)
    }
    let fileHandle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
    currentSize = Int(try fileHandle.seekToEnd())
    handle = fileHandle
  }

  private func write(_ line: String) {
    prepareIfNeeded()
    guard !isBroken else { return }
    let data = Data(line.utf8)
    do {
      if currentSize > 0, currentSize + data.count > Self.maximumFileBytes {
        try rotate()
      }
      // One write per complete line: a crash can at worst leave one unfinished last line, which is never read
      // and is removed the next time the store opens.
      try handle?.write(contentsOf: data)
      currentSize += data.count
    } catch {
      isBroken = true
      try? handle?.close()
      handle = nil
    }
  }

  private func rotate() throws {
    try handle?.close()
    handle = nil
    let fileManager = FileManager.default
    try? fileManager.removeItem(at: previousURL)
    try fileManager.moveItem(at: currentURL, to: previousURL)
    try openCurrentFile()
  }
}
