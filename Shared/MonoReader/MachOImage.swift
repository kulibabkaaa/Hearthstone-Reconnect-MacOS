import Foundation

/// The CPU type a loaded image was built for. Hearthstone is universal; under Rosetta it runs x86_64.
public enum CPUArchitecture: Equatable, Sendable {
  case arm64
  case x86_64
}

public struct LoadedImage: Equatable, Sendable {
  public let address: UInt64
  public let path: String

  public init(address: UInt64, path: String) {
    self.address = address
    self.path = path
  }
}

public enum LoadedImages {
  /// Reads dyld's image list: `dyld_all_image_infos` (version u32, count u32, array pointer), each entry
  /// `{ load address, path pointer, mod date }` (24 bytes). The address comes from task_info(TASK_DYLD_INFO).
  public static func list(allImageInfoAddress: UInt64, reader: MemoryReader) throws -> [LoadedImage] {
    let count = try reader.u32(allImageInfoAddress + 4)
    let array = try reader.pointer(allImageInfoAddress + 8)
    guard count > 0, count < 10_000, array != 0 else { throw MonoReaderError.notReady("dyld image list is empty") }
    let raw = try reader.bytes(array, Int(count) * 24)
    var images: [LoadedImage] = []
    images.reserveCapacity(Int(count))
    for index in 0..<Int(count) {
      let (address, pathPointer) = raw.withUnsafeBytes {
        ($0.loadUnaligned(fromByteOffset: index * 24, as: UInt64.self),
         $0.loadUnaligned(fromByteOffset: index * 24 + 8, as: UInt64.self))
      }
      guard address != 0, pathPointer != 0 else { continue }
      images.append(LoadedImage(address: address, path: (try? reader.cString(pathPointer, maxLength: 2048)) ?? ""))
    }
    return images
  }
}

/// A 64-bit Mach-O image as it is mapped in the target, read from the target's own memory (so the slice the game
/// actually runs is the one parsed). Only what symbol lookup needs.
public struct MachOImage: Equatable, Sendable {
  public static let magic64: UInt32 = 0xfeed_facf
  public static let cpuTypeARM64: UInt32 = 0x0100_000c
  public static let cpuTypeX86_64: UInt32 = 0x0100_0007
  static let loadCommandSegment64: UInt32 = 0x19
  static let loadCommandSymtab: UInt32 = 0x2

  public let address: UInt64
  public let architecture: CPUArchitecture
  let slide: UInt64
  let linkeditBase: UInt64
  let symbolOffset: UInt64
  let symbolCount: Int
  let stringOffset: UInt64
  let stringSize: UInt64

  public init(address: UInt64, reader: MemoryReader) throws {
    guard try reader.u32(address) == Self.magic64 else {
      throw MonoReaderError.unsupportedLayout("Mono library is not a 64-bit Mach-O image")
    }
    switch try reader.u32(address + 4) {
    case Self.cpuTypeARM64: architecture = .arm64
    case Self.cpuTypeX86_64: architecture = .x86_64
    case let other: throw MonoReaderError.unsupportedLayout("CPU type 0x\(String(other, radix: 16))")
    }
    let commandCount = try reader.u32(address + 16)
    let commandsSize = try reader.u32(address + 20)
    guard commandCount < 512, commandsSize < 1 << 20 else { throw MonoReaderError.invalidData("Mach-O load commands") }
    let commands = try reader.bytes(address + 32, Int(commandsSize))
    func u32(_ offset: Int) -> UInt32 { commands.withUnsafeBytes { $0.loadUnaligned(fromByteOffset: offset, as: UInt32.self) } }
    func u64(_ offset: Int) -> UInt64 { commands.withUnsafeBytes { $0.loadUnaligned(fromByteOffset: offset, as: UInt64.self) } }
    func name(_ offset: Int) -> String {
      let bytes = commands[offset..<(offset + 16)].prefix { $0 != 0 }
      return String(decoding: bytes, as: UTF8.self)
    }

    var textAddress: UInt64?
    var linkeditAddress: UInt64?
    var linkeditFileOffset: UInt64 = 0
    var symtab: (symbols: UInt64, count: UInt32, strings: UInt64, stringSize: UInt32)?
    var cursor = 0
    for _ in 0..<commandCount {
      guard cursor + 8 <= commands.count else { break }
      let command = u32(cursor)
      let size = Int(u32(cursor + 4))
      guard size >= 8, cursor + size <= commands.count else { throw MonoReaderError.invalidData("Mach-O load command size") }
      if command == Self.loadCommandSegment64, size >= 72 {
        switch name(cursor + 8) {
        case "__TEXT": textAddress = u64(cursor + 24)
        case "__LINKEDIT":
          linkeditAddress = u64(cursor + 24)
          linkeditFileOffset = u64(cursor + 40)
        default: break
        }
      } else if command == Self.loadCommandSymtab, size >= 24 {
        symtab = (UInt64(u32(cursor + 8)), u32(cursor + 12), UInt64(u32(cursor + 16)), u32(cursor + 20))
      }
      cursor += size
    }
    guard let textAddress, let linkeditAddress, let symtab, symtab.count < 500_000 else {
      throw MonoReaderError.unsupportedLayout("Mono library has no symbol table")
    }
    self.address = address
    slide = address &- textAddress
    linkeditBase = linkeditAddress &+ slide &- linkeditFileOffset
    symbolOffset = symtab.symbols
    symbolCount = Int(symtab.count)
    stringOffset = symtab.strings
    stringSize = UInt64(symtab.stringSize)
  }

  /// Addresses (in the target) of the requested defined symbols, e.g. "_mono_get_root_domain".
  public func symbols(named wanted: Set<String>, reader: MemoryReader) throws -> [String: UInt64] {
    let table = try reader.bytes(linkeditBase + symbolOffset, symbolCount * 16)
    let strings = try reader.bytes(linkeditBase + stringOffset, Int(stringSize))
    let longest = wanted.map(\.utf8.count).max() ?? 0
    var found: [String: UInt64] = [:]
    for index in 0..<symbolCount {
      let (nameOffset, type, value) = table.withUnsafeBytes {
        ($0.loadUnaligned(fromByteOffset: index * 16, as: UInt32.self),
         $0.load(fromByteOffset: index * 16 + 4, as: UInt8.self),
         $0.loadUnaligned(fromByteOffset: index * 16 + 8, as: UInt64.self))
      }
      // N_SECT: defined in a section of this image. Skip debugging (stab) entries.
      guard type & 0xe0 == 0, type & 0x0e == 0x0e, value != 0, Int(nameOffset) < strings.count else { continue }
      let start = Int(nameOffset)
      let limit = min(strings.count, start + longest + 1)
      guard let end = strings[start..<limit].firstIndex(of: 0) else { continue }
      let name = String(decoding: strings[start..<end], as: UTF8.self)
      if wanted.contains(name) { found[name] = value &+ slide }
      if found.count == wanted.count { break }
    }
    return found
  }
}
