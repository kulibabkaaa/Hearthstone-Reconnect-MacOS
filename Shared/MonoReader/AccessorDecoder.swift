import Foundation

/// One memory operand seen in an accessor function.
struct MemoryAccess: Equatable {
  enum Kind: Equatable {
    /// A load of `bits` into a register (`signed`: sign-extending, e.g. ldrsw / movslq).
    case load(bits: Int, signed: Bool)
    /// Address arithmetic: `add xd, xn, #imm` / `lea disp(base), reg`.
    case address
    /// A compare or test against memory (x86 `test`/`cmp`). Reads memory but produces no value.
    case compare
  }

  let kind: Kind
  /// The base register still held the function's first argument (x0 / rdi) or a copy of it.
  let baseIsArgument: Bool
  let displacement: Int64
}

/// What a short accessor function does with memory, in program order.
struct DecodedAccessor: Equatable {
  var accesses: [MemoryAccess] = []
  /// Target of a PC-relative load: arm64 `adrp` + `ldr`, x86_64 `mov reg, [rip + disp]`.
  var pcRelativeLoadTarget: UInt64?

  func firstLoad(bits: Int? = nil, signed: Bool? = nil, fromArgument: Bool = true, after: Int = -1) -> (index: Int, displacement: Int64)? {
    for (index, access) in accesses.enumerated() where index > after {
      guard case let .load(loadBits, isSigned) = access.kind else { continue }
      if let bits, loadBits != bits { continue }
      if let signed, isSigned != signed { continue }
      if fromArgument && !access.baseIsArgument { continue }
      return (index, access.displacement)
    }
    return nil
  }

  func firstAddress(fromArgument: Bool = true) -> Int64? {
    accesses.first { $0.kind == .address && (!fromArgument || $0.baseIsArgument) }?.displacement
  }

  func firstAccess(fromArgument: Bool = true) -> Int64? {
    accesses.first { !fromArgument || $0.baseIsArgument }?.displacement
  }
}

/// A deliberately small decoder for Mono's one-line accessor functions (`return klass->name;` and friends).
/// It recognises only the instruction shapes those functions use; anything else ends the decode, and a missing
/// operand then makes the layout unsupported instead of guessed.
enum AccessorDecoder {
  static let maxInstructions = 64
  static let maxJumps = 4

  /// `fetch(address)` returns code bytes starting at `address` (used to follow unconditional jumps).
  static func decode(at address: UInt64, architecture: CPUArchitecture, followConditionalBranches: Bool = false,
                     fetch: (UInt64) throws -> [UInt8]) throws -> DecodedAccessor {
    switch architecture {
    case .arm64: return try decodeARM64(at: address, followConditional: followConditionalBranches, fetch: fetch)
    case .x86_64: return try decodeX86(at: address, followConditional: followConditionalBranches, fetch: fetch)
    }
  }

  // MARK: arm64

  private static func signExtend(_ value: UInt64, bits: Int) -> Int64 {
    let shift = 64 - bits
    return Int64(bitPattern: value << UInt64(shift)) >> Int64(shift)
  }

