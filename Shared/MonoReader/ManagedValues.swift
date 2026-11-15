import Foundation

/// A managed object, or a struct stored inline (in an array or another object). Field offsets are applied to
/// `fieldBase`: the object's address, or the struct's data address minus the object header (Mono's field
/// offsets for value types count the header they'd have when boxed).
public struct ManagedRef: Equatable, Sendable {
  public let fieldBase: UInt64
  public let klass: UInt64
  public let isInlineStruct: Bool
}

extension MonoRuntime {
  public func object(at pointer: UInt64) throws -> ManagedRef? {
    guard pointer != 0 else { return nil }
    return ManagedRef(fieldBase: pointer, klass: try classOf(object: pointer), isInlineStruct: false)
  }

  /// The object stored in a class's static field, e.g. `GameState.s_instance`. Nil while unset.
  public func staticObject(_ className: String, _ fieldName: String, in assembly: String = "Assembly-CSharp") throws -> ManagedRef? {
    guard let klass = try findClass(className, in: assembly),
          let field = try field(fieldName, in: klass), field.isStatic, !field.isLiteral,
          let storage = try staticStorage(klass) else { return nil }
    guard isReference(field) else { throw MonoReaderError.invalidData("\(className).\(fieldName) is not a reference") }
    return try object(at: try reader.pointer(storage + UInt64(UInt32(bitPattern: field.offset))))
  }

  private func isReference(_ field: MonoField) -> Bool {
    switch field.typeCode {
    case MonoTypeCode.classType, MonoTypeCode.object, MonoTypeCode.szArray, MonoTypeCode.array, MonoTypeCode.string: return true
    case MonoTypeCode.genericInstance:
      // MonoGenericClass.container_class is the first field; a generic struct is stored inline.
      guard let definition = try? reader.pointer(field.typeData), definition != 0 else { return false }
      return (try? isValueType(definition)) == false
    default: return false
    }
  }

  private func instanceField(_ ref: ManagedRef, _ name: String) throws -> (MonoField, UInt64) {
    guard let field = try field(name, in: ref.klass), !field.isStatic else {
      throw MonoReaderError.notFound("field \(name) on \(try fullName(ref.klass))")
    }
    return (field, ref.fieldBase + UInt64(UInt32(bitPattern: field.offset)))
  }

  /// A reference-typed field (object, array, or boxed generic class). Nil when null.
  public func objectField(_ ref: ManagedRef, _ name: String) throws -> ManagedRef? {
    let (field, address) = try instanceField(ref, name)
    guard isReference(field) else { throw MonoReaderError.invalidData("\(name) is not a reference") }
    return try object(at: try reader.pointer(address))
  }

  /// A non-generic struct field stored inline.
  public func structField(_ ref: ManagedRef, _ name: String) throws -> ManagedRef {
    let (field, address) = try instanceField(ref, name)
    guard field.typeCode == MonoTypeCode.valueType, field.typeData != 0 else {
      throw MonoReaderError.invalidData("\(name) is not an inline struct")
    }
    return ManagedRef(fieldBase: address - layout.objectHeader, klass: field.typeData, isInlineStruct: true)
  }

  /// An object field or an inline struct field, whichever the field is. Nil for a null object.
  public func child(_ ref: ManagedRef, _ name: String) throws -> ManagedRef? {
    let (field, _) = try instanceField(ref, name)
    return field.typeCode == MonoTypeCode.valueType ? try structField(ref, name) : try objectField(ref, name)
  }

  public func path(_ ref: ManagedRef?, _ names: String...) throws -> ManagedRef? {
    var current = ref
    for name in names {
      guard let value = current else { return nil }
      current = try child(value, name)
    }
    return current
  }

  public func stringField(_ ref: ManagedRef, _ name: String) throws -> String? {
    let (field, address) = try instanceField(ref, name)
    guard field.typeCode == MonoTypeCode.string else { throw MonoReaderError.invalidData("\(name) is not a string") }
    return try string(at: try reader.pointer(address))
  }

