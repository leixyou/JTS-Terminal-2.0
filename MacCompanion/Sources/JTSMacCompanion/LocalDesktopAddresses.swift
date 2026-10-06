import Foundation
import Darwin

enum LocalDesktopAddresses {
    static func available() -> [String] {
        var addresses: [String] = []
        var head: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&head) == 0 else { return ["127.0.0.1"] }
        defer { freeifaddrs(head) }
        var current = head
        while let entry = current {
            defer { current = entry.pointee.ifa_next }
            guard let address = entry.pointee.ifa_addr,
                  address.pointee.sa_family == UInt8(AF_INET),
                  entry.pointee.ifa_flags & UInt32(IFF_UP) != 0,
                  entry.pointee.ifa_flags & UInt32(IFF_LOOPBACK) == 0 else { continue }
            var buffer = [CChar](repeating: 0, count: Int(NI_MAXHOST))
            if getnameinfo(address, socklen_t(address.pointee.sa_len), &buffer,
                           socklen_t(buffer.count), nil, 0, NI_NUMERICHOST) == 0 {
                let host = String(cString: buffer)
                if !addresses.contains(host) { addresses.append(host) }
            }
        }
        return addresses.sorted() + ["127.0.0.1"]
    }
}