  private static func decodeARM64(at start: UInt64, followConditional: Bool,
                                  fetch: (UInt64) throws -> [UInt8]) throws -> DecodedAccessor {
    var result = DecodedAccessor()
    var tracked: Set<UInt32> = [0]  // registers holding the first argument
    var pages: [UInt32: UInt64] = [:]  // adrp results
    var pc = start
    var code = try fetch(pc)
    var codeBase = pc
    var jumps = 0

    func written(_ register: UInt32) { tracked.remove(register); pages[register] = nil }

    for _ in 0..<maxInstructions {
      if pc - codeBase + 4 > UInt64(code.count) { codeBase = pc; code = try fetch(pc) }
      guard pc - codeBase + 4 <= UInt64(code.count) else { break }
      let word = code.withUnsafeBytes { $0.loadUnaligned(fromByteOffset: Int(pc - codeBase), as: UInt32.self) }
      let rd = word & 31
      let rn = (word >> 5) & 31

      if word == 0xd65f_03c0 { break }  // ret
      if word & 0xfc00_0000 == 0x1400_0000 {  // b imm26
        guard jumps < maxJumps else { break }
        jumps += 1
        pc = UInt64(bitPattern: Int64(bitPattern: pc) &+ signExtend(UInt64(word & 0x03ff_ffff), bits: 26) * 4)
        continue
      }
      if word & 0xfc00_0000 == 0x9400_0000 {  // bl: the callee may change x0-x18
        tracked.subtract(0...18)
        pages = pages.filter { $0.key > 18 }
        pc += 4
        continue
      }
      let conditionalTarget: UInt64?
      if word & 0x7e00_0000 == 0x3600_0000 {  // tbz / tbnz imm14
        conditionalTarget = UInt64(bitPattern: Int64(bitPattern: pc) &+ signExtend(UInt64((word >> 5) & 0x3fff), bits: 14) * 4)
      } else if word & 0x7e00_0000 == 0x3400_0000 || word & 0xff00_0010 == 0x5400_0000 {  // cbz/cbnz, b.cond imm19
        conditionalTarget = UInt64(bitPattern: Int64(bitPattern: pc) &+ signExtend(UInt64((word >> 5) & 0x7ffff), bits: 19) * 4)
      } else {
        conditionalTarget = nil
      }
      if let conditionalTarget {
        if followConditional {
          guard jumps < maxJumps else { break }
          jumps += 1
          pc = conditionalTarget
        } else {
          pc += 4
        }
        continue
      }

      if word & 0x9f00_0000 == 0x9000_0000 {  // adrp
        let immlo = UInt64((word >> 29) & 0x3)
        let immhi = UInt64((word >> 5) & 0x7ffff)
        let offset = signExtend((immhi << 2 | immlo) << 12, bits: 33)
        written(rd)
        pages[rd] = UInt64(bitPattern: Int64(bitPattern: pc & ~0xfff) &+ offset)
      } else if word & 0x3f00_0000 == 0x3900_0000 {  // ldr/ldrb/ldrh/ldrs* (unsigned immediate), or str
        let size = word >> 30
        let opc = (word >> 22) & 3
        let displacement = Int64((word >> 10) & 0xfff) << Int64(size)
        if opc != 0 {  // opc 0 is a store
          let signed = opc >= 2
          result.accesses.append(MemoryAccess(kind: .load(bits: 8 << Int(size), signed: signed),
                                              baseIsArgument: tracked.contains(rn), displacement: displacement))
          if let page = pages[rn], size == 3, !signed { result.pcRelativeLoadTarget = page &+ UInt64(displacement) }
          written(rd)
        }
      } else if word & 0xff80_0000 == 0x9100_0000 {  // add xd, xn, #imm{, lsl #12}
        let shift: Int64 = (word >> 22) & 1 == 1 ? 12 : 0
        let displacement = Int64((word >> 10) & 0xfff) << shift
        if rn != 31 { result.accesses.append(MemoryAccess(kind: .address, baseIsArgument: tracked.contains(rn), displacement: displacement)) }
        if let page = pages[rn] { written(rd); pages[rd] = page &+ UInt64(displacement) } else { written(rd) }
      } else if word & 0xffe0_ffe0 == 0xaa00_03e0 {  // mov xd, xm (orr xd, xzr, xm)
        let rm = (word >> 16) & 31
        let copies = tracked.contains(rm)
        written(rd)
        if copies { tracked.insert(rd) }
      } else if word & 0x3a00_0000 == 0x2800_0000 {
        // stp/ldp: frame setup and teardown. ldp writes two registers.
        if (word >> 22) & 1 == 1 { written(rd); written((word >> 10) & 31) }
      } else if word & 0x3b20_0c00 == 0x3820_0800 || word & 0x3f00_0000 == 0x3800_0000 {
        // register-offset / pre-post-index load-store: not an accessor shape; treat the target as clobbered.
        written(rd)
      } else {
        // Any other data-processing instruction writes Rd.
        written(rd)
      }
      pc += 4
    }
    return result
  }

  // MARK: x86_64

  private struct ModRM {
    var mod: UInt8
    var reg: UInt8
    var rm: UInt8  // register number (with REX.B) when mod == 3
    var base: UInt8?  // nil for rip-relative or no base
    var hasIndex: Bool
    var ripRelative: Bool
    var displacement: Int64
    var length: Int
  }

