import Foundation
import Testing

@testable import MonoReader

private func symbols(_ architecture: CPUArchitecture) -> [String: UInt64] {
  let chunks = architecture == .arm64 ? AccessorCodeFixture.arm64 : AccessorCodeFixture.x86_64
  return Dictionary(uniqueKeysWithValues: chunks.map { ($0.symbol, $0.address) })
}

/// Code fetch over the fixture chunks (addresses relative to the image).
private func fetcher(_ architecture: CPUArchitecture) -> (UInt64) throws -> [UInt8] {
  let chunks = (architecture == .arm64 ? AccessorCodeFixture.arm64 : AccessorCodeFixture.x86_64)
    .map { ($0.address, FakeMono.bytes(hex: $0.hex)) }
  return { address in
    // Windows overlap; use the one with the most code after `address`.
    let longest = chunks.filter { address >= $0.0 && address < $0.0 + UInt64($0.1.count) }
      .map { Array($0.1[Int(address - $0.0)...]) }
      .max { $0.count < $1.count }
    guard let longest else { throw MonoReaderError.readFailed(address: address, count: 64) }
    return longest
  }
}

@Suite("Mono layout from accessor code")
struct MonoLayoutTests {
  @Test("both CPU slices of Hearthstone's Mono give the same, measured layout", arguments: [CPUArchitecture.arm64, .x86_64])
  func derivesMeasuredLayout(architecture: CPUArchitecture) throws {
    var layout = try MonoLayout.derive(symbols: symbols(architecture), architecture: architecture, fetch: fetcher(architecture))
    layout.domainAssemblies = expectedLayout.domainAssemblies
    layout.imageClassCache = expectedLayout.imageClassCache
    #expect(layout == expectedLayout)
  }

  @Test("the root-domain global is decoded from mono_get_root_domain on both CPUs")
  func rootDomainGlobal() throws {
    let arm = try MonoLayout.rootDomainGlobal(function: symbols(.arm64)["_mono_get_root_domain"]!, architecture: .arm64,
                                              fetch: fetcher(.arm64))
    let intel = try MonoLayout.rootDomainGlobal(function: symbols(.x86_64)["_mono_get_root_domain"]!, architecture: .x86_64,
                                                fetch: fetcher(.x86_64))
    #expect(arm == 0x30_ae80)  // adrp x8, 0x30a000; ldr x0, [x8, #0xe80]
    #expect(intel == 0x32_d288)  // movq 0x1e7518(%rip), %rax at 0x145d69
  }

  @Test("an accessor whose code isn't recognised makes the layout unsupported", arguments: [CPUArchitecture.arm64, .x86_64])
  func unrecognisedCode(architecture: CPUArchitecture) throws {
    let base = fetcher(architecture)
    let nameAccessor = symbols(architecture)["_mono_class_get_name"]!
    let undefined: [UInt8] = architecture == .arm64 ? [0, 0, 0, 0] : [0x0f, 0x0b]  // udf #0 / ud2
    let fetch: (UInt64) throws -> [UInt8] = { address in
      if address >= nameAccessor && address < nameAccessor + 64 { return undefined + [UInt8](repeating: 0, count: 60) }
      return try base(address)
    }
    #expect(throws: MonoReaderError.unsupportedLayout("unrecognised code in _mono_class_get_name")) {
      try MonoLayout.derive(symbols: symbols(architecture), architecture: architecture, fetch: fetch)
    }
  }

  @Test("an accessor reading a different offset changes the layout instead of being ignored")
  func followsTheCode() throws {
    let base = fetcher(.arm64)
    let nameAccessor = symbols(.arm64)["_mono_class_get_name"]!
    // ldr x0, [x0, #0x50]; ret
    let patched: [UInt8] = [0x00, 0x28, 0x40, 0xf9, 0xc0, 0x03, 0x5f, 0xd6]
    let fetch: (UInt64) throws -> [UInt8] = { address in
      address == nameAccessor ? patched : try base(address)
    }
    let layout = try MonoLayout.derive(symbols: symbols(.arm64), architecture: .arm64, fetch: fetch)
    #expect(layout.className == 0x50)
  }

  @Test("a missing export makes the layout unsupported")
  func missingExport() {
    var exports = symbols(.x86_64)
    exports["_mono_field_get_offset"] = nil
    #expect(throws: MonoReaderError.unsupportedLayout("missing export _mono_field_get_offset")) {
      try MonoLayout.derive(symbols: exports, architecture: .x86_64, fetch: fetcher(.x86_64))
    }
  }
}

@Suite("Mono runtime attach")
struct MonoRuntimeAttachTests {
  private func ready(_ architecture: CPUArchitecture, configure: (FakeMono) -> Void = { _ in }) -> FakeMono {
    let fake = FakeMono(architecture: architecture)
    fake.makeRuntime()
    configure(fake)
    fake.finishClassCaches()
    fake.install()
    return fake
  }

  @Test("attaches, finds containers by scanning, and passes the self-check", arguments: [CPUArchitecture.arm64, .x86_64])
  func attaches(architecture: CPUArchitecture) throws {
    let runtime = try ready(architecture).attach()
    #expect(runtime.architecture == architecture)
    #expect(runtime.layout == expectedLayout)
    #expect(runtime.assemblies.map(\.name) == ["mscorlib", "Assembly-CSharp"])
    #expect(try runtime.findClass("System.String", in: "mscorlib") != nil)
  }

  @Test("a self-check mismatch gives no runtime at all (the overlay stays quiet)")
  func selfCheckFailure() throws {
    let fake = FakeMono(architecture: .arm64)
    // A Mono whose String length field is not where mono_string_length reads: the layout can't be trusted.
    fake.makeRuntime(stringLengthOffset: 0x18)
    fake.finishClassCaches()
    fake.install()
    #expect(throws: MonoReaderError.unsupportedLayout("self-check failed: System.String fields")) { try fake.attach() }
  }