  /// A managed System.String's text. Nil for null.
  public func string(at pointer: UInt64) throws -> String? {
    guard pointer != 0 else { return nil }
    let length = try reader.i32(pointer + layout.stringLength)
    guard length >= 0, length <= 8192 else { throw MonoReaderError.invalidData("string length \(length)") }
    return try reader.utf16String(pointer + layout.stringChars, units: Int(length))
  }

  /// A 32-bit integer field (int, uint, or an int-backed enum).
  public func int32Field(_ ref: ManagedRef, _ name: String) throws -> Int32 {
    let (field, address) = try instanceField(ref, name)
    switch field.typeCode {
    case MonoTypeCode.i4, MonoTypeCode.u4: return try reader.i32(address)
    case MonoTypeCode.valueType where try isEnum(field.typeData) && enumUnderlyingIs32Bit(field.typeData):
      return try reader.i32(address)
    default: throw MonoReaderError.invalidData("\(name) is not a 32-bit integer (type 0x\(String(field.typeCode, radix: 16)))")
    }
  }

  /// A 64-bit integer field (long or ulong), as its bit pattern.
  public func int64Field(_ ref: ManagedRef, _ name: String) throws -> Int64 {
    let (field, address) = try instanceField(ref, name)
    guard field.typeCode == MonoTypeCode.i8 || field.typeCode == MonoTypeCode.u8 else {
      throw MonoReaderError.invalidData("\(name) is not a 64-bit integer")
    }
    return try reader.i64(address)
  }

  public func boolField(_ ref: ManagedRef, _ name: String) throws -> Bool {
    let (field, address) = try instanceField(ref, name)
    guard field.typeCode == MonoTypeCode.boolean else { throw MonoReaderError.invalidData("\(name) is not a bool") }
    return try reader.u8(address) != 0
  }

  private func enumUnderlyingIs32Bit(_ enumClass: UInt64) throws -> Bool {
    // An enum's only instance field ("value__") has the underlying type.
    guard let value = try ownFields(enumClass).first(where: { !$0.isStatic }) else { return false }
    return value.typeCode == MonoTypeCode.i4 || value.typeCode == MonoTypeCode.u4
  }

  // MARK: Arrays

  public struct ArrayInfo {
    public let length: Int
    public let elementClass: UInt64
    public let elementSize: UInt64
    public let elementIsValueType: Bool
    public let data: UInt64
  }

  public func arrayInfo(_ array: ManagedRef) throws -> ArrayInfo {
    let length = try reader.u64(array.fieldBase + layout.arrayLength)
    guard length <= 1_000_000 else { throw MonoReaderError.invalidData("array length \(length)") }
    let elementClass = try reader.pointer(array.klass + layout.classElementClass)
    guard elementClass != 0 else { throw MonoReaderError.invalidData("array without element class") }
    let elementSize = UInt64(try reader.i32(array.klass + layout.classSizes))
    let isValueType = try isValueType(elementClass)
    guard elementSize > 0, elementSize <= 4096, isValueType || elementSize == 8 else {
      throw MonoReaderError.invalidData("array element size \(elementSize)")
    }
    return ArrayInfo(length: Int(length), elementClass: elementClass, elementSize: elementSize,
                     elementIsValueType: isValueType, data: array.fieldBase + layout.arrayData)
  }

  /// Element `index`: an object (nil when null) or an inline struct.
  public func element(_ info: ArrayInfo, _ index: Int) throws -> ManagedRef? {
    guard index >= 0, index < info.length else { throw MonoReaderError.invalidData("index \(index) of \(info.length)") }
    let slot = info.data + UInt64(index) * info.elementSize
    if info.elementIsValueType {
      return ManagedRef(fieldBase: slot - layout.objectHeader, klass: info.elementClass, isInlineStruct: true)
    }
    return try object(at: try reader.pointer(slot))
  }

