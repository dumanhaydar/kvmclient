import Foundation
import Network
import Observation

/// Finds KVMs on the local networks this device is attached to: every address of each IPv4
/// subnet is tried on ports 80 and 443, and whatever answers goes through `DeviceDetector`.
/// None of the supported firmwares advertises a Bonjour service, so a sweep is the only way
/// that works for all of them.
@MainActor @Observable
final class LANScanner {
    struct Found: Identifiable, Hashable {
        let host: String
        let useHTTPS: Bool
        let kind: DeviceKind
        /// Reverse DNS name, when the router or mDNS knows one (e.g. "picokvm.lan").
        let hostname: String?

        var id: String { host }

        var suggestedName: String {
            hostname.flatMap { $0.split(separator: ".").first.map(String.init) } ?? kind.shortTitle
        }
    }

    private(set) var found: [Found] = []
    private(set) var isScanning = false
    private(set) var progress = 0.0
    /// Scanned subnets, e.g. "192.168.1.0/24".
    private(set) var networks: [String] = []
    /// The system refused local network access (iOS/macOS privacy setting, or its prompt is
    /// still on screen), so the sweep couldn't see anything.
    private(set) var isBlocked = false
    private var task: Task<Void, Never>?

    private static let maxInFlight = 96

    func start() {
        task?.cancel()
        found = []
        progress = 0
        isBlocked = false
        isScanning = true
        task = Task { await scan() }
    }

    func stop() {
        task?.cancel()
        task = nil
        isScanning = false
    }

    private func scan() async {
        let subnets = Self.localSubnets()
        networks = subnets.map(\.description)
        let hosts = subnets.flatMap(\.hosts)
        var iterator = hosts.makeIterator()
        var finished = 0

        await withTaskGroup(of: (Found?, Bool).self) { group in
            for _ in 0..<Self.maxInFlight {
                guard let host = iterator.next() else { break }
                group.addTask { await Self.examine(host) }
            }
            while let (result, blocked) = await group.next() {
                guard !Task.isCancelled else { group.cancelAll(); return }
                finished += 1
                progress = Double(finished) / Double(max(hosts.count, 1))
                if blocked { isBlocked = true }
                if let result {
                    found.append(result)
                    found.sort { Self.sortKey($0.host) < Self.sortKey($1.host) }
                }
                if let host = iterator.next() {
                    group.addTask { await Self.examine(host) }
                }
            }
        }
        if !Task.isCancelled { isScanning = false }
    }

    private static func sortKey(_ host: String) -> Int {
        host.split(separator: ".").reduce(0) { $0 << 8 | (Int($1) ?? 0) }
    }

    // MARK: Probing

    /// The KVM at `host`, if any, and whether local network access was denied.
    private nonisolated static func examine(_ host: String) async -> (Found?, Bool) {
        async let https = probe(host, port: 443)
        async let http = probe(host, port: 80)
        let probes = await [(true, https), (false, http)]
        if probes.contains(where: { $0.1 == .blocked }) { return (nil, true) }
        // HTTPS first: PiKVM redirects HTTP to HTTPS, and WebSockets don't follow redirects.
        for useHTTPS in probes.filter({ $0.1 == .open }).map(\.0) {
            let client = HTTPClient(baseURL: URL(string: "\(useHTTPS ? "https" : "http")://\(host)")!, trustSelfSigned: true)
            let kind = await DeviceDetector.detect(client)
            client.invalidate()
            if let kind {
                return (Found(host: host, useHTTPS: useHTTPS, kind: kind, hostname: await reverseName(host)), false)
            }
        }
        return (nil, false)
    }

    private enum Probe { case open, closed, blocked }

    /// TCP connect with a short deadline. Hosts that don't exist never answer ARP, so the
    /// connection just sits in "preparing" until the deadline.
    private nonisolated static func probe(_ host: String, port: UInt16, timeout: TimeInterval = 1.2) async -> Probe {
        await withCheckedContinuation { continuation in
            let queue = DispatchQueue(label: "kvmclient.scan.probe")
            let connection = NWConnection(host: NWEndpoint.Host(host), port: NWEndpoint.Port(rawValue: port)!, using: .tcp)
            var done = false
            let finish: (Probe) -> Void = { result in
                guard !done else { return }
                done = true
                connection.cancel()
                continuation.resume(returning: result)
            }
            connection.stateUpdateHandler = { state in
                switch state {
                case .ready: finish(.open)
                // A refused connection shows up as .waiting; ENETDOWN on a live interface is the
                // local network privacy check saying no.
                case .waiting(.posix(.ECONNREFUSED)), .failed(.posix(.ECONNREFUSED)): finish(.closed)
                case .waiting(.posix(.ENETDOWN)): finish(.blocked)
                case .failed: finish(.closed)
                default: break
                }
            }
            connection.start(queue: queue)
            queue.asyncAfter(deadline: .now() + timeout) { finish(.closed) }
        }
    }

