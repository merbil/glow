import Darwin
import Foundation

/// Which IPv4 networks this Mac is on right now, read from its own network interfaces
/// (no traffic, no permission prompt). Used to explain why the bridge can't be reached.
enum LocalNetwork {
    struct Subnet: Equatable {
        let address: UInt32     // host byte order
        let mask: UInt32
    }

    enum Verdict: Equatable {
        case sameNetwork        // the bridge's address is on one of the Mac's networks
        case differentNetwork   // the Mac is online, but not on the bridge's network (guest Wi-Fi, a second router, away from home)
        case noNetwork          // the Mac has no IPv4 network at all
        case unknown            // not an IPv4 address, so we can't tell
    }

    /// The Mac's active IPv4 networks (up, not loopback).
    static func subnets() -> [Subnet] {
        var head: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&head) == 0, let first = head else { return [] }
        defer { freeifaddrs(head) }
        var result: [Subnet] = []
        for entry in sequence(first: first, next: { $0.pointee.ifa_next }) {
            let ifa = entry.pointee
            let flags = Int32(ifa.ifa_flags)
            guard flags & IFF_UP != 0, flags & IFF_LOOPBACK == 0,
                  let addr = ifa.ifa_addr, addr.pointee.sa_family == sa_family_t(AF_INET),
                  let mask = ifa.ifa_netmask else { continue }
            let a = addr.withMemoryRebound(to: sockaddr_in.self, capacity: 1) { UInt32(bigEndian: $0.pointee.sin_addr.s_addr) }
            let m = mask.withMemoryRebound(to: sockaddr_in.self, capacity: 1) { UInt32(bigEndian: $0.pointee.sin_addr.s_addr) }
            // 169.254.x.x is the address a Mac gives itself when no network hands one out: not a real network.
            if a >> 16 == 0xA9FE { continue }
            result.append(Subnet(address: a, mask: m))
        }
        return result
    }

    static func verdict(for host: String, subnets: [Subnet] = subnets()) -> Verdict {
        var a = in_addr()
        guard inet_pton(AF_INET, host, &a) == 1 else { return .unknown }
        guard !subnets.isEmpty else { return .noNetwork }
        let ip = UInt32(bigEndian: a.s_addr)
        return subnets.contains { ($0.address & $0.mask) == (ip & $0.mask) } ? .sameNetwork : .differentNetwork
    }

    /// For tests: "192.168.1.20/24" → Subnet.
    static func subnet(_ cidr: String) -> Subnet? {
        let parts = cidr.split(separator: "/")
        var a = in_addr()
        guard parts.count == 2, let bits = UInt32(parts[1]), bits <= 32,
              inet_pton(AF_INET, String(parts[0]), &a) == 1 else { return nil }
        return Subnet(address: UInt32(bigEndian: a.s_addr), mask: bits == 0 ? 0 : ~UInt32(0) << (32 - bits))
    }
}