  /// Element `index` of an int[] / uint[].
  public func int32Element(_ info: ArrayInfo, _ index: Int) throws -> Int32 {
    guard index >= 0, index < info.length, info.elementSize == 4 else { throw MonoReaderError.invalidData("int32 element") }
    return try reader.i32(info.data + UInt64(index) * 4)
  }

  // MARK: Collections

  private func requireGeneric(_ ref: ManagedRef, named definitionName: String) throws {
    guard let definition = try genericDefinition(ref.klass), try fullName(definition) == definitionName else {
      throw MonoReaderError.invalidData("\(try fullName(ref.klass)) is not a \(definitionName)")
    }
  }

  /// Items of a System.Collections.Generic.List<T> of a reference type.
  public func listItems(_ list: ManagedRef) throws -> [ManagedRef?] {
    try requireGeneric(list, named: "System.Collections.Generic.List`1")
    let size = Int(try int32Field(list, "_size"))
    guard let items = try objectField(list, "_items") else { return [] }
    let info = try arrayInfo(items)
    guard size >= 0, size <= info.length else { throw MonoReaderError.invalidData("list size \(size)") }
    return try (0..<size).map { try element(info, $0) }
  }

  /// Live entries of a System.Collections.Generic.Dictionary<TKey, TValue> (the Entry structs).
  public func dictionaryEntries(_ dictionary: ManagedRef) throws -> [ManagedRef] {
    try requireGeneric(dictionary, named: "System.Collections.Generic.Dictionary`2")
    let countField = try field("_count", in: dictionary.klass) != nil ? "_count" : "count"
    let entriesField = try field("_entries", in: dictionary.klass) != nil ? "_entries" : "entries"
    let count = Int(try int32Field(dictionary, countField))
    guard let entries = try objectField(dictionary, entriesField) else { return [] }
    let info = try arrayInfo(entries)
    guard count >= 0, count <= info.length, info.elementIsValueType else { throw MonoReaderError.invalidData("dictionary") }
    var result: [ManagedRef] = []
    for index in 0..<count {
      guard let entry = try element(info, index) else { continue }
      // A removed entry has next < -1 (newer BCL) or hashCode < 0 (older BCL).
      if try field("next", in: entry.klass) != nil, try int32Field(entry, "next") < -1 { continue }
      if try field("hashCode", in: entry.klass) != nil, try int32Field(entry, "hashCode") < 0, try field("next", in: entry.klass) == nil { continue }
      result.append(entry)
    }
    return result
  }

  /// Live slots of a Blizzard.T5.Core.Map<TKey, TValue> (Mono's classic Dictionary design: `touchedSlots`
  /// slots in use, a slot is live when its link's HashCode has the high bit set). Returns slot indexes plus
  /// the key and value arrays.
  public func mapSlots(_ map: ManagedRef) throws -> (slots: [Int], keys: ArrayInfo?, values: ArrayInfo?) {
    try requireGeneric(map, named: "Blizzard.T5.Core.Map`2")
    let touched = Int(try int32Field(map, "touchedSlots"))
    guard let links = try objectField(map, "linkSlots") else { return ([], nil, nil) }
    let linkInfo = try arrayInfo(links)
    guard touched >= 0, touched <= linkInfo.length, linkInfo.elementIsValueType else { throw MonoReaderError.invalidData("map") }
    let keys = try objectField(map, "keySlots").map(arrayInfo)
    let values = try objectField(map, "valueSlots").map(arrayInfo)
    var live: [Int] = []
    for index in 0..<touched {
      guard let link = try element(linkInfo, index) else { continue }
      if UInt32(bitPattern: try int32Field(link, "HashCode")) & 0x8000_0000 != 0 { live.append(index) }
    }
    guard live.allSatisfy({ $0 < (keys?.length ?? 0) && $0 < (values?.length ?? 0) }) else {
      throw MonoReaderError.invalidData("map slots out of range")
    }
    return (live, keys, values)
  }
}
