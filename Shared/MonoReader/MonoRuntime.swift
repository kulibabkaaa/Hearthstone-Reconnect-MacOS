import Foundation

/// Mono's type codes (MonoTypeEnum) that the reader handles.
public enum MonoTypeCode {
  public static let boolean: UInt8 = 0x02
  public static let char: UInt8 = 0x03
  public static let i1: UInt8 = 0x04
  public static let u1: UInt8 = 0x05
  public static let i2: UInt8 = 0x06
  public static let u2: UInt8 = 0x07
  public static let i4: UInt8 = 0x08
  public static let u4: UInt8 = 0x09
  public static let i8: UInt8 = 0x0a
  public static let u8: UInt8 = 0x0b
  public static let string: UInt8 = 0x0e
  public static let valueType: UInt8 = 0x11
  public static let classType: UInt8 = 0x12
  public static let genericInstance: UInt8 = 0x15
  public static let object: UInt8 = 0x1c
  public static let szArray: UInt8 = 0x1d
  public static let array: UInt8 = 0x14
}

/// MonoClass kinds (class_kind).
public enum MonoClassKind {
  public static let definition: UInt8 = 1
  public static let genericDefinition: UInt8 = 2
  public static let genericInstance: UInt8 = 3
}

public struct MonoField: Equatable, Sendable {
  public let name: String
  public let typeCode: UInt8
  /// MonoType.data: the MonoClass* for VALUETYPE/CLASS, the MonoGenericClass* for GENERICINST.
  public let typeData: UInt64
  public let attributes: UInt16
  public let offset: Int32

  public var isStatic: Bool { attributes & 0x10 != 0 }
  public var isLiteral: Bool { attributes & 0x40 != 0 }
}

public struct MonoAssembly: Equatable, Sendable {
  public let name: String
  public let image: UInt64
}

/// A read-only view of a Unity Mono runtime in another process.
public final class MonoRuntime {
  public static let monoLibrarySuffix = "/libmonobdwgc-2.0.dylib"

  public let reader: MemoryReader
  public let architecture: CPUArchitecture
  public private(set) var layout: MonoLayout
  public let domain: UInt64
  public private(set) var assemblies: [MonoAssembly] = []

  private var classIndex: [UInt64: [String: UInt64]] = [:]
  private var fieldCache: [UInt64: [MonoField]] = [:]
  private var nameCache: [UInt64: String] = [:]
  private var lastIndexed: [UInt64: Date] = [:]
  private static let reindexInterval: TimeInterval = 5

  init(reader: MemoryReader, architecture: CPUArchitecture, layout: MonoLayout, domain: UInt64) {
    self.reader = reader
    self.architecture = architecture
    self.layout = layout
    self.domain = domain
  }

  /// Finds Mono in the target, reads its layout from its own code, checks it, and indexes `indexAssemblies`.
  /// Throws `.notReady` while the game is still starting and `.unsupportedLayout` when this Mono build isn't one
  /// the reader can trust (then it must give no data).
  public static func attach(memory: MemorySource, allImageInfoAddress: UInt64,
                            indexAssemblies: [String] = ["Assembly-CSharp"]) throws -> MonoRuntime {
    let reader = MemoryReader(source: memory)
    let images = try LoadedImages.list(allImageInfoAddress: allImageInfoAddress, reader: reader)
    guard let mono = images.first(where: { $0.path.hasSuffix(monoLibrarySuffix) }) else {
      throw MonoReaderError.notReady("Mono isn't loaded yet")
    }
    let image = try MachOImage(address: mono.address, reader: reader)
    let wanted = Set(MonoLayout.accessorSymbols + [MonoLayout.rootDomainSymbol])
    let symbols = try image.symbols(named: wanted, reader: reader)
    let fetch: (UInt64) throws -> [UInt8] = { try reader.bytes($0, 64) }
    var layout = try MonoLayout.derive(symbols: symbols, architecture: image.architecture, fetch: fetch)
    guard let rootFunction = symbols[MonoLayout.rootDomainSymbol] else {
      throw MonoReaderError.unsupportedLayout("missing export \(MonoLayout.rootDomainSymbol)")
    }
    let global = try MonoLayout.rootDomainGlobal(function: rootFunction, architecture: image.architecture, fetch: fetch)
    let domain = try reader.pointer(global)
    guard domain != 0 else { throw MonoReaderError.notReady("Mono has no root domain yet") }

    layout.domainAssemblies = try findDomainAssemblies(domain: domain, layout: layout, reader: reader)
    let runtime = MonoRuntime(reader: reader, architecture: image.architecture, layout: layout, domain: domain)
    runtime.assemblies = try runtime.readAssemblies()
    guard let corlib = runtime.assemblies.first(where: { $0.name == "mscorlib" }) else {
      throw MonoReaderError.notReady("mscorlib isn't loaded yet")
    }
    // Everything below needs a game that is past startup; a slow start must never look like an unknown layout.
    for name in indexAssemblies where !runtime.assemblies.contains(where: { $0.name == name }) {
      throw MonoReaderError.notReady("\(name) isn't loaded yet")
    }
    runtime.layout.imageClassCache = try findClassCache(image: corlib.image, layout: layout, reader: reader)
    try runtime.validateLayout()
    for name in indexAssemblies { _ = try runtime.index(assembly: name, force: true) }
    reader.clearCache()
    return runtime
  }

