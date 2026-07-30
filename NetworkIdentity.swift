import Foundation

// MARK: - NetworkIdentity
// Identifies the local network the device is currently attached to, so that
// per-network state — currently the cached Sonos topology — is never restored
// onto the wrong network.
//
// The key is the primary IPv4 interface's subnet in CIDR form, e.g.
// "192.168.1.0/24". Derived from getifaddrs; no entitlements, no permission
// prompts, no location access.
//
// DELIBERATELY NOT USED:
//
//   SSID (CNCopyCurrentNetworkInfo) — would be a far stronger key, but requires
//   the Access WiFi Information entitlement AND Location When In Use. Not worth
//   a location prompt on first launch of a music app.
//
//   Default gateway IP — reachable via a NET_RT_DUMP routing-table walk, and it
//   was in the original plan for this file. Dropped on inspection: it carries
//   almost no entropy beyond the subnet itself, because a 192.168.1.0/24
//   network's gateway is 192.168.1.1 in the overwhelming majority of cases. It
//   would have added ~70 lines of untestable pointer arithmetic to distinguish
//   networks that the subnet alone already fails to distinguish. Bad trade.
//
// CONSEQUENCE — READ THIS BEFORE RELYING ON THE KEY:
//
//   Subnet keys COLLIDE. Two different homes both on 192.168.1.0/24 produce the
//   same key, and common consumer routers make that likely rather than exotic.
//   This key is a fast-path hint, not proof of identity. Any caller that uses it
//   to restore cached state MUST validate that state against something the
//   remote system actually reports — for Sonos topology, the household ID — and
//   discard on mismatch. See ZoneDiscoveryService's cache extension.

enum NetworkIdentity {

    /// Stable key for the current network, or nil when offline or when no
    /// usable IPv4 interface is up. Callers should treat nil as "don't use
    /// cached state" rather than as an error.
    static func currentKey() -> String? {
        guard let (address, netmask) = primaryIPv4() else { return nil }
        return subnetCIDR(address: address, netmask: netmask)
    }

    // MARK: - Private

    /// Address and netmask of the primary IPv4 interface, in network byte order.
    /// Prefers en0 (Wi-Fi on device). Falls back to any other running, non-
    /// loopback Ethernet-family interface — covers wired iPad adapters and the
    /// Simulator, where the host's interface naming varies.
    private static func primaryIPv4() -> (address: in_addr_t, netmask: in_addr_t)? {
        var head: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&head) == 0, let first = head else { return nil }
        defer { freeifaddrs(head) }

        var preferred: (in_addr_t, in_addr_t)?
        var fallback: (in_addr_t, in_addr_t)?

        for ptr in sequence(first: first, next: { $0.pointee.ifa_next }) {
            let flags = Int32(ptr.pointee.ifa_flags)
            guard flags & IFF_UP == IFF_UP,
                  flags & IFF_RUNNING == IFF_RUNNING,
                  flags & IFF_LOOPBACK == 0 else { continue }

            guard let sa = ptr.pointee.ifa_addr,
                  sa.pointee.sa_family == UInt8(AF_INET),
                  let mask = ptr.pointee.ifa_netmask else { continue }

            let address = sa.withMemoryRebound(to: sockaddr_in.self, capacity: 1) {
                $0.pointee.sin_addr.s_addr
            }
            let netmask = mask.withMemoryRebound(to: sockaddr_in.self, capacity: 1) {
                $0.pointee.sin_addr.s_addr
            }

            // A zero netmask can't produce a meaningful subnet.
            guard netmask != 0 else { continue }

            let name = String(cString: ptr.pointee.ifa_name)
            if name == "en0" {
                preferred = (address, netmask)
            } else if fallback == nil, name.hasPrefix("en") || name.hasPrefix("bridge") {
                fallback = (address, netmask)
            }
        }

        return preferred ?? fallback
    }

    /// Formats the network portion of an address as CIDR, e.g. "192.168.1.0/24".
    private static func subnetCIDR(address: in_addr_t, netmask: in_addr_t) -> String? {
        var network = in_addr(s_addr: address & netmask)
        var buffer = [CChar](repeating: 0, count: Int(INET_ADDRSTRLEN))
        guard inet_ntop(AF_INET, &network, &buffer, socklen_t(INET_ADDRSTRLEN)) != nil else {
            return nil
        }
        // Popcount is byte-order independent, so the network-order mask is fine
        // to count directly.
        return "\(String(cString: buffer))/\(netmask.nonzeroBitCount)"
    }
}
