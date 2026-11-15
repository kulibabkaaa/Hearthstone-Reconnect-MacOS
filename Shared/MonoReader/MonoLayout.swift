import Foundation

/// Byte offsets inside Mono's runtime structures for the running build.
///
/// Every offset that a one-line exported accessor reads (`mono_class_get_name` is `return klass->name;`) is taken
/// from that accessor's machine code at attach time, for whichever CPU slice the game runs. The rest have no such
/// accessor; they come from `knownInternals`, and `MonoRuntime`'s self-check proves them against facts every
/// mscorlib has (System.String's fields and its static `Empty`). Anything unrecognised or failing the check
/// makes the reader give no data.
public struct MonoLayout: Equatable, Sendable {
  // From accessor code.
  public var assemblyName: UInt64
  public var assemblyImage: UInt64
  public var classElementClass: UInt64
  public var classKind: UInt64
  public var classBits: UInt64
  public var classParent: UInt64
  public var classNestedIn: UInt64
  public var classImage: UInt64
  public var className: UInt64
  public var classNamespace: UInt64
  public var classSizes: UInt64
  public var classFields: UInt64
  public var classByValArg: UInt64
  public var fieldType: UInt64
  public var fieldName: UInt64
  public var fieldOffset: UInt64
  public var typeCode: UInt64
  public var stringLength: UInt64
  public var stringChars: UInt64
  public var arrayLength: UInt64
  public var arrayData: UInt64
  public var classVTableSize: UInt64
  public var vtableSlots: UInt64

  // No accessor: verified by the self-check (see MonoRuntime.validateLayout()).
  public var classRuntimeInfo: UInt64
  public var classGenericClass: UInt64
  public var classFieldCount: UInt64
  public var classNextCache: UInt64
  public var domainID: UInt64
  public var runtimeInfoDomainVTables: UInt64
  public var typeAttributes: UInt64
  public var fieldSize: UInt64
  public var objectHeader: UInt64
  public var hashTableSize: UInt64
  public var hashTableBuckets: UInt64
  public var valueTypeBit: UInt32
  public var enumBit: UInt32

  // Found by scanning live structures (no accessor, no stable constant): set by MonoRuntime.
  public var domainAssemblies: UInt64 = 0
  public var imageClassCache: UInt64 = 0

  /// Internal offsets of Unity 6000.3's Mono (MonoBleedingEdge) on macOS, read from the code of internal
  /// helpers in libmonobdwgc-2.0.dylib: mono_class_get_field_count (generic_class 0xe8, field_count 0xf8),
  /// mono_class_try_get_vtable (runtime_info 0xc8, domain_id 0xa4, domain_vtables +8). Identical in the
  /// arm64 and x86_64 slices. Note: Windows builds differ (Firestone's PE table is 8 bytes off from `parent`).
  public static let knownInternals = (
    classRuntimeInfo: UInt64(0xc8), classGenericClass: UInt64(0xe8), classFieldCount: UInt64(0xf8),
    classNextCache: UInt64(0x100), domainID: UInt64(0xa4), runtimeInfoDomainVTables: UInt64(8),
    typeAttributes: UInt64(8), fieldSize: UInt64(32), objectHeader: UInt64(16),
    hashTableSize: UInt64(24), hashTableBuckets: UInt64(32), valueTypeBit: UInt32(2), enumBit: UInt32(3)
  )

  /// The exported functions the layout is read from.
  public static let accessorSymbols: [String] = [
    "_mono_assembly_get_name", "_mono_assembly_get_image", "_mono_class_get_element_class", "_mono_class_get_flags",
    "_mono_class_is_valuetype", "_mono_class_get_parent", "_mono_class_get_nesting_type", "_mono_class_get_image",
    "_mono_class_get_name", "_mono_class_get_namespace", "_mono_array_element_size", "_mono_class_get_fields",
    "_mono_class_get_type", "_mono_field_get_type", "_mono_field_get_name", "_mono_field_get_offset",
    "_mono_type_get_type", "_mono_string_length", "_mono_string_chars", "_mono_array_length",
    "_mono_array_addr_with_size", "_mono_vtable_get_static_field_data",
  ]
  public static let rootDomainSymbol = "_mono_get_root_domain"