  /// Drops cached memory pages so the next reads see current values. Call once per poll.
  public func beginSnapshot() { reader.clearCache() }

  // MARK: Discovery

  private static func printable(_ text: String) -> Bool {
    text.utf8.count >= 2 && text.utf8.allSatisfy { $0 >= 0x20 && $0 < 0x7f }
  }

  /// MonoDomain.domain_assemblies: a GSList of MonoAssembly* whose names include mscorlib.
  static func findDomainAssemblies(domain: UInt64, layout: MonoLayout, reader: MemoryReader) throws -> UInt64 {
    for offset in stride(from: UInt64(8), to: 1024, by: 8) {
      guard let head = try? reader.pointer(domain + offset), head != 0, head % 8 == 0 else { continue }
      var node = head
      var names: [String] = []
      while node != 0, names.count < 1000 {
        guard let assembly = try? reader.pointer(node), assembly != 0,
              let namePointer = try? reader.pointer(assembly + layout.assemblyName),
              let name = try? reader.cString(namePointer, maxLength: 128), printable(name) else { break }
        names.append(name)
        node = (try? reader.pointer(node + 8)) ?? 0
      }
      if names.first == "mscorlib" || (names.count >= 2 && names.contains("mscorlib")) { return offset }
    }
    throw MonoReaderError.notReady("no assembly list in the root domain")
  }

  /// MonoImage.class_cache: a MonoInternalHashTable whose buckets hold classes that point back at this image.
  static func findClassCache(image: UInt64, layout: MonoLayout, reader: MemoryReader) throws -> UInt64 {
    for offset in stride(from: UInt64(256), to: 4096, by: 8) {
      guard let size = try? reader.u32(image + offset + layout.hashTableSize), size >= 64, size < 400_000,
            let buckets = try? reader.pointer(image + offset + layout.hashTableBuckets), buckets != 0, buckets % 8 == 0,
            let firstBuckets = try? reader.bytes(buckets, Int(min(size, 256)) * 8) else { continue }
      var checked = 0
      var good = 0
      for index in 0..<Int(min(size, 256)) {
        let klass = firstBuckets.withUnsafeBytes { $0.loadUnaligned(fromByteOffset: index * 8, as: UInt64.self) }
        guard klass != 0 else { continue }
        checked += 1
        if (try? reader.pointer(klass + layout.classImage)) == image,
           let namePointer = try? reader.pointer(klass + layout.className),
           let name = try? reader.cString(namePointer, maxLength: 256), !name.isEmpty { good += 1 }
      }
      if checked >= 8, good == checked { return offset }
    }
    // Classes enter the cache as they are first used, so an early cache can be too small to recognise.
    throw MonoReaderError.notReady("no class cache in mscorlib's image yet")
  }

  func readAssemblies() throws -> [MonoAssembly] {
    var result: [MonoAssembly] = []
    var node = try reader.pointer(domain + layout.domainAssemblies)
    while node != 0, result.count < 2000 {
      let assembly = try reader.pointer(node)
      if assembly != 0 {
        let name = try reader.cString(try reader.pointer(assembly + layout.assemblyName), maxLength: 256)
        let image = try reader.pointer(assembly + layout.assemblyImage)
        if image != 0 { result.append(MonoAssembly(name: name, image: image)) }
      }
      node = try reader.pointer(node + 8)
    }
    return result
  }

  // MARK: Self-check

