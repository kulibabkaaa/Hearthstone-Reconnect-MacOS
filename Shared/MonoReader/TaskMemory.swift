#if canImport(Darwin)
import Darwin
import Foundation
import Security

/// The live game's memory through its Mach task port. Read-only: the only call made on the port is
/// mach_vm_read_overwrite (plus task_info for dyld's image list).
public final class TaskMemory: MemorySource {
  private let task: mach_port_t

  /// Needs the "Developer Tools access" right (see TaskportAuthorization) and the debugger entitlement.
  public init(pid: pid_t) throws {
    var port: mach_port_t = 0
    let result = task_for_pid(mach_task_self_, pid, &port)
    guard result == KERN_SUCCESS else { throw MonoReaderError.accessDenied(result) }
    task = port
  }

  deinit { mach_port_deallocate(mach_task_self_, task) }

  public func read(address: UInt64, count: Int) throws -> [UInt8] {
    var buffer = [UInt8](repeating: 0, count: count)
    var copied: mach_vm_size_t = 0
    let result = buffer.withUnsafeMutableBytes { raw in
      mach_vm_read_overwrite(task, address, mach_vm_size_t(count),
                             mach_vm_address_t(UInt(bitPattern: raw.baseAddress)), &copied)
    }
    guard result == KERN_SUCCESS, copied == count else { throw MonoReaderError.readFailed(address: address, count: count) }
    return buffer
  }

  /// Address of dyld's `dyld_all_image_infos` in the target.
  public func allImageInfoAddress() throws -> UInt64 {
    var info = task_dyld_info()
    var count = mach_msg_type_number_t(MemoryLayout<task_dyld_info>.size / MemoryLayout<natural_t>.size)
    let result = withUnsafeMutablePointer(to: &info) {
      $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
        task_info(task, task_flavor_t(TASK_DYLD_INFO), $0, &count)
      }
    }
    guard result == KERN_SUCCESS, info.all_image_info_addr != 0 else {
      throw MonoReaderError.notReady("dyld image info unavailable (\(result))")
    }
    return info.all_image_info_addr
  }
}

public enum ProcessStart {
  /// When a process started, from the kernel (for processes LaunchServices didn't record a launch date for).
  public static func date(pid: pid_t) -> Date? {
    var info = kinfo_proc()
    var size = MemoryLayout<kinfo_proc>.stride
    var name: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_PID, pid]
    guard sysctl(&name, 4, &info, &size, nil, 0) == 0, size > 0, info.kp_proc.p_pid == pid else { return nil }
    let start = info.kp_proc.p_un.__p_starttime
    return Date(timeIntervalSince1970: TimeInterval(start.tv_sec) + TimeInterval(start.tv_usec) / 1_000_000)
  }
}

/// The macOS right task_for_pid checks for a same-user process ("Developer Tools access"). Its rule is shared
/// in the login session with a 10-hour timeout, so one approval covers later attaches too.
public enum TaskportAuthorization {
  public static let rightName = "system.privilege.taskport"

  /// True when macOS grants the right now with no dialog.
  public static func isGrantedWithoutDialog() -> Bool {
    copyRight(interactive: false) == errAuthorizationSuccess
  }

  /// Asks for the right; may show the macOS password dialog. Returns the Authorization status.
  public static func request() -> OSStatus {
    copyRight(interactive: true)
  }

  private static func copyRight(interactive: Bool) -> OSStatus {
    var authorization: AuthorizationRef?
    let created = AuthorizationCreate(nil, nil, [], &authorization)
    guard created == errAuthorizationSuccess, let authorization else { return created }
    defer { AuthorizationFree(authorization, []) }
    return rightName.withCString { name in
      var item = AuthorizationItem(name: name, valueLength: 0, value: nil, flags: 0)
      return withUnsafeMutablePointer(to: &item) { pointer in
        var rights = AuthorizationRights(count: 1, items: pointer)
        var flags: AuthorizationFlags = [.extendRights, .preAuthorize]
        if interactive { flags.insert(.interactionAllowed) }
        return AuthorizationCopyRights(authorization, &rights, nil, flags, nil)
      }
    }
  }
}
#endif