    private nonisolated static func reverseName(_ host: String) async -> String? {
        await withCheckedContinuation { continuation in
            let gate = DispatchQueue(label: "kvmclient.scan.dns")
            var done = false
            let finish: (String?) -> Void = { name in
                gate.async {
                    guard !done else { return }
                    done = true
                    continuation.resume(returning: name)
                }
            }
            DispatchQueue.global().async {
                var address = sockaddr_in()
                address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
                address.sin_family = sa_family_t(AF_INET)
                guard inet_pton(AF_INET, host, &address.sin_addr) == 1 else { return finish(nil) }
                var buffer = [CChar](repeating: 0, count: Int(NI_MAXHOST))
                let status = withUnsafePointer(to: &address) {
                    $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                        getnameinfo($0, socklen_t(MemoryLayout<sockaddr_in>.size), &buffer, socklen_t(buffer.count), nil, 0, NI_NAMEREQD)
                    }
                }
                let name = status == 0 ? String(cString: buffer).trimmingCharacters(in: CharacterSet(charactersIn: ".")) : nil
                finish(name?.isEmpty == false ? name : nil)
            }
            gate.asyncAfter(deadline: .now() + 1.5) { finish(nil) }
        }
    }

    // MARK: Interfaces

    struct Subnet: CustomStringConvertible {
        let network: UInt32
        let prefix: Int
        let own: UInt32

        var description: String { "\(Self.format(network))/\(prefix)" }

        var hosts: [String] {
            let size = UInt32(1) << UInt32(32 - prefix)
            guard size > 2 else { return [] }
            return (1..<size - 1).map { network + $0 }.filter { $0 != own }.map(Self.format)
        }

        static func format(_ address: UInt32) -> String {
            "\(address >> 24).\(address >> 16 & 0xFF).\(address >> 8 & 0xFF).\(address & 0xFF)"
        }
    }

    /// IPv4 subnets of the active LAN interfaces (Wi-Fi, Ethernet). VPN tunnels, link-local and
    /// Tailscale's CGNAT range are skipped; subnets larger than /22 are narrowed to the /24 around
    /// our own address to keep the sweep short.
    static func localSubnets() -> [Subnet] {
        var list: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&list) == 0, let first = list else { return [] }
        defer { freeifaddrs(list) }
        var subnets: [Subnet] = []
        for pointer in sequence(first: first, next: { $0.pointee.ifa_next }) {
            let entry = pointer.pointee
            let flags = Int32(entry.ifa_flags)
            let name = String(cString: entry.ifa_name)
            guard flags & IFF_UP != 0, flags & IFF_RUNNING != 0,
                  flags & (IFF_LOOPBACK | IFF_POINTOPOINT) == 0,
                  !["utun", "ipsec", "awdl", "llw", "feth", "zt"].contains(where: name.hasPrefix),
                  let addr = entry.ifa_addr, addr.pointee.sa_family == sa_family_t(AF_INET),
                  let mask = entry.ifa_netmask else { continue }
            let address = ipv4(addr), netmask = ipv4(mask)
            if address >> 16 == 0xA9FE || address >> 22 == 0x191 { continue } // 169.254/16, 100.64/10
            var prefix = netmask.nonzeroBitCount
            if prefix < 22 { prefix = 24 }
            guard prefix < 31 else { continue }
            let network = address & (UInt32.max << UInt32(32 - prefix))
            if !subnets.contains(where: { $0.network == network && $0.prefix == prefix }) {
                subnets.append(Subnet(network: network, prefix: prefix, own: address))
            }
        }
        return subnets
    }

    private static func ipv4(_ pointer: UnsafeMutablePointer<sockaddr>) -> UInt32 {
        pointer.withMemoryRebound(to: sockaddr_in.self, capacity: 1) { UInt32(bigEndian: $0.pointee.sin_addr.s_addr) }
    }
}