  /// Proves the offsets that no accessor gives (and re-proves several that one does) on classes every mscorlib
  /// has: System.String, System.Int32 and the enums already loaded. Throws `.unsupportedLayout` on a mismatch, and
  /// `.notReady` when what it needs hasn't been loaded or initialised yet (classes load as they are first used).
  func validateLayout() throws {
    func fail(_ why: String) -> MonoReaderError { .unsupportedLayout("self-check failed: \(why)") }
    _ = try index(assembly: "mscorlib", force: true)
    guard let string = try findClass("System.String", in: "mscorlib"),
          let int32 = try findClass("System.Int32", in: "mscorlib"),
          let enumBase = try findClass("System.Enum", in: "mscorlib") else {
      throw MonoReaderError.notReady("mscorlib's core classes aren't loaded yet")
    }
    let corlib = image(of: "mscorlib") ?? 0
    let enums = try (classIndex[corlib] ?? [:]).values.filter { try parent($0) == enumBase }.prefix(64)
    guard !enums.isEmpty else { throw MonoReaderError.notReady("no enum classes loaded yet") }
    guard try kind(string) == MonoClassKind.definition, try kind(int32) == MonoClassKind.definition else { throw fail("class kind") }
    guard try !isValueType(string), try !isEnum(string), try isValueType(int32), try !isEnum(int32),
          try enums.allSatisfy({ try isEnum($0) && isValueType($0) }) else {
      throw fail("class flag bits")
    }
    // A managed object starts with a vtable pointer and a sync word; String's first field follows them.
    guard layout.stringLength == layout.objectHeader else { throw fail("object header") }
    let fields = try ownFields(string)
    guard fields.count >= 3,
          fields.contains(where: { !$0.isStatic && $0.typeCode == MonoTypeCode.i4 && UInt64($0.offset) == layout.stringLength }),
          fields.contains(where: { !$0.isStatic && $0.typeCode == MonoTypeCode.char && UInt64($0.offset) == layout.stringChars }) else {
      throw fail("System.String fields")
    }
    guard let empty = fields.first(where: { $0.name == "Empty" && $0.isStatic && !$0.isLiteral && $0.typeCode == MonoTypeCode.string }) else {
      throw fail("System.String.Empty")
    }
    guard let storage = try staticStorage(string) else { throw MonoReaderError.notReady("System.String isn't initialised yet") }
    let emptyString = try reader.pointer(storage + UInt64(UInt32(bitPattern: empty.offset)))
    guard emptyString != 0, try classOf(object: emptyString) == string, try reader.i32(emptyString + layout.stringLength) == 0 else {
      throw fail("static data")
    }
  }

  // MARK: Classes

  public func image(of assembly: String) -> UInt64? { assemblies.first { $0.name == assembly }?.image }

  /// Indexes every class in an assembly's class cache by full name ("Namespace.Outer+Inner").
  /// Re-indexing is rate-limited unless `force`; returns the number of classes.
  @discardableResult
  public func index(assembly: String, force: Bool = false) throws -> Int {
    if image(of: assembly) == nil { assemblies = try readAssemblies() }
    guard let image = image(of: assembly) else { throw MonoReaderError.notFound("assembly \(assembly)") }
    if !force, let last = lastIndexed[image], Date().timeIntervalSince(last) < Self.reindexInterval {
      return classIndex[image]?.count ?? 0
    }
    lastIndexed[image] = Date()
    let table = image + layout.imageClassCache
    let size = try reader.u32(table + layout.hashTableSize)
    let buckets = try reader.pointer(table + layout.hashTableBuckets)
    guard size > 0, size < 400_000, buckets != 0 else { throw MonoReaderError.invalidData("class cache of \(assembly)") }
    let bucketBytes = try reader.bytes(buckets, Int(size) * 8)
    var names: [String: UInt64] = [:]
    for bucket in 0..<Int(size) {
      var klass = bucketBytes.withUnsafeBytes { $0.loadUnaligned(fromByteOffset: bucket * 8, as: UInt64.self) }
      var chain = 0
      while klass != 0, chain < 10_000 {
        guard try reader.pointer(klass + layout.classImage) == image else {
          throw MonoReaderError.unsupportedLayout("class cache entry from another image")
        }
        names[try fullName(klass)] = klass
        klass = try reader.pointer(klass + layout.classNextCache)
        chain += 1
      }
    }
    classIndex[image] = names
    return names.count
  }

  /// A class by full name. A miss re-indexes the assembly (rate-limited): classes load lazily as the game runs.
  public func findClass(_ fullName: String, in assembly: String = "Assembly-CSharp") throws -> UInt64? {
    guard let image = image(of: assembly) else { return nil }
    if let klass = classIndex[image]?[fullName] { return klass }
    try index(assembly: assembly)
    return classIndex[image]?[fullName]
  }

  public func name(_ klass: UInt64) throws -> String {
    try reader.cString(try reader.pointer(klass + layout.className), maxLength: 512)
  }

  public func fullName(_ klass: UInt64) throws -> String {
    if let cached = nameCache[klass] { return cached }
    var parts: [String] = []
    var current = klass
    var namespace = ""
    while current != 0, parts.count < 16 {
      parts.append(try name(current))
      let outer = try reader.pointer(current + layout.classNestedIn)
      if outer == 0 { namespace = try reader.cString(try reader.pointer(current + layout.classNamespace), maxLength: 512) }
      current = outer
    }
    let joined = parts.reversed().joined(separator: "+")
    let result = namespace.isEmpty ? joined : "\(namespace).\(joined)"
    nameCache[klass] = result
    return result
  }

