import Foundation

@testable import MonoReader

/// Sparse fake process memory, 4 KB pages. Reading a byte on a page nobody wrote throws, like unmapped memory.
final class FakeMemory: MemorySource {
  private(set) var pages: [UInt64: [UInt8]] = [:]
  private(set) var reads = 0

  func write(_ address: UInt64, _ bytes: [UInt8]) {
    for (index, byte) in bytes.enumerated() {
      let at = address + UInt64(index)
      let base = at & ~0xfff
      if pages[base] == nil { pages[base] = [UInt8](repeating: 0, count: 4096) }
      pages[base]![Int(at - base)] = byte
    }
  }

  func write<T: FixedWidthInteger>(_ address: UInt64, _ value: T) {
    write(address, withUnsafeBytes(of: value.littleEndian) { Array($0) })
  }

  func unmap(page address: UInt64) { pages[address & ~0xfff] = nil }

  func read(address: UInt64, count: Int) throws -> [UInt8] {
    reads += 1
    var out: [UInt8] = []
    out.reserveCapacity(count)
    for index in 0..<count {
      let at = address + UInt64(index)
      guard let page = pages[at & ~0xfff] else { throw MonoReaderError.readFailed(address: address, count: count) }
      out.append(page[Int(at & 0xfff)])
    }
    return out
  }
}

/// The offsets of Hearthstone 37.0's Mono (Unity 6000.3.11f1) on macOS, as measured live on 15 Nov 2026.
/// Both CPU slices must derive exactly these from their accessor code.
let expectedLayout: MonoLayout = {
  var layout = MonoLayout(
    assemblyName: 0x10, assemblyImage: 0x60, classElementClass: 0, classKind: 0x1b, classBits: 0x20, classParent: 0x28,
    classNestedIn: 0x30, classImage: 0x38, className: 0x40, classNamespace: 0x48, classSizes: 0x88, classFields: 0x90,
    classByValArg: 0xb0, fieldType: 0, fieldName: 8, fieldOffset: 0x18, typeCode: 0xa, stringLength: 0x10,
    stringChars: 0x14, arrayLength: 0x18, arrayData: 0x20, classVTableSize: 0x54, vtableSlots: 0x48,
    classRuntimeInfo: 0xc8, classGenericClass: 0xe8, classFieldCount: 0xf8, classNextCache: 0x100, domainID: 0xa4,
    runtimeInfoDomainVTables: 8, typeAttributes: 8, fieldSize: 32, objectHeader: 16, hashTableSize: 24,
    hashTableBuckets: 32, valueTypeBit: 2, enumBit: 3)
  layout.domainAssemblies = 0xb0
  layout.imageClassCache = 0x4d0
  return layout
}()

struct FieldSpec {
  var name: String
  var type: UInt8
  var data: UInt64 = 0
  var isStatic = false
  var offset: Int32
  var literal = false
}

/// Builds a fake Hearthstone process: the Mono library image (real accessor code from AccessorCodeFixture),
/// dyld's image list, and Mono runtime structures laid out with `expectedLayout`.
final class FakeMono {
  let memory = FakeMemory()
  let layout = expectedLayout
  let architecture: CPUArchitecture
  let imageBase: UInt64 = 0x2_0000_0000
  private var heap: UInt64 = 0x1_0000_0000
  private(set) var allImageInfo: UInt64 = 0
  private(set) var domain: UInt64 = 0
  private var assemblyNodes: [(name: String, assembly: UInt64, image: UInt64)] = []
  private var classesByImage: [UInt64: [UInt64]] = [:]
  private var vtables: [UInt64: UInt64] = [:]
  private var genericDefinitions: [String: UInt64] = [:]
  private(set) var stringClass: UInt64 = 0
  private(set) var objectClass: UInt64 = 0
  /// System.String's static block (holds `Empty`).
  private(set) var stringStorage: UInt64 = 0

  /// Bytes of the accessor code as placed in the image; tests may corrupt them before `install()`.
  var code: [String: (address: UInt64, bytes: [UInt8])] = [:]
  var monoPath = "/Applications/Hearthstone/Hearthstone.app/Contents/Frameworks/libmonobdwgc-2.0.dylib"
  var exportSymbols = true

  init(architecture: CPUArchitecture) {
    self.architecture = architecture
    let chunks = architecture == .arm64 ? AccessorCodeFixture.arm64 : AccessorCodeFixture.x86_64
    for chunk in chunks { code[chunk.symbol] = (chunk.address, Self.bytes(hex: chunk.hex)) }
  }