  @Test("a broken static-data path fails the self-check")
  func staticDataFailure() throws {
    // String.Empty points at an object of another class.
    let fake = ready(.x86_64) { $0.pointer($0.stringStorage, $0.newObject($0.objectClass)) }
    #expect(throws: MonoReaderError.unsupportedLayout("self-check failed: static data")) { try fake.attach() }
  }

  @Test("no Mono library yet means not ready, not unsupported")
  func noMono() throws {
    let fake = FakeMono(architecture: .arm64)
    fake.monoPath = "/usr/lib/libobjc.A.dylib"
    fake.makeRuntime()
    fake.finishClassCaches()
    fake.install()
    #expect(throws: MonoReaderError.notReady("Mono isn't loaded yet")) { try fake.attach() }
  }

  @Test("an empty root domain means not ready")
  func noDomain() throws {
    let fake = FakeMono(architecture: .arm64)
    fake.makeRuntime()
    fake.finishClassCaches()
    fake.install()
    fake.memory.write(fake.imageBase + fake.rootDomainGlobalOffset, UInt64(0))
    #expect(throws: MonoReaderError.notReady("Mono has no root domain yet")) { try fake.attach() }
  }

  @Test("Assembly-CSharp not loaded yet means not ready")
  func noGameAssembly() throws {
    let fake = FakeMono(architecture: .x86_64)
    fake.makeRuntime(assemblies: [])
    fake.finishClassCaches()
    fake.install()
    #expect(throws: MonoReaderError.notReady("Assembly-CSharp isn't loaded yet")) { try fake.attach() }
  }

  @Test("a stripped Mono library is unsupported")
  func noSymbols() throws {
    let fake = FakeMono(architecture: .arm64)
    fake.exportSymbols = false
    fake.makeRuntime()
    fake.finishClassCaches()
    fake.install()
    #expect(throws: MonoReaderError.unsupportedLayout("missing export _mono_vtable_get_static_field_data")) { try fake.attach() }
  }

  @Test("a class loaded after attach is found by re-indexing")
  func lateClass() throws {
    let fake = ready(.arm64)
    let runtime = try fake.attach()
    #expect(try runtime.findClass("Late") == nil)
    let late = fake.addClass(image: fake.image("Assembly-CSharp"), namespace: "", name: "Late")
    fake.finishClassCaches()
    runtime.beginSnapshot()
    try runtime.index(assembly: "Assembly-CSharp", force: true)
    #expect(try runtime.findClass("Late") == late)
  }

  @Test("nested classes are indexed by their full name")
  func nestedNames() throws {
    let fake = ready(.arm64) { fake in
      let csharp = fake.image("Assembly-CSharp")
      let outer = fake.addClass(image: csharp, namespace: "Hearthstone", name: "Outer")
      _ = fake.addClass(image: csharp, namespace: "", name: "Inner", nestedIn: outer)
    }
    let runtime = try fake.attach()
    #expect(try runtime.findClass("Hearthstone.Outer+Inner") != nil)
  }
}

@Suite("Memory reader")
struct MemoryReaderTests {
  @Test("reads values across page boundaries and caches pages")
  func pages() throws {
    let memory = FakeMemory()
    memory.write(0x1ffe, UInt32(0xdead_beef))
    memory.write(0x3000, Array("hello".utf8) + [0])
    let reader = MemoryReader(source: memory)
    #expect(try reader.u32(0x1ffe) == 0xdead_beef)
    #expect(try reader.cString(0x3000) == "hello")
    let before = memory.reads
    _ = try reader.u32(0x1ffe)
    #expect(memory.reads == before)
    reader.clearCache()
    _ = try reader.u32(0x1ffe)
    #expect(memory.reads > before)
  }

  @Test("unreadable memory throws")
  func unreadable() {
    let reader = MemoryReader(source: FakeMemory())
    #expect(throws: MonoReaderError.self) { try reader.u64(0x5000) }
    #expect(throws: MonoReaderError.self) { try reader.u64(0) }
  }

  @Test("a C string running off mapped memory throws instead of returning partial text")
  func unterminated() {
    let memory = FakeMemory()
    memory.write(0x1ff0, [UInt8](repeating: 0x41, count: 16))
    #expect(throws: MonoReaderError.self) { try MemoryReader(source: memory).cString(0x1ff0) }
  }

  @Test("a bad Mach-O header is unsupported")
  func badHeader() {
    let memory = FakeMemory()
    memory.write(0x4000, UInt32(0xfeed_face))
    #expect(throws: MonoReaderError.unsupportedLayout("Mono library is not a 64-bit Mach-O image")) {
      try MachOImage(address: 0x4000, reader: MemoryReader(source: memory))
    }
  }
}

@Suite("Read-only guarantee")
struct ReadOnlyTests {
  @Test("the reader never calls an API that writes to or controls another process")
  func noWrites() throws {
    let folder = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
      .appendingPathComponent("../../Shared/MonoReader").standardized
    let sources = try FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)
      .filter { $0.pathExtension == "swift" }
    #expect(sources.count >= 7)
    let forbidden = ["mach_vm_write", "vm_write", "mach_vm_protect", "vm_protect", "mach_vm_allocate", "task_suspend",
                     "thread_create", "thread_set_state", "ptrace", "task_set_"]
    for source in sources {
      let text = try String(contentsOf: source, encoding: .utf8)
      for api in forbidden { #expect(!text.contains(api), "\(source.lastPathComponent) uses \(api)") }
    }
  }
}