  public func kind(_ klass: UInt64) throws -> UInt8 { try reader.u8(klass + layout.classKind) & 0x7 }
  public func parent(_ klass: UInt64) throws -> UInt64 { try reader.pointer(klass + layout.classParent) }
  public func isValueType(_ klass: UInt64) throws -> Bool {
    try reader.u32(klass + layout.classBits) >> layout.valueTypeBit & 1 == 1
  }
  public func isEnum(_ klass: UInt64) throws -> Bool { try reader.u32(klass + layout.classBits) >> layout.enumBit & 1 == 1 }

  /// For a generic instance (List<int>), its generic definition (List`1).
  public func genericDefinition(_ klass: UInt64) throws -> UInt64? {
    guard try kind(klass) == MonoClassKind.genericInstance else { return nil }
    let genericClass = try reader.pointer(klass + layout.classGenericClass)
    guard genericClass != 0 else { return nil }
    let definition = try reader.pointer(genericClass)
    guard definition != 0, try kind(definition) == MonoClassKind.genericDefinition else {
      throw MonoReaderError.unsupportedLayout("generic instance without a generic definition")
    }
    return definition
  }

  /// Fields declared on this class (not inherited). A generic instance uses its own inflated fields, whose offsets
  /// fit its type arguments, and its definition's field count.
  public func ownFields(_ klass: UInt64) throws -> [MonoField] {
    if let cached = fieldCache[klass] { return cached }
    var countSource = klass
    var first = try reader.pointer(klass + layout.classFields)
    switch try kind(klass) {
    case MonoClassKind.definition, MonoClassKind.genericDefinition: break
    case MonoClassKind.genericInstance:
      guard let definition = try genericDefinition(klass) else { return [] }
      countSource = definition
    default: return []
    }
    let count = try reader.u32(countSource + layout.classFieldCount)
    guard first != 0, count > 0 else { return [] }
    guard count < 4096 else { throw MonoReaderError.invalidData("\(count) fields") }
    let raw = try reader.bytes(first, Int(count) * Int(layout.fieldSize))
    var fields: [MonoField] = []
    for index in 0..<Int(count) {
      let base = index * Int(layout.fieldSize)
      func pointer(_ offset: UInt64) -> UInt64 {
        raw.withUnsafeBytes { $0.loadUnaligned(fromByteOffset: base + Int(offset), as: UInt64.self) }
      }
      let type = pointer(layout.fieldType)
      guard type != 0 else { break }
      let offset = raw.withUnsafeBytes { $0.loadUnaligned(fromByteOffset: base + Int(layout.fieldOffset), as: Int32.self) }
      fields.append(MonoField(
        name: try reader.cString(pointer(layout.fieldName), maxLength: 512),
        typeCode: try reader.u8(type + layout.typeCode),
        typeData: try reader.pointer(type),
        attributes: try reader.u16(type + layout.typeAttributes),
        offset: offset
      ))
    }
    first = 0
    fieldCache[klass] = fields
    return fields
  }

  /// A field by name on this class or its parents.
  public func field(_ name: String, in klass: UInt64) throws -> MonoField? {
    var current = klass
    var depth = 0
    while current != 0, depth < 32 {
      if let found = try ownFields(current).first(where: { $0.name == name }) { return found }
      current = try parent(current)
      depth += 1
    }
    return nil
  }

  /// The class's static-field block for the root domain, or nil before the class is initialised.
  public func staticStorage(_ klass: UInt64) throws -> UInt64? {
    let runtimeInfo = try reader.pointer(klass + layout.classRuntimeInfo)
    guard runtimeInfo != 0 else { return nil }
    let domainID = UInt64(try reader.i32(domain + layout.domainID))
    let maxDomain = UInt64(try reader.u16(runtimeInfo))
    guard domainID <= maxDomain else { return nil }
    let vtable = try reader.pointer(runtimeInfo + layout.runtimeInfoDomainVTables + domainID * 8)
    guard vtable != 0 else { return nil }
    guard try reader.pointer(vtable) == klass else { throw MonoReaderError.invalidData("vtable of another class") }
    let slots = UInt64(try reader.i32(klass + layout.classVTableSize))
    guard slots < 100_000 else { throw MonoReaderError.invalidData("vtable size \(slots)") }
    let storage = try reader.pointer(vtable + layout.vtableSlots + slots * 8)
    return storage == 0 ? nil : storage
  }

  /// The class of a managed object (object → MonoVTable → klass).
  public func classOf(object: UInt64) throws -> UInt64 {
    let vtable = try reader.pointer(object)
    guard vtable != 0 else { throw MonoReaderError.invalidData("object without vtable") }
    let klass = try reader.pointer(vtable)
    guard klass != 0 else { throw MonoReaderError.invalidData("vtable without class") }
    return klass
  }
}