  private static func modRM(_ code: [UInt8], _ at: Int, rex: UInt8) -> ModRM? {
    guard at < code.count else { return nil }
    let byte = code[at]
    let mod = byte >> 6
    let reg = ((byte >> 3) & 7) | ((rex & 0x4) << 1)
    let rmLow = byte & 7
    var length = 1
    var base: UInt8?
    var hasIndex = false
    var rip = false
    if mod == 3 {
      return ModRM(mod: 3, reg: reg, rm: rmLow | ((rex & 0x1) << 3), base: nil, hasIndex: false, ripRelative: false,
                   displacement: 0, length: 1)
    }
    var dispSize = mod == 1 ? 1 : (mod == 2 ? 4 : 0)
    if rmLow == 4 {  // SIB
      guard at + 1 < code.count else { return nil }
      let sib = code[at + 1]
      length += 1
      let index = ((sib >> 3) & 7) | ((rex & 0x2) << 2)
      hasIndex = index != 4
      let baseLow = sib & 7
      if baseLow == 5 && mod == 0 { dispSize = 4 } else { base = baseLow | ((rex & 0x1) << 3) }
    } else if rmLow == 5 && mod == 0 {
      rip = true
      dispSize = 4
    } else {
      base = rmLow | ((rex & 0x1) << 3)
    }
    guard at + length + dispSize <= code.count else { return nil }
    var displacement: Int64 = 0
    if dispSize == 1 { displacement = Int64(Int8(bitPattern: code[at + length])) }
    if dispSize == 4 {
      displacement = Int64(code.withUnsafeBytes { $0.loadUnaligned(fromByteOffset: at + length, as: Int32.self) })
    }
    length += dispSize
    return ModRM(mod: mod, reg: reg, rm: rmLow, base: base, hasIndex: hasIndex, ripRelative: rip,
                 displacement: displacement, length: length)
  }

