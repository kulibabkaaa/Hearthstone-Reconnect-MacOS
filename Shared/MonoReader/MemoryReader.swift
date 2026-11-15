import Foundation

/// Why a read of the game's memory could not produce an answer.
public enum MonoReaderError: Error, Equatable, CustomStringConvertible {
  /// The target's memory at this range could not be read (it moved, was freed, or the game quit).
  case readFailed(address: UInt64, count: Int)
  /// The game is still starting: Mono or the game's assemblies aren't there yet. Trying later can work.
  case notReady(String)
  /// This Mono build doesn't look like the one the reader understands. The reader must give no data at all
  /// rather than guess, so callers treat this as final for the running game.
  case unsupportedLayout(String)
  /// A class, field or symbol the caller asked for doesn't exist.
  case notFound(String)
  /// A value had the wrong type or an implausible size.
  case invalidData(String)
  /// macOS refused access to the game's memory.
  case accessDenied(Int32)

  public var description: String {
    switch self {
    case let .readFailed(address, count): return "memory at 0x\(String(address, radix: 16)) (\(count) bytes) is unreadable"
    case let .notReady(why): return "game not ready: \(why)"
    case let .unsupportedLayout(why): return "unsupported Mono layout: \(why)"
    case let .notFound(what): return "not found: \(what)"
    case let .invalidData(why): return "invalid data: \(why)"
    case let .accessDenied(code): return "task_for_pid failed (\(code))"
    }
  }
}

/// Where bytes come from: the live game (TaskMemory) or a fake built by tests. Read-only by design.
public protocol MemorySource: AnyObject {
  /// Copies `count` bytes at `address`. Throws if any of them is unreadable.
  func read(address: UInt64, count: Int) throws -> [UInt8]
}

/// Typed little-endian reads over a MemorySource, with a page cache so walking many small structures
/// costs one system call per 4 KB page instead of one per field. Call `clearCache()` before each snapshot
/// so values are never older than the current poll.
public final class MemoryReader {
  public static let pageSize: UInt64 = 4096
  private static let pageMask: UInt64 = ~(pageSize - 1)

  private let source: MemorySource
  private let maxCachedPages: Int
  private var pages: [UInt64: [UInt8]] = [:]
  /// Calls made to the source; useful for checking the cost of a read.
  public private(set) var sourceReads = 0

  public init(source: MemorySource, maxCachedPages: Int = 4096) {
    self.source = source
    self.maxCachedPages = maxCachedPages
  }

  public func clearCache() { pages.removeAll(keepingCapacity: true) }

  private func page(_ base: UInt64) throws -> [UInt8] {
    if let cached = pages[base] { return cached }
    if pages.count >= maxCachedPages { pages.removeAll(keepingCapacity: true) }
    sourceReads += 1
    let bytes = try source.read(address: base, count: Int(Self.pageSize))
    guard bytes.count == Int(Self.pageSize) else { throw MonoReaderError.readFailed(address: base, count: bytes.count) }
    pages[base] = bytes
    return bytes
  }

  public func bytes(_ address: UInt64, _ count: Int) throws -> [UInt8] {
    guard count > 0 else { return [] }
    guard count <= 1 << 22 else { throw MonoReaderError.invalidData("read of \(count) bytes") }
    let (end, overflow) = address.addingReportingOverflow(UInt64(count))
    guard !overflow, address != 0 else { throw MonoReaderError.readFailed(address: address, count: count) }
    var out: [UInt8] = []
    out.reserveCapacity(count)
    var cursor = address
    do {
      while cursor < end {
        let base = cursor & Self.pageMask
        let page = try page(base)
        let start = Int(cursor - base)
        let take = min(Int(Self.pageSize) - start, Int(end - cursor))
        out.append(contentsOf: page[start..<(start + take)])
        cursor += UInt64(take)
      }
    } catch {
      // A whole page wasn't readable; the exact range still may be.
      sourceReads += 1
      let direct = try source.read(address: address, count: count)
      guard direct.count == count else { throw MonoReaderError.readFailed(address: address, count: count) }
      return direct
    }
    return out
  }

  private func load<T: FixedWidthInteger>(_ address: UInt64, as type: T.Type) throws -> T {
    let size = UInt64(MemoryLayout<T>.size)
    let base = address & Self.pageMask
    if address != 0, address - base + size <= Self.pageSize, let page = try? page(base) {
      return page.withUnsafeBytes { $0.loadUnaligned(fromByteOffset: Int(address - base), as: T.self) }
    }
    let raw = try bytes(address, Int(size))
    return raw.withUnsafeBytes { $0.loadUnaligned(as: T.self) }
  }

  public func u8(_ address: UInt64) throws -> UInt8 { try load(address, as: UInt8.self) }
  public func u16(_ address: UInt64) throws -> UInt16 { try load(address, as: UInt16.self) }
  public func u32(_ address: UInt64) throws -> UInt32 { try load(address, as: UInt32.self) }
  public func i32(_ address: UInt64) throws -> Int32 { try load(address, as: Int32.self) }
  public func u64(_ address: UInt64) throws -> UInt64 { try load(address, as: UInt64.self) }
  public func i64(_ address: UInt64) throws -> Int64 { try load(address, as: Int64.self) }
  public func pointer(_ address: UInt64) throws -> UInt64 { try load(address, as: UInt64.self) }

  /// A NUL-terminated UTF-8 string (Mono's metadata names). Empty for a null pointer.
  public func cString(_ address: UInt64, maxLength: Int = 512) throws -> String {
    guard address != 0 else { return "" }
    var out: [UInt8] = []
    var cursor = address
    while out.count < maxLength {
      let base = cursor & Self.pageMask
      let chunkEnd = min(base + Self.pageSize, cursor + UInt64(maxLength - out.count))
      let chunk = try bytes(cursor, Int(chunkEnd - cursor))
      if let zero = chunk.firstIndex(of: 0) {
        out.append(contentsOf: chunk[..<zero])
        return String(decoding: out, as: UTF8.self)
      }
      out.append(contentsOf: chunk)
      cursor = chunkEnd
    }
    throw MonoReaderError.invalidData("string at 0x\(String(address, radix: 16)) longer than \(maxLength)")
  }

  /// `units` UTF-16 code units (a managed string's characters).
  public func utf16String(_ address: UInt64, units: Int) throws -> String {
    guard units > 0 else { return "" }
    let raw = try bytes(address, units * 2)
    var codeUnits = [UInt16](repeating: 0, count: units)
    for index in 0..<units { codeUnits[index] = UInt16(raw[index * 2]) | UInt16(raw[index * 2 + 1]) << 8 }
    return String(decoding: codeUnits, as: UTF16.self)
  }
}