  static func bytes(hex: String) -> [UInt8] {
    var out: [UInt8] = []
    var index = hex.startIndex
    while index < hex.endIndex {
      let next = hex.index(index, offsetBy: 2)
      out.append(UInt8(hex[index..<next], radix: 16)!)
      index = next
    }
    return out
  }

  // MARK: Allocation

  func alloc(_ size: Int, align: UInt64 = 16) -> UInt64 {
    heap = (heap + align - 1) / align * align
    let address = heap
    memory.write(address, [UInt8](repeating: 0, count: max(size, 1)))
    heap += UInt64(max(size, 1))
    return address
  }

  func cString(_ text: String) -> UInt64 {
    let address = alloc(text.utf8.count + 1, align: 1)
    memory.write(address, Array(text.utf8) + [0])
    return address
  }

  func pointer(_ address: UInt64, _ value: UInt64) { memory.write(address, value) }

  // MARK: Image and dyld

  /// The root-domain global the real mono_get_root_domain code points at, relative to the image.
  var rootDomainGlobalOffset: UInt64 { architecture == .arm64 ? 0x30_ae80 : 0x32_d288 }

  /// Writes the Mach-O header, symbol table, code, dyld's list and the root domain pointer.
  func install() {
    let linkeditVM: UInt64 = 0x40_0000
    var names: [UInt8] = [0]
    var symbols: [UInt8] = []
    for (symbol, chunk) in code.sorted(by: { $0.key < $1.key }) where exportSymbols {
      symbols += le(UInt32(names.count)) + [0x0f, 1] + le(UInt16(0)) + le(chunk.address)
      names += Array(symbol.utf8) + [0]
    }
    let symbolCount = symbols.count / 16
    let stringOffset = UInt64(symbols.count)

    var commands: [UInt8] = []
    commands += segment("__TEXT", vmaddr: 0, fileoff: 0)
    commands += segment("__LINKEDIT", vmaddr: linkeditVM, fileoff: 0x1000)
    commands += le(UInt32(0x2)) + le(UInt32(24)) + le(UInt32(0x1000)) + le(UInt32(symbolCount))
      + le(UInt32(0x1000) + UInt32(stringOffset)) + le(UInt32(names.count))
    let cpu: UInt32 = architecture == .arm64 ? MachOImage.cpuTypeARM64 : MachOImage.cpuTypeX86_64
    let header = le(MachOImage.magic64) + le(cpu) + le(UInt32(0)) + le(UInt32(6)) + le(UInt32(3))
      + le(UInt32(commands.count)) + le(UInt32(0)) + le(UInt32(0))
    memory.write(imageBase, header + commands)
    // __LINKEDIT lives at vmaddr + slide - fileoff + offset.
    let linkeditBase = imageBase + linkeditVM - 0x1000
    memory.write(linkeditBase + 0x1000, symbols)
    memory.write(linkeditBase + 0x1000 + stringOffset, names)
    for (_, chunk) in code { memory.write(imageBase + chunk.address, chunk.bytes) }

    let path = cString(monoPath)
    let otherPath = cString("/usr/lib/libSystem.B.dylib")
    let list = alloc(48)
    pointer(list, 0x1_8000_0000); pointer(list + 8, otherPath)
    pointer(list + 24, imageBase); pointer(list + 32, path)
    allImageInfo = alloc(64)
    memory.write(allImageInfo, UInt32(17))
    memory.write(allImageInfo + 4, UInt32(2))
    pointer(allImageInfo + 8, list)
    memory.write(imageBase + rootDomainGlobalOffset, domain)
  }

  private func le<T: FixedWidthInteger>(_ value: T) -> [UInt8] { withUnsafeBytes(of: value.littleEndian) { Array($0) } }

  private func segment(_ name: String, vmaddr: UInt64, fileoff: UInt64) -> [UInt8] {
    var bytes = le(UInt32(0x19)) + le(UInt32(72))
    bytes += Array(name.utf8) + [UInt8](repeating: 0, count: 16 - name.utf8.count)
    bytes += le(vmaddr) + le(UInt64(0x10_0000)) + le(fileoff) + le(UInt64(0x10_0000))
    bytes += le(UInt32(5)) + le(UInt32(5)) + le(UInt32(0)) + le(UInt32(0))
    return bytes
  }

  // MARK: Mono runtime