  private static func decodeX86(at start: UInt64, followConditional: Bool,
                                fetch: (UInt64) throws -> [UInt8]) throws -> DecodedAccessor {
    let rdi: UInt8 = 7
    let callerSaved: Set<UInt8> = [0, 1, 2, 6, 7, 8, 9, 10, 11]
    var result = DecodedAccessor()
    var tracked: Set<UInt8> = [rdi]
    var pc = start
    var code = try fetch(pc)
    var jumps = 0
    var offset = 0

    func jump(to target: UInt64) throws -> Bool {
      guard jumps < maxJumps else { return false }
      jumps += 1
      pc = target
      code = try fetch(pc)
      offset = 0
      return true
    }

    instructionLoop: for _ in 0..<maxInstructions {
      if offset + 16 > code.count { pc += UInt64(offset); code = try fetch(pc); offset = 0 }
      guard offset < code.count else { break }
      let instructionStart = offset
      var rex: UInt8 = 0
      var operandSize16 = false
      while offset < code.count, [0x66, 0x2e, 0xf2, 0xf3].contains(code[offset]) {
        if code[offset] == 0x66 { operandSize16 = true }
        offset += 1
      }
      if offset < code.count, code[offset] & 0xf0 == 0x40 { rex = code[offset]; offset += 1 }
      guard offset < code.count else { break }
      let rexW = rex & 0x8 != 0
      let opcode = code[offset]
      offset += 1
      func nextAddress() -> UInt64 { pc + UInt64(offset) }

      func memoryOperand(_ m: ModRM, kind: MemoryAccess.Kind) {
        if m.ripRelative {
          if case .load = kind { result.pcRelativeLoadTarget = UInt64(bitPattern: Int64(bitPattern: nextAddress()) &+ m.displacement) }
          return
        }
        result.accesses.append(MemoryAccess(kind: kind, baseIsArgument: m.base.map { tracked.contains($0) } ?? false,
                                            displacement: m.displacement))
      }

      switch opcode {
      case 0xc3: break instructionLoop  // ret
      case 0x90: continue  // nop
      case 0x50...0x57: continue  // push
      case 0x58...0x5f: tracked.remove((opcode - 0x58) | ((rex & 1) << 3))  // pop
      case 0xe8:  // call rel32
        offset += 4
        tracked.subtract(callerSaved)
      case 0xe9, 0xeb:  // jmp rel32 / rel8
        let size = opcode == 0xe9 ? 4 : 1
        guard offset + size <= code.count else { break instructionLoop }
        let rel = size == 4
          ? Int64(code.withUnsafeBytes { $0.loadUnaligned(fromByteOffset: offset, as: Int32.self) })
          : Int64(Int8(bitPattern: code[offset]))
        offset += size
        guard try jump(to: UInt64(bitPattern: Int64(bitPattern: nextAddress()) &+ rel)) else { break instructionLoop }
      case 0x70...0x7f:  // jcc rel8
        guard offset < code.count else { break instructionLoop }
        let rel = Int64(Int8(bitPattern: code[offset]))
        offset += 1
        if followConditional { guard try jump(to: UInt64(bitPattern: Int64(bitPattern: nextAddress()) &+ rel)) else { break instructionLoop } }
      case 0x88, 0x89, 0x8a, 0x8b, 0x8d, 0x63, 0x84, 0x85, 0x01, 0x03, 0x09, 0x0b, 0x21, 0x23, 0x29, 0x2b,
           0x31, 0x33, 0x39, 0x3b, 0xd1, 0xc1, 0x80, 0x81, 0x83, 0xf6, 0xf7, 0xc7, 0xc6:
        guard let m = modRM(code, offset, rex: rex) else { break instructionLoop }
        offset += m.length
        switch opcode {
        case 0xc1, 0x80, 0x83, 0xc6: offset += 1
        case 0x81, 0xc7: offset += operandSize16 ? 2 : 4
        case 0xf6 where m.reg & 7 == 0: offset += 1
        case 0xf7 where m.reg & 7 == 0: offset += operandSize16 ? 2 : 4
        default: break
        }
        let bits = rexW ? 64 : (operandSize16 ? 16 : 32)
        switch opcode {
        case 0x8b, 0x8a:  // mov reg, r/m
          if m.mod == 3 {
            let copies = tracked.contains(m.rm)
            tracked.remove(m.reg)
            if copies && opcode == 0x8b && rexW { tracked.insert(m.reg) }
          } else {
            memoryOperand(m, kind: .load(bits: opcode == 0x8a ? 8 : bits, signed: false))
            tracked.remove(m.reg)
          }
        case 0x89:  // mov r/m, reg
          if m.mod == 3 {
            let copies = tracked.contains(m.reg)
            tracked.remove(m.rm)
            if copies && rexW { tracked.insert(m.rm) }
          }
        case 0x63:  // movsxd
          if m.mod != 3 { memoryOperand(m, kind: .load(bits: 32, signed: true)) }
          tracked.remove(m.reg)
        case 0x8d:  // lea
          memoryOperand(m, kind: .address)
          tracked.remove(m.reg)
        case 0x84, 0x85, 0x39, 0x3b, 0xf6, 0xf7, 0x80, 0x81, 0x83:
          let isCompare = [0x84, 0x85, 0x39, 0x3b].contains(opcode) || (m.reg & 7 == 7 && [0x80, 0x81, 0x83].contains(opcode))
            || ((opcode == 0xf6 || opcode == 0xf7) && m.reg & 7 == 0)
          if m.mod != 3 { memoryOperand(m, kind: .compare) } else if !isCompare { tracked.remove(m.rm) }
        case 0x03, 0x0b, 0x23, 0x2b, 0x33:
          tracked.remove(m.reg)
        default:  // 0x01, 0x09, 0x21, 0x29, 0x31, shifts, c6/c7 stores
          if m.mod == 3 { tracked.remove(m.rm) }
        }
      case 0x0f:
        guard offset < code.count else { break instructionLoop }
        let second = code[offset]
        offset += 1
        switch second {
        case 0x80...0x8f:  // jcc rel32
          guard offset + 4 <= code.count else { break instructionLoop }
          let rel = Int64(code.withUnsafeBytes { $0.loadUnaligned(fromByteOffset: offset, as: Int32.self) })
          offset += 4
          if followConditional { guard try jump(to: UInt64(bitPattern: Int64(bitPattern: nextAddress()) &+ rel)) else { break instructionLoop } }
        case 0xb6, 0xb7, 0xbe, 0xbf, 0xaf, 0x1f:
          guard let m = modRM(code, offset, rex: rex) else { break instructionLoop }
          offset += m.length
          if second == 0x1f { continue }  // multi-byte nop
          if m.mod != 3, second != 0xaf {
            memoryOperand(m, kind: .load(bits: (second & 1) == 0 ? 8 : 16, signed: second >= 0xbe))
          }
          tracked.remove(m.reg)
        default:
          break instructionLoop
        }
      case 0xb8...0xbf:  // mov reg, imm
        offset += rexW ? 8 : 4
        tracked.remove((opcode - 0xb8) | ((rex & 1) << 3))
      default:
        break instructionLoop
      }
      _ = instructionStart
    }
    return result
  }
}
