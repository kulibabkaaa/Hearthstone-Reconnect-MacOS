import Darwin
import Foundation

/// Reads which remote addresses a process has TCP sockets to, the way `lsof` does (libproc). Only addresses and
/// ports are read, never traffic. While the proxy is on, `lsof` shows every Hearthstone socket as CLOSED, but the
/// remote addresses are still the real ones, which is all the reconnect needs.
enum HearthstoneConnections {
  /// Remote IPv4 endpoints of the process's TCP sockets, or nil when they can't be read.
  static func openTCPRemoteEndpoints(pid: pid_t) -> [GameEndpoint]? {
    let needed = proc_pidinfo(pid, PROC_PIDLISTFDS, 0, nil, 0)
    guard needed > 0 else { return nil }
    let stride = MemoryLayout<proc_fdinfo>.stride
    // Room for sockets opened between the two calls.
    var descriptors = [proc_fdinfo](repeating: proc_fdinfo(), count: Int(needed) / stride + 32)
    let filled = descriptors.withUnsafeMutableBytes {
      proc_pidinfo(pid, PROC_PIDLISTFDS, 0, $0.baseAddress, Int32($0.count))
    }
    guard filled > 0 else { return nil }

    var endpoints: [GameEndpoint] = []
    for descriptor in descriptors.prefix(Int(filled) / stride)
    where descriptor.proc_fdtype == UInt32(PROX_FDTYPE_SOCKET) {
      if let endpoint = remoteEndpoint(pid: pid, fd: descriptor.proc_fd) {
        endpoints.append(endpoint)
      }
    }
    return endpoints
  }

  private static func remoteEndpoint(pid: pid_t, fd: Int32) -> GameEndpoint? {
    var info = socket_fdinfo()
    let size = Int32(MemoryLayout<socket_fdinfo>.stride)
    guard proc_pidfdinfo(pid, fd, PROC_PIDFDSOCKETINFO, &info, size) == size,
      info.psi.soi_kind == SOCKINFO_TCP
    else { return nil }

    let internet = info.psi.soi_proto.pri_tcp.tcpsi_ini
    let port = UInt16(bigEndian: UInt16(truncatingIfNeeded: internet.insi_fport))
    guard port > 0 else { return nil }

    var address: in_addr
    if internet.insi_vflag & UInt8(INI_IPV4) != 0 {
      address = internet.insi_faddr.ina_46.i46a_addr4
    } else if internet.insi_vflag & UInt8(INI_IPV6) != 0 {
      // Only IPv4-mapped IPv6 (::ffff:a.b.c.d); game servers are IPv4.
      var address6 = internet.insi_faddr.ina_6
      let bytes = withUnsafeBytes(of: &address6) { Array($0) }
      guard bytes.count == 16, bytes[0..<10].allSatisfy({ $0 == 0 }), bytes[10] == 0xff, bytes[11] == 0xff
      else { return nil }
      address = in_addr(s_addr: bytes.withUnsafeBytes { $0.loadUnaligned(fromByteOffset: 12, as: UInt32.self) })
    } else {
      return nil
    }
    guard address.s_addr != 0 else { return nil }

    var text = [CChar](repeating: 0, count: Int(INET_ADDRSTRLEN))
    guard inet_ntop(AF_INET, &address, &text, socklen_t(text.count)) != nil else { return nil }
    return GameEndpoint(host: String(cString: text), port: port)
  }
}