  /// The root domain, mscorlib with System.String / Int32 / DayOfWeek and filler classes, and Assembly-CSharp.
  func makeRuntime(stringLengthOffset: Int32 = 0x10, assemblies extra: [String] = ["Assembly-CSharp"]) {
    domain = alloc(0x400)
    let corlib = addAssembly("mscorlib")
    objectClass = addClass(image: corlib, namespace: "System", name: "Object")
    stringClass = addClass(image: corlib, namespace: "System", name: "String", parent: objectClass)
    let emptyString = alloc(0x20)
    pointer(emptyString, vtable(for: stringClass))
    setFields(stringClass, [
      FieldSpec(name: "m_stringLength", type: MonoTypeCode.i4, offset: stringLengthOffset),
      FieldSpec(name: "m_firstChar", type: MonoTypeCode.char, offset: 0x14),
      FieldSpec(name: "Empty", type: MonoTypeCode.string, isStatic: true, offset: 0),
      FieldSpec(name: "LengthConst", type: MonoTypeCode.i4, isStatic: true, offset: 0, literal: true),
    ])
    stringStorage = staticStorage(for: stringClass, size: 16)
    pointer(stringStorage, emptyString)
    let valueType = addClass(image: corlib, namespace: "System", name: "ValueType", parent: objectClass)
    let int32 = addClass(image: corlib, namespace: "System", name: "Int32", parent: valueType, valueType: true)
    setFields(int32, [FieldSpec(name: "m_value", type: MonoTypeCode.i4, offset: 16)])
    let enumBase = addClass(image: corlib, namespace: "System", name: "Enum", parent: valueType)
    let day = addClass(image: corlib, namespace: "System", name: "DayOfWeek", parent: enumBase, valueType: true, isEnum: true)
    setFields(day, [FieldSpec(name: "value__", type: MonoTypeCode.i4, offset: 16)])
    for filler in ["Boolean", "Byte", "Char", "Int64", "UInt64", "Array", "Type"] {
      _ = addClass(image: corlib, namespace: "System", name: filler, parent: objectClass)
    }
    _ = genericDefinition(namespace: "System.Collections.Generic", name: "List`1", image: corlib)
    _ = genericDefinition(namespace: "System.Collections.Generic", name: "Dictionary`2", image: corlib)
    for name in extra { _ = addAssembly(name) }
  }

  @discardableResult
  func addAssembly(_ name: String) -> UInt64 {
    let image = alloc(0x1000)
    let assembly = alloc(0x100)
    pointer(assembly + layout.assemblyName, cString(name))
    pointer(assembly + layout.assemblyImage, image)
    assemblyNodes.append((name, assembly, image))
    // Rewrite the GSList.
    var next: UInt64 = 0
    for node in assemblyNodes.reversed() {
      let cell = alloc(16)
      pointer(cell, node.assembly)
      pointer(cell + 8, next)
      next = cell
    }
    pointer(domain + layout.domainAssemblies, next)
    return image
  }

  func image(_ assembly: String) -> UInt64 { assemblyNodes.first { $0.name == assembly }!.image }

  func addClass(image: UInt64, namespace: String, name: String, kind: UInt8 = MonoClassKind.definition,
                parent: UInt64 = 0, nestedIn: UInt64 = 0, valueType: Bool = false, isEnum: Bool = false,
                cached: Bool = true) -> UInt64 {
    let klass = alloc(0x120)
    memory.write(klass + layout.classKind, kind)
    var bits: UInt32 = 0
    if valueType { bits |= 1 << layout.valueTypeBit }
    if isEnum { bits |= 1 << layout.enumBit }
    memory.write(klass + layout.classBits, bits)
    pointer(klass + layout.classParent, parent)
    pointer(klass + layout.classNestedIn, nestedIn)
    pointer(klass + layout.classImage, image)
    pointer(klass + layout.className, cString(name))
    pointer(klass + layout.classNamespace, cString(namespace))
    if cached { classesByImage[image, default: []].append(klass) }
    return klass
  }

  func genericDefinition(namespace: String, name: String, image: UInt64) -> UInt64 {
    if let existing = genericDefinitions[name] { return existing }
    let definition = addClass(image: image, namespace: namespace, name: name, kind: MonoClassKind.genericDefinition,
                              parent: objectClass, cached: false)
    genericDefinitions[name] = definition
    return definition
  }

  /// A generic instance class (e.g. List<Foo>) of `definition`, with its own inflated fields.
  func genericInstance(of definition: UInt64, image: UInt64, fields: [FieldSpec], valueType: Bool = false) -> UInt64 {
    let klass = addClass(image: image, namespace: "", name: "inst", kind: MonoClassKind.genericInstance,
                         parent: objectClass, valueType: valueType, cached: false)
    let genericClass = alloc(32)
    pointer(genericClass, definition)
    pointer(klass + layout.classGenericClass, genericClass)
    pointer(klass + layout.classFields, fieldArray(fields))
    memory.write(definition + layout.classFieldCount, UInt32(fields.count))
    return klass
  }