  /// Reads the layout from the accessor code. `fetch(address)` returns code bytes at `address` in the target.
  public static func derive(symbols: [String: UInt64], architecture: CPUArchitecture,
                            fetch: (UInt64) throws -> [UInt8]) throws -> MonoLayout {
    func decoded(_ symbol: String, followConditional: Bool = false) throws -> DecodedAccessor {
      guard let address = symbols[symbol] else { throw MonoReaderError.unsupportedLayout("missing export \(symbol)") }
      return try AccessorDecoder.decode(at: address, architecture: architecture,
                                        followConditionalBranches: followConditional, fetch: fetch)
    }
    func offset(_ value: Int64?, _ symbol: String, pointerAligned: Bool = false) throws -> UInt64 {
      guard let value, value >= 0, value < 0x1000, !pointerAligned || value % 8 == 0 else {
        throw MonoReaderError.unsupportedLayout("unrecognised code in \(symbol)")
      }
      return UInt64(value)
    }
    func load64(_ symbol: String) throws -> UInt64 {
      try offset(try decoded(symbol).firstLoad(bits: 64)?.displacement, symbol, pointerAligned: true)
    }
    func load32(_ symbol: String) throws -> UInt64 {
      try offset(try decoded(symbol).firstLoad(bits: 32)?.displacement, symbol)
    }

    let staticData = try decoded("_mono_vtable_get_static_field_data", followConditional: true)
    guard let size = staticData.firstLoad(bits: 32, signed: true, fromArgument: false),
          let slots = staticData.firstLoad(bits: 64, fromArgument: false, after: size.index) else {
      throw MonoReaderError.unsupportedLayout("unrecognised code in _mono_vtable_get_static_field_data")
    }
    let internals = knownInternals
    return MonoLayout(
      assemblyName: try offset(try decoded("_mono_assembly_get_name").firstAddress(), "_mono_assembly_get_name"),
      assemblyImage: try load64("_mono_assembly_get_image"),
      classElementClass: try load64("_mono_class_get_element_class"),
      classKind: try offset(try decoded("_mono_class_get_flags").firstLoad(bits: 8)?.displacement, "_mono_class_get_flags"),
      classBits: try offset(try decoded("_mono_class_is_valuetype").firstAccess(), "_mono_class_is_valuetype"),
      classParent: try load64("_mono_class_get_parent"),
      classNestedIn: try load64("_mono_class_get_nesting_type"),
      classImage: try load64("_mono_class_get_image"),
      className: try load64("_mono_class_get_name"),
      classNamespace: try load64("_mono_class_get_namespace"),
      classSizes: try load32("_mono_array_element_size"),
      classFields: try load64("_mono_class_get_fields"),
      classByValArg: try offset(try decoded("_mono_class_get_type").firstAddress(), "_mono_class_get_type", pointerAligned: true),
      fieldType: try load64("_mono_field_get_type"),
      fieldName: try load64("_mono_field_get_name"),
      fieldOffset: try load32("_mono_field_get_offset"),
      typeCode: try offset(try decoded("_mono_type_get_type").firstLoad(bits: 8)?.displacement, "_mono_type_get_type"),
      stringLength: try load32("_mono_string_length"),
      stringChars: try offset(try decoded("_mono_string_chars").firstAddress(), "_mono_string_chars"),
      arrayLength: try load32("_mono_array_length"),
      arrayData: try offset(try decoded("_mono_array_addr_with_size").firstAddress(fromArgument: false),
                            "_mono_array_addr_with_size", pointerAligned: true),
      classVTableSize: try offset(size.displacement, "_mono_vtable_get_static_field_data"),
      vtableSlots: try offset(slots.displacement, "_mono_vtable_get_static_field_data", pointerAligned: true),
      classRuntimeInfo: internals.classRuntimeInfo,
      classGenericClass: internals.classGenericClass,
      classFieldCount: internals.classFieldCount,
      classNextCache: internals.classNextCache,
      domainID: internals.domainID,
      runtimeInfoDomainVTables: internals.runtimeInfoDomainVTables,
      typeAttributes: internals.typeAttributes,
      fieldSize: internals.fieldSize,
      objectHeader: internals.objectHeader,
      hashTableSize: internals.hashTableSize,
      hashTableBuckets: internals.hashTableBuckets,
      valueTypeBit: internals.valueTypeBit,
      enumBit: internals.enumBit
    )
  }

  /// The global `mono_root_domain` that `mono_get_root_domain` returns.
  public static func rootDomainGlobal(function: UInt64, architecture: CPUArchitecture,
                                      fetch: (UInt64) throws -> [UInt8]) throws -> UInt64 {
    let decoded = try AccessorDecoder.decode(at: function, architecture: architecture, fetch: fetch)
    guard let target = decoded.pcRelativeLoadTarget else {
      throw MonoReaderError.unsupportedLayout("unrecognised code in mono_get_root_domain")
    }
    return target
  }
}