  /// A MonoType for a generic instance field: data is a MonoGenericClass whose container is `definition`.
  func genericType(_ definition: UInt64) -> UInt64 {
    let genericClass = alloc(32)
    pointer(genericClass, definition)
    return genericClass
  }

  private func fieldArray(_ fields: [FieldSpec]) -> UInt64 {
    let array = alloc(fields.count * Int(layout.fieldSize) + 8)
    for (index, spec) in fields.enumerated() {
      let type = alloc(16)
      pointer(type, spec.data)
      var attributes: UInt16 = spec.isStatic ? 0x10 : 0
      if spec.literal { attributes |= 0x40 }
      memory.write(type + layout.typeAttributes, attributes)
      memory.write(type + layout.typeCode, spec.type)
      let entry = array + UInt64(index) * layout.fieldSize
      pointer(entry + layout.fieldType, type)
      pointer(entry + layout.fieldName, cString(spec.name))
      memory.write(entry + layout.fieldOffset, spec.offset)
    }
    return array
  }

  func setFields(_ klass: UInt64, _ fields: [FieldSpec]) {
    pointer(klass + layout.classFields, fieldArray(fields))
    memory.write(klass + layout.classFieldCount, UInt32(fields.count))
  }

  func vtable(for klass: UInt64, slots: Int32 = 3) -> UInt64 {
    if let existing = vtables[klass] { return existing }
    let vtable = alloc(Int(layout.vtableSlots) + Int(slots + 1) * 8)
    pointer(vtable, klass)
    memory.write(klass + layout.classVTableSize, slots)
    vtables[klass] = vtable
    return vtable
  }

  /// Gives the class a static-field block reachable the way Mono stores it.
  func staticStorage(for klass: UInt64, size: Int) -> UInt64 {
    let vtable = vtable(for: klass)
    let storage = alloc(size)
    let slots = UInt64(3)  // vtable(for:) sets vtable_size to 3
    pointer(vtable + layout.vtableSlots + slots * 8, storage)
    let runtimeInfo = alloc(32)
    memory.write(runtimeInfo, UInt16(0))
    pointer(runtimeInfo + layout.runtimeInfoDomainVTables, vtable)
    pointer(klass + layout.classRuntimeInfo, runtimeInfo)
    return storage
  }

  func newObject(_ klass: UInt64, size: Int = 0x80) -> UInt64 {
    let object = alloc(size)
    pointer(object, vtable(for: klass))
    return object
  }

  func newString(_ text: String) -> UInt64 {
    let units = Array(text.utf16)
    let object = alloc(0x14 + units.count * 2 + 2)
    pointer(object, vtable(for: stringClass))
    memory.write(object + layout.stringLength, Int32(units.count))
    for (index, unit) in units.enumerated() { memory.write(object + layout.stringChars + UInt64(index * 2), unit) }
    return object
  }

  /// An array object; returns (object, address of element 0).
  func newArray(of elementClass: UInt64, elementSize: Int32, count: Int) -> (object: UInt64, data: UInt64) {
    let arrayClass = alloc(0x120)
    memory.write(arrayClass + layout.classKind, UInt8(5))
    pointer(arrayClass + layout.classElementClass, elementClass)
    memory.write(arrayClass + layout.classSizes, elementSize)
    pointer(arrayClass + layout.className, cString("[]"))
    pointer(arrayClass + layout.classNamespace, cString(""))
    let object = alloc(Int(layout.arrayData) + count * Int(elementSize))
    pointer(object, vtable(for: arrayClass))
    memory.write(object + layout.arrayLength, UInt64(count))
    return (object, object + layout.arrayData)
  }

  /// Writes every image's class cache (one class per bucket, collisions chained through next_class_cache).
  func finishClassCaches() {
    for node in assemblyNodes {
      let classes = classesByImage[node.image] ?? []
      let size = max(64, classes.count)
      let buckets = alloc(size * 8)
      var heads = [UInt64](repeating: 0, count: size)
      for (index, klass) in classes.enumerated() {
        let bucket = index % size
        pointer(klass + layout.classNextCache, heads[bucket])
        heads[bucket] = klass
      }
      for (index, head) in heads.enumerated() { pointer(buckets + UInt64(index * 8), head) }
      memory.write(node.image + layout.imageClassCache + layout.hashTableSize, UInt32(size))
      pointer(node.image + layout.imageClassCache + layout.hashTableBuckets, buckets)
    }
  }

  func attach() throws -> MonoRuntime {
    try MonoRuntime.attach(memory: memory, allImageInfoAddress: allImageInfo)
  }
}
